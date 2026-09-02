/* quicknote-helper.c — secure storage helper for ghpo.quicknote.
 *
 * All filesystem access is descriptor-relative and no-follow: the notes
 * directory is held as an fd, leaves are opened with openat(...,O_NOFOLLOW),
 * new files are created with O_CREAT|O_EXCL and mode 0600, and edits/new
 * notes are published with renameat (renameat2 RENAME_NOREPLACE for new).
 * Every read/write/output is byte-bounded. Note bodies and search queries
 * arrive on stdin terminated by a NUL byte, never in argv.
 *
 * Subcommands:
 *   quicknote-helper [--dir DIR] list [limit]
 *   quicknote-helper [--dir DIR] search [limit]          (query via stdin)
 *   quicknote-helper [--dir DIR] save [--edit NAME]      (note via stdin)
 *   quicknote-helper [--dir DIR] view NAME
 *   quicknote-helper [--dir DIR] delete NAME
 *   quicknote-helper [--dir DIR] copy                    (text via stdin -> wl-copy)
 *   quicknote-helper --payload-dir DIR ensure
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <dirent.h>
#include <errno.h>
#include <time.h>
#include <ctype.h>
#include <stdint.h>

#define MAX_NOTE_BYTES   (512 * 1024)
#define MAX_QUERY_BYTES  512
#define MAX_FILES        500
#define MAX_FILE_BYTES   (128 * 1024)
#define MAX_OUTPUT_BYTES (4 * 1024 * 1024)
#define MAX_TAGS         6
#define MAX_TAG_LEN      128

static uid_t uid_now = 0;
static char dir_path[4096] = { 0 };
static size_t out_bytes = 0;
static int out_full = 0;

/* ------------------------------------------------------------------ output */

static void oput(const char *s) {
    if (out_full) return;
    size_t l = strlen(s);
    if (out_bytes + l > MAX_OUTPUT_BYTES) { out_full = 1; return; }
    fputs(s, stdout);
    out_bytes += l;
}
static void opch(char c) {
    if (out_full) return;
    if (out_bytes + 1 > MAX_OUTPUT_BYTES) { out_full = 1; return; }
    putchar(c);
    out_bytes++;
}
static void json_escape(const char *s, size_t n) {
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        switch (c) {
            case '"': oput("\\\""); break;
            case '\\': oput("\\\\"); break;
            case '\n': oput("\\n"); break;
            case '\r': oput("\\r"); break;
            case '\t': oput("\\t"); break;
            default:
                if (c < 0x20) { char b[8]; snprintf(b, sizeof b, "\\u%04x", c); oput(b); }
                else opch((char)c);
        }
    }
}

/* ------------------------------------------------------------- bounded stdin */

static size_t read_bounded(char *buf, size_t max) {
    size_t n = 0;
    char chunk[4096];
    while (n < max) {
        ssize_t r = read(0, chunk, sizeof chunk);
        if (r <= 0) break;
        for (ssize_t i = 0; i < r && n < max; i++) {
            if (chunk[i] == '\0') return n;   /* NUL terminator */
            buf[n++] = chunk[i];
        }
    }
    return n;
}

/* --------------------------------------------------------------- filesystem */

static int open_notes_dir(void) {
    int fd = open(dir_path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0 && errno == ENOENT) {
        /* create the notes dir on first use (0700, never following symlinks) */
        if (mkdir(dir_path, 0700) == 0 || errno == EEXIST)
            fd = open(dir_path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    }
    if (fd < 0) { fprintf(stderr, "quicknote-helper: cannot open notes dir\n"); exit(2); }
    struct stat st;
    if (fstat(fd, &st) < 0 || !S_ISDIR(st.st_mode) || st.st_uid != uid_now) {
        fprintf(stderr, "quicknote-helper: notes dir not owned by user\n");
        exit(2);
    }
    return fd;
}

/* Open a leaf (relative to dfd) requiring: no symlink, regular, owned. */
static int open_leaf(int dfd, const char *name, int flags) {
    if (!name || !*name || strchr(name, '/') || strcmp(name, ".") == 0 || strcmp(name, "..") == 0) {
        errno = EINVAL;
        return -1;
    }
    int fd = openat(dfd, name, flags | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return -1;
    struct stat st;
    if (fstat(fd, &st) < 0 || !S_ISREG(st.st_mode) || st.st_uid != uid_now) {
        close(fd);
        errno = EACCES;
        return -1;
    }
    return fd;
}

static int is_md(const char *name) {
    size_t l = strlen(name);
    return l >= 4 && strcmp(name + l - 3, ".md") == 0;
}

/* Create a new leaf with O_EXCL + 0600, returning its fd (name in out). */
static int create_excl(int dfd, const char *prefix, char *out, size_t outsz) {
    for (int i = 0; i < 100; i++) {
        snprintf(out, outsz, "%s%ld-%06x.md", prefix, (long)getpid(),
                 (unsigned)(rand() & 0xffffff));
        int fd = openat(dfd, out, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (fd >= 0) return fd;
        if (errno != EEXIST) return -1;
    }
    errno = EEXIST;
    return -1;
}

static int inode_of(int dfd, const char *name, struct stat *out) {
    if (fstatat(dfd, name, out, AT_SYMLINK_NOFOLLOW) < 0) return -1;
    if (!S_ISREG(out->st_mode) || out->st_uid != uid_now) { errno = EACCES; return -1; }
    return 0;
}

/* --------------------------------------------------------------- emit note */

struct note_entry { char *name; time_t mtime; };

static void emit_note(int dfd, const char *name) {
    int fd = open_leaf(dfd, name, O_RDONLY);
    if (fd < 0) return;
    char content[MAX_FILE_BYTES + 1];
    ssize_t n = read(fd, content, MAX_FILE_BYTES);
    close(fd);
    if (n < 0) n = 0;
    content[n] = '\0';

    /* title = first non-blank line, bounded */
    char title_buf[MAX_FILE_BYTES + 1] = { 0 };
    const char *p = content;
    while (*p) {
        const char *nl = strchr(p, '\n');
        size_t ll = nl ? (size_t)(nl - p) : strlen(p);
        int blank = 1;
        for (size_t i = 0; i < ll; i++)
            if (!isspace((unsigned char)p[i])) { blank = 0; break; }
        if (!blank) { memcpy(title_buf, p, ll); title_buf[ll] = '\0'; break; }
        if (!nl) break;
        p = nl + 1;
    }

    /* tags: #[A-Za-z0-9_-]+ tokens, deduped, capped */
    char *tags[MAX_TAGS];
    int ntags = 0;
    for (ssize_t i = 0; i < n && ntags < MAX_TAGS; i++) {
        if (content[i] != '#') continue;
        ssize_t j = i + 1;
        if (j >= n) break;
        if (!(isalnum((unsigned char)content[j]) || content[j] == '_')) continue;
        ssize_t start = j;
        while (j < n && (isalnum((unsigned char)content[j]) || content[j] == '_' || content[j] == '-')) j++;
        size_t len = (size_t)(j - start);
        if (len == 0 || len > MAX_TAG_LEN) { i = j; continue; }
        int dup = 0;
        for (int k = 0; k < ntags; k++)
            if (strlen(tags[k]) == len + 1 && strncmp(tags[k] + 1, content + start, len) == 0) dup = 1;
        if (!dup) {
            char *t = malloc(len + 2);
            if (t) { t[0] = '#'; memcpy(t + 1, content + start, len); t[len + 1] = '\0'; tags[ntags++] = t; }
        }
        i = j;
    }

    struct stat st;
    time_t mtime = 0;
    if (inode_of(dfd, name, &st) == 0) mtime = st.st_mtime;
    char stamp[32] = "";
    if (mtime) {
        struct tm tm;
        if (localtime_r(&mtime, &tm)) strftime(stamp, sizeof stamp, "%d/%m %H:%M", &tm);
    }
    char pathbuf[4096];
    snprintf(pathbuf, sizeof pathbuf, "%s/%s", dir_path, name);
    char nb[32];
    snprintf(nb, sizeof nb, "%lld", (long long)mtime);

    oput("{\"path\":\"");
    json_escape(pathbuf, strlen(pathbuf));
    oput("\",\"file\":\"");
    json_escape(name, strlen(name));
    oput("\",\"title\":\"");
    json_escape(title_buf, strlen(title_buf));
    oput("\",\"content\":\"");
    json_escape(content, (size_t)n);
    oput("\",\"stamp\":\"");
    json_escape(stamp, strlen(stamp));
    oput("\",\"mtime\":");
    oput(nb);
    oput(",\"tags\":[");
    for (int i = 0; i < ntags; i++) { if (i) oput(","); oput("\""); json_escape(tags[i], strlen(tags[i])); oput("\""); }
    oput("]}");
    for (int i = 0; i < ntags; i++) free(tags[i]);
}

/* ------------------------------------------------------------------ sorting */

static int cmp_mtime(const void *a, const void *b) {
    const struct note_entry *x = a, *y = b;
    return (x->mtime < y->mtime) - (x->mtime > y->mtime);   /* newest first */
}

/* ------------------------------------------------------------------- list */

static void cmd_list(int limit) {
    int dfd = open_notes_dir();
    DIR *d = fdopendir(dup(dfd));
    if (!d) { close(dfd); exit(2); }
    struct note_entry *ents = calloc(MAX_FILES, sizeof *ents);
    int n = 0;
    struct dirent *de;
    while ((de = readdir(d)) && n < MAX_FILES) {
        const char *nm = de->d_name;
        if (nm[0] == '.') continue;
        if (!is_md(nm)) continue;
        int fd = open_leaf(dfd, nm, O_RDONLY);
        if (fd < 0) continue;
        struct stat st;
        fstat(fd, &st);
        close(fd);
        ents[n].name = strdup(nm);
        ents[n].mtime = st.st_mtime;
        n++;
    }
    closedir(d);
    qsort(ents, n, sizeof *ents, cmp_mtime);
    if (limit > n) limit = n;
    if (limit < 0) limit = 0;
    opch('[');
    for (int i = 0; i < limit; i++) {
        if (i) opch(',');
        emit_note(dfd, ents[i].name);
        free(ents[i].name);
    }
    opch(']');
    close(dfd);
    free(ents);
}

/* ----------------------------------------------------------------- search */

static void cmd_search(int limit) {
    char q[MAX_QUERY_BYTES + 1];
    size_t qn = read_bounded(q, MAX_QUERY_BYTES);
    q[qn] = '\0';
    if (qn == 0) { cmd_list(limit); return; }

    int dfd = open_notes_dir();
    DIR *d = fdopendir(dup(dfd));
    if (!d) { close(dfd); exit(2); }
    struct note_entry *ents = calloc(MAX_FILES, sizeof *ents);
    int n = 0;
    struct dirent *de;
    while ((de = readdir(d)) && n < MAX_FILES) {
        const char *nm = de->d_name;
        if (nm[0] == '.') continue;
        if (!is_md(nm)) continue;
        int fd = open_leaf(dfd, nm, O_RDONLY);
        if (fd < 0) continue;
        char buf[MAX_FILE_BYTES + 1];
        ssize_t r = read(fd, buf, MAX_FILE_BYTES);
        struct stat st;
        fstat(fd, &st);
        close(fd);
        if (r < 0) continue;
        buf[r] = '\0';
        if (strcasestr(buf, q)) {
            ents[n].name = strdup(nm);
            ents[n].mtime = st.st_mtime;
            n++;
        }
    }
    closedir(d);
    qsort(ents, n, sizeof *ents, cmp_mtime);
    if (limit > n) limit = n;
    if (limit < 0) limit = 0;
    opch('[');
    for (int i = 0; i < limit; i++) {
        if (i) opch(',');
        emit_note(dfd, ents[i].name);
        free(ents[i].name);
    }
    opch(']');
    close(dfd);
    free(ents);
}

/* ------------------------------------------------------------------- save */

static void cmd_save(const char *edit_name) {
    char note[MAX_NOTE_BYTES + 1];
    size_t n = read_bounded(note, MAX_NOTE_BYTES);
    note[n] = '\0';
    /* reject blank */
    int blank = 1;
    for (size_t i = 0; i < n; i++)
        if (!isspace((unsigned char)note[i])) { blank = 0; break; }
    if (blank) exit(0);

    int dfd = open_notes_dir();
    char tmpname[64];
    int tfd = create_excl(dfd, ".qn-new-", tmpname, sizeof tmpname);
    if (tfd < 0) { fprintf(stderr, "quicknote-helper: create temp failed\n"); exit(1); }
    ssize_t w = write(tfd, note, n);
    fsync(tfd);
    close(tfd);
    if (w != (ssize_t)n) { unlinkat(dfd, tmpname, 0); exit(1); }

    if (edit_name) {
        /* bind the target inode before replacing it */
        struct stat st;
        if (inode_of(dfd, edit_name, &st) < 0) { unlinkat(dfd, tmpname, 0); exit(1); }
        ino_t ino = st.st_ino;
        dev_t dev = st.st_dev;
        /* re-check right before rename: CAS against the bound inode */
        struct stat st2;
        if (inode_of(dfd, edit_name, &st2) < 0 || st2.st_ino != ino || st2.st_dev != dev) {
            unlinkat(dfd, tmpname, 0);
            fprintf(stderr, "quicknote-helper: edit target changed\n");
            exit(1);
        }
        if (renameat(dfd, tmpname, dfd, edit_name) < 0) {
            unlinkat(dfd, tmpname, 0);
            exit(1);
        }
    } else {
        char final[128];
        time_t now = time(NULL);
        struct tm tm;
        localtime_r(&now, &tm);
        strftime(final, sizeof final, "%Y-%m-%d_%H-%M-%S.md", &tm);
        /* RENAME_NOREPLACE: atomic, never overwrites an existing file */
        if (renameat2(dfd, tmpname, dfd, final, RENAME_NOREPLACE) < 0) {
            int ok = 0;
            for (int i = 1; i < 1000 && !ok; i++) {
                if (errno != EEXIST) break;
                snprintf(final, sizeof final, "%04d-%02d-%02d_%02d-%02d-%02d-%d.md",
                         tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
                         tm.tm_hour, tm.tm_min, tm.tm_sec, i);
                ok = (renameat2(dfd, tmpname, dfd, final, RENAME_NOREPLACE) == 0);
            }
            if (!ok) { unlinkat(dfd, tmpname, 0); exit(1); }
        }
    }
    /* fsync the directory so the rename is durable */
    fsync(dfd);
    close(dfd);
}

/* ------------------------------------------------------------------- view */

static void cmd_view(const char *name) {
    int dfd = open_notes_dir();
    int fd = open_leaf(dfd, name, O_RDONLY);
    if (fd < 0) exit(1);
    char buf[8192];
    size_t total = 0;
    ssize_t r;
    while (total < MAX_FILE_BYTES && (r = read(fd, buf, sizeof buf)) > 0) {
        if (total + (size_t)r > MAX_FILE_BYTES) r = (ssize_t)(MAX_FILE_BYTES - total);
        if (write(1, buf, (size_t)r) != r) break;
        total += (size_t)r;
    }
    close(fd);
    close(dfd);
}

/* ----------------------------------------------------------------- delete */

static void cmd_delete(const char *name) {
    int dfd = open_notes_dir();
    if (inode_of(dfd, name, &(struct stat){0}) < 0) { close(dfd); exit(1); }
    if (unlinkat(dfd, name, 0) < 0) { close(dfd); exit(1); }
    fsync(dfd);
    close(dfd);
}

/* ------------------------------------------------------------------- copy */

static void cmd_copy(void) {
    char buf[MAX_NOTE_BYTES + 1];
    size_t n = read_bounded(buf, MAX_NOTE_BYTES);
    buf[n] = '\0';
    int pfd[2];
    if (pipe(pfd) < 0) exit(1);
    pid_t pid = fork();
    if (pid == 0) {
        dup2(pfd[0], 0);
        close(pfd[0]);
        close(pfd[1]);
        execlp("wl-copy", "wl-copy", (char *)NULL);
        _exit(127);
    }
    if (pid < 0) exit(1);
    close(pfd[0]);
    ssize_t w = write(pfd[1], buf, n);
    close(pfd[1]);
    waitpid(pid, NULL, 0);
    (void)w;
}

/* ------------------------------------------------------------ payload dir */

static void cmd_payload_ensure(const char *pd) {
    if (mkdir(pd, 0700) != 0 && errno != EEXIST) exit(1);
    int fd = open(pd, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) exit(1);
    struct stat st;
    if (fstat(fd, &st) < 0 || !S_ISDIR(st.st_mode) || st.st_uid != uid_now
        || (st.st_mode & 077) != 0) {
        close(fd);
        exit(1);
    }
    close(fd);
}

/* -------------------------------------------------------------------- main */

int main(int argc, char **argv) {
    uid_now = getuid();
    srand((unsigned)(time(NULL) ^ getpid()));

    const char *pd = NULL;
    while (argc > 2 && strcmp(argv[1], "--dir") == 0) {
        snprintf(dir_path, sizeof dir_path, "%s", argv[2]);
        argv += 2; argc -= 2;
    }
    while (argc > 2 && strcmp(argv[1], "--payload-dir") == 0) {
        pd = argv[2];
        argv += 2; argc -= 2;
    }
    if (!dir_path[0]) {
        const char *home = getenv("HOME");
        snprintf(dir_path, sizeof dir_path, "%s/Documents/QuickNotes",
                 home && *home ? home : "");
    } else if (dir_path[0] == '~' && dir_path[1] == '/') {
        /* expand a leading tilde so literal "~/Documents/..." settings work */
        const char *home = getenv("HOME");
        char expanded[4096];
        snprintf(expanded, sizeof expanded, "%s%s",
                 home && *home ? home : "", dir_path + 1);
        snprintf(dir_path, sizeof dir_path, "%s", expanded);
    }

    if (argc < 2) {
        fprintf(stderr, "usage: quicknote-helper [--dir DIR] {list|search|save|view|delete|copy} ...\n");
        return 2;
    }
    const char *cmd = argv[1];
    argv += 2; argc -= 2;

    if (pd && strcmp(cmd, "ensure") == 0) { cmd_payload_ensure(pd); return 0; }

    int limit = 50;
    if (argc > 0) { char *e = NULL; long v = strtol(argv[0], &e, 10); if (e && *e == '\0') limit = (int)v; }

    if (strcmp(cmd, "list") == 0) { cmd_list(limit); return 0; }
    if (strcmp(cmd, "search") == 0) { cmd_search(limit); return 0; }
    if (strcmp(cmd, "save") == 0) {
        const char *edit = NULL;
        if (argc >= 2 && strcmp(argv[0], "--edit") == 0) edit = argv[1];
        cmd_save(edit);
        return 0;
    }
    if (strcmp(cmd, "view") == 0 && argc >= 1) { cmd_view(argv[0]); return 0; }
    if (strcmp(cmd, "delete") == 0 && argc >= 1) { cmd_delete(argv[0]); return 0; }
    if (strcmp(cmd, "copy") == 0) { cmd_copy(); return 0; }

    fprintf(stderr, "usage: quicknote-helper [--dir DIR] {list|search|save|view|delete|copy} ...\n");
    return 2;
}
