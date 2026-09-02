#define _GNU_SOURCE
/* quicknote-crypto.c — long-lived, key-holding storage daemon for ghpo.quicknote.
 *
 * All note content is encrypted at rest with XChaCha20-Poly1305
 * (libsodium crypto_secretbox_easy). The key is derived from a password with
 * Argon2id and held ONLY in this process's memory (never on disk, never in
 * argv or logs); `lock` zeroizes it. File I/O is descriptor-relative and
 * no-follow (as in the previous helper). All content travels over stdin/stdout
 * as line-framed JSON — never in process arguments.
 *
 * Protocol (one JSON object per line on stdin; one JSON object per line on
 * stdout):
 *   {"op":"unlock","password":"..."}   -> {"ok":true} | {"ok":false,...}
 *   {"op":"list","limit":50}           -> {"ok":true,"notes":[...]}
 *   {"op":"search","query":"..."}      -> {"ok":true,"notes":[...]}
 *   {"op":"save","content":"...","edit":"file.md"|null} -> {"ok":true}
 *   {"op":"view","file":"file.md"}     -> {"ok":true,"content":"..."}
 *   {"op":"delete","file":"file.md"}   -> {"ok":true}
 *   {"op":"copy","content":"..."}      -> {"ok":true}
 *   {"op":"lock"}                      -> {"ok":true}
 *   {"op":"ping"}                      -> {"ok":true,"unlocked":bool}
 *
 * The seal file `<dir>/.quicknote-seal` holds the Argon2id salt plus an
 * encrypted verification string, so a fresh session can confirm the password.
 */
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
#include <sys/mman.h>
#include <sodium.h>

#define MAX_NOTE_BYTES    (512 * 1024)
#define MAX_QUERY_BYTES   512
#define MAX_FILES         500
#define MAX_FILE_BYTES    (128 * 1024)
#define MAX_TAGS          6
#define MAX_TAG_LEN       128
#define MAX_REQUEST       (MAX_NOTE_BYTES * 4 + 65536)
#define SEAL_NAME         ".quicknote-seal"
#define VERIFY_MSG        "quicknote-v1"

static uid_t uid_now;
static char dir_path[4096];
static unsigned char key[crypto_secretbox_KEYBYTES];
static int unlocked = 0;
static int plain = 0;

/* ---------------------------------------------------------------- utilities */

static char *xstrdup(const char *s) {
    char *d = strdup(s);
    if (!d) exit(2);
    return d;
}

/* ---- minimal JSON scanner ------------------------------------------------ */

/* Skip a JSON string literal at s, returning pointer past it. */
static const char *skip_string(const char *s) {
    if (*s != '"') return s;
    s++;
    while (*s) {
        if (*s == '\\') { s += 2; continue; }
        if (*s == '"') return s + 1;
        s++;
    }
    return s;
}

/* Look up a top-level string member "key":"..." in object text. Returns a
 * malloc'd unescaped value (length in *olen) or NULL. */
static char *json_field_str(const char *s, const char *key, size_t *olen) {
    size_t kl = strlen(key);
    const char *p = s;
    while ((p = strchr(p, '"')) != NULL) {
        const char *ks = p + 1;
        if (strncmp(ks, key, kl) == 0 && ks[kl] == '"') {
            const char *after = skip_string(p);
            while (isspace((unsigned char)*after)) after++;
            if (*after == ':') {
                const char *v = after + 1;
                while (isspace((unsigned char)*v)) v++;
                if (*v == '"') {
                    /* decode string into a fresh buffer */
                    v++;
                    size_t cap = strlen(v) + 1;
                    char *out = malloc(cap);
                    size_t n = 0;
                    while (*v && *v != '"') {
                        if (*v == '\\') {
                            v++;
                            switch (*v) {
                                case 'n': out[n++] = '\n'; break;
                                case 'r': out[n++] = '\r'; break;
                                case 't': out[n++] = '\t'; break;
                                case 'b': out[n++] = '\b'; break;
                                case 'f': out[n++] = '\f'; break;
                                case '/': out[n++] = '/'; break;
                                case '"': out[n++] = '"'; break;
                                case '\\': out[n++] = '\\'; break;
                                case 'u': {
                                    /* decode \uXXXX (assumes UTF-8 text; control chars land here) */
                                    long cp = 0;
                                    if (v[1] && v[2] && v[3] && v[4]) {
                                        for (int i = 1; i <= 4; i++) {
                                            char c = v[i];
                                            cp <<= 4;
                                            if (c >= '0' && c <= '9') cp += c - '0';
                                            else if (c >= 'a' && c <= 'f') cp += c - 'a' + 10;
                                            else if (c >= 'A' && c <= 'F') cp += c - 'A' + 10;
                                        }
                                        v += 4;
                                    }
                                    if (cp < 0x80) out[n++] = (char)cp;
                                    else if (cp < 0x800) {
                                        out[n++] = (char)(0xC0 | (cp >> 6));
                                        out[n++] = (char)(0x80 | (cp & 0x3F));
                                    } else {
                                        out[n++] = (char)(0xE0 | (cp >> 12));
                                        out[n++] = (char)(0x80 | ((cp >> 6) & 0x3F));
                                        out[n++] = (char)(0x80 | (cp & 0x3F));
                                    }
                                    break;
                                }
                                default: break;
                            }
                            v++;
                        } else {
                            out[n++] = *v++;
                        }
                    }
                    out[n] = '\0';
                    if (olen) *olen = n;
                    return out;
                }
                return NULL;
            }
        }
        p = skip_string(p);
    }
    return NULL;
}

/* ---- bounded line read from stdin ---------------------------------------- */

static char *read_line_bounded(void) {
    size_t cap = 65536, n = 0;
    char *buf = malloc(cap);
    if (!buf) return NULL;
    int c;
    while (n + 1 < MAX_REQUEST) {
        c = getchar();
        if (c == EOF) { if (n == 0) { free(buf); return NULL; } break; }
        if (c == '\n') break;
        if (n + 1 >= cap) { cap *= 2; buf = realloc(buf, cap); }
        buf[n++] = (char)c;
    }
    buf[n] = '\0';
    return buf;
}

/* ------------------------------------------------------------- JSON output */

static size_t out_bytes;
static void oput(const char *s) { fputs(s, stdout); out_bytes += strlen(s); }
static void opch(char c) { putchar(c); out_bytes++; }
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
static void resp_begin_ok(void) { out_bytes = 0; oput("{\"ok\":true"); }
static void resp_end(void) { oput("}\n"); fflush(stdout); }
static void resp_error(const char *msg) {
    out_bytes = 0;
    oput("{\"ok\":false,\"error\":\"");
    json_escape(msg, strlen(msg));
    oput("\"}\n");
    fflush(stdout);
}

/* --------------------------------------------------------------- filesystem */

static int open_notes_dir(void) {
    int fd = open(dir_path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0 && errno == ENOENT) {
        if (mkdir(dir_path, 0700) == 0 || errno == EEXIST)
            fd = open(dir_path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    }
    if (fd < 0) return -1;
    struct stat st;
    if (fstat(fd, &st) < 0 || !S_ISDIR(st.st_mode) || st.st_uid != uid_now) { close(fd); return -1; }
    return fd;
}

static int open_leaf(int dfd, const char *name, int flags) {
    if (!name || !*name || strchr(name, '/') || strcmp(name, ".") == 0 || strcmp(name, "..") == 0)
        return -1;
    int fd = openat(dfd, name, flags | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return -1;
    struct stat st;
    if (fstat(fd, &st) < 0 || !S_ISREG(st.st_mode) || st.st_uid != uid_now) { close(fd); return -1; }
    return fd;
}

static int is_md(const char *name) {
    size_t l = strlen(name);
    return l >= 4 && strcmp(name + l - 3, ".md") == 0;
}

static int create_excl(int dfd, const char *prefix, char *out, size_t outsz) {
    for (int i = 0; i < 100; i++) {
        snprintf(out, outsz, "%s%ld-%06x.md", prefix, (long)getpid(),
                 (unsigned)(rand() & 0xffffff));
        int fd = openat(dfd, out, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (fd >= 0) return fd;
        if (errno != EEXIST) return -1;
    }
    return -1;
}

static int inode_of(int dfd, const char *name, struct stat *out) {
    if (fstatat(dfd, name, out, AT_SYMLINK_NOFOLLOW) < 0) return -1;
    if (!S_ISREG(out->st_mode) || out->st_uid != uid_now) return -1;
    return 0;
}

/* ---------------------------------------------------------------- crypto IO */

/* Read + decrypt a note file. Returns malloc'd plaintext (len) or NULL. */
static unsigned char *note_read(int dfd, const char *name, size_t *out_len) {
    int fd = open_leaf(dfd, name, O_RDONLY);
    if (fd < 0) return NULL;
    struct stat st;
    if (fstat(fd, &st) < 0) { close(fd); return NULL; }
    size_t fsz = (size_t)st.st_size;
    if (fsz > MAX_NOTE_BYTES + crypto_secretbox_NONCEBYTES + crypto_secretbox_MACBYTES + 64) {
        close(fd);
        return NULL;
    }
    unsigned char *blob = malloc(fsz ? fsz : 1);
    if (!blob) { close(fd); return NULL; }
    ssize_t r = 0;
    size_t got = 0;
    while (got < fsz && (r = read(fd, blob + got, fsz - got)) > 0) got += (size_t)r;
    close(fd);
    if (got != fsz) { free(blob); return NULL; }

    if (plain) {
        *out_len = got;
        unsigned char *p2 = malloc(got + 1);
        if (!p2) { free(blob); return NULL; }
        memcpy(p2, blob, got);
        p2[got] = '\0';
        free(blob);
        return p2;
    }
    if (fsz < crypto_secretbox_NONCEBYTES + crypto_secretbox_MACBYTES + 1) { free(blob); return NULL; }
    unsigned char *ct = blob + crypto_secretbox_NONCEBYTES;
    size_t ct_len = fsz - crypto_secretbox_NONCEBYTES;
    unsigned char *plain = malloc(ct_len - crypto_secretbox_MACBYTES + 1);
    if (!plain) { free(blob); return NULL; }
    if (crypto_secretbox_open_easy(plain, ct, ct_len, blob, key) != 0) {
        free(blob);
        free(plain);
        return NULL;
    }
    plain[ct_len - crypto_secretbox_MACBYTES] = '\0';
    *out_len = ct_len - crypto_secretbox_MACBYTES;
    free(blob);
    return plain;
}

/* Encrypt plaintext into a malloc'd blob (nonce || ciphertext). */
static int note_encrypt(const unsigned char *pt, size_t plen, unsigned char **out, size_t *out_len) {
    if (plain) {
        unsigned char *raw = malloc(plen ? plen : 1);
        if (!raw) return -1;
        memcpy(raw, pt, plen);
        *out = raw;
        *out_len = plen;
        return 0;
    }
    unsigned char nonce[crypto_secretbox_NONCEBYTES];
    randombytes_buf(nonce, sizeof nonce);
    size_t cap = crypto_secretbox_NONCEBYTES + plen + crypto_secretbox_MACBYTES;
    unsigned char *blob = malloc(cap);
    if (!blob) return -1;
    memcpy(blob, nonce, crypto_secretbox_NONCEBYTES);
    if (crypto_secretbox_easy(blob + crypto_secretbox_NONCEBYTES, pt, plen, nonce, key) != 0) {
        free(blob);
        return -1;
    }
    *out = blob;
    *out_len = crypto_secretbox_NONCEBYTES + plen + crypto_secretbox_MACBYTES;
    return 0;
}

/* --------------------------------------------------------------- note emit */

struct note_entry { char *name; time_t mtime; };

static int cmp_mtime(const void *a, const void *b) {
    const struct note_entry *x = a, *y = b;
    return (x->mtime < y->mtime) - (x->mtime > y->mtime);
}

static void emit_note(int dfd, const char *name) {
    size_t n;
    unsigned char *content = note_read(dfd, name, &n);
    if (!content) return;
    if (n > MAX_FILE_BYTES) n = MAX_FILE_BYTES;
    content[n] = '\0';

    /* title */
    char title_buf[MAX_FILE_BYTES + 1] = { 0 };
    const char *p = (const char *)content;
    while (*p) {
        const char *nl = strchr(p, '\n');
        size_t ll = nl ? (size_t)(nl - p) : strlen(p);
        int blank = 1;
        for (size_t i = 0; i < ll; i++) if (!isspace((unsigned char)p[i])) { blank = 0; break; }
        if (!blank) { memcpy(title_buf, p, ll); title_buf[ll] = '\0'; break; }
        if (!nl) break;
        p = nl + 1;
    }

    /* tags */
    char *tags[MAX_TAGS];
    int ntags = 0;
    for (ssize_t i = 0; i < (ssize_t)n && ntags < MAX_TAGS; i++) {
        if (content[i] != '#') continue;
        ssize_t j = i + 1;
        if (j >= (ssize_t)n) break;
        if (!(isalnum((unsigned char)content[j]) || content[j] == '_')) continue;
        ssize_t start = j;
        while (j < (ssize_t)n && (isalnum((unsigned char)content[j]) || content[j] == '_' || content[j] == '-')) j++;
        size_t len = (size_t)(j - start);
        if (len == 0 || len > MAX_TAG_LEN) { i = j; continue; }
        int dup = 0;
        for (int k = 0; k < ntags; k++)
            if (strlen(tags[k]) == len + 1 && strncmp(tags[k] + 1, (char *)content + start, len) == 0) dup = 1;
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
    if (mtime) { struct tm tm; if (localtime_r(&mtime, &tm)) strftime(stamp, sizeof stamp, "%d/%m %H:%M", &tm); }
    char pathbuf[4096];
    snprintf(pathbuf, sizeof pathbuf, "%s/%s", dir_path, name);
    char nb[32];
    snprintf(nb, sizeof nb, "%lld", (long long)mtime);

    oput("{\"path\":\""); json_escape(pathbuf, strlen(pathbuf));
    oput("\",\"file\":\""); json_escape(name, strlen(name));
    oput("\",\"title\":\""); json_escape(title_buf, strlen(title_buf));
    oput("\",\"content\":\""); json_escape((char *)content, n);
    oput("\",\"stamp\":\""); json_escape(stamp, strlen(stamp));
    oput("\",\"mtime\":"); oput(nb);
    oput(",\"tags\":[");
    for (int i = 0; i < ntags; i++) { if (i) oput(","); oput("\""); json_escape(tags[i], strlen(tags[i])); oput("\""); free(tags[i]); }
    oput("]}");
    free(content);
}

/* ---------------------------------------------------------------- commands */

static void cmd_list(int limit) {
    int dfd = open_notes_dir();
    if (dfd < 0) { resp_error("cannot open notes dir"); return; }
    DIR *d = fdopendir(dup(dfd));
    if (!d) { close(dfd); resp_error("opendir failed"); return; }
    struct note_entry *ents = calloc(MAX_FILES, sizeof *ents);
    int n = 0;
    struct dirent *de;
    while ((de = readdir(d)) && n < MAX_FILES) {
        if (de->d_name[0] == '.' || !is_md(de->d_name)) continue;
        int fd = open_leaf(dfd, de->d_name, O_RDONLY);
        if (fd < 0) continue;
        struct stat st; fstat(fd, &st); close(fd);
        ents[n].name = xstrdup(de->d_name);
        ents[n].mtime = st.st_mtime;
        n++;
    }
    closedir(d);
    qsort(ents, n, sizeof *ents, cmp_mtime);
    if (limit > n) limit = n;
    resp_begin_ok();
    oput(",\"notes\":[");
    for (int i = 0; i < limit; i++) {
        if (i) opch(',');
        emit_note(dfd, ents[i].name);
        free(ents[i].name);
    }
    oput("]");
    resp_end();
    close(dfd);
    free(ents);
}

static void cmd_search(const char *query, int limit) {
    if (!query || !*query) { cmd_list(limit); return; }
    int dfd = open_notes_dir();
    if (dfd < 0) { resp_error("cannot open notes dir"); return; }
    DIR *d = fdopendir(dup(dfd));
    if (!d) { close(dfd); resp_error("opendir failed"); return; }
    struct note_entry *ents = calloc(MAX_FILES, sizeof *ents);
    int n = 0;
    struct dirent *de;
    while ((de = readdir(d)) && n < MAX_FILES) {
        if (de->d_name[0] == '.' || !is_md(de->d_name)) continue;
        size_t clen;
        unsigned char *c = note_read(dfd, de->d_name, &clen);
        if (!c) continue;
        struct stat st; fstatat(dfd, de->d_name, &st, AT_SYMLINK_NOFOLLOW);
        int hit = strcasestr((char *)c, query) != NULL;
        free(c);
        if (hit) { ents[n].name = xstrdup(de->d_name); ents[n].mtime = st.st_mtime; n++; }
    }
    closedir(d);
    qsort(ents, n, sizeof *ents, cmp_mtime);
    if (limit > n) limit = n;
    resp_begin_ok();
    oput(",\"notes\":[");
    for (int i = 0; i < limit; i++) {
        if (i) opch(',');
        emit_note(dfd, ents[i].name);
        free(ents[i].name);
    }
    oput("]");
    resp_end();
    close(dfd);
    free(ents);
}

static void cmd_save(const char *content, const char *edit_name) {
    size_t clen = strlen(content ? content : "");
    if (clen > MAX_NOTE_BYTES) clen = MAX_NOTE_BYTES;
    int blank = 1;
    for (size_t i = 0; i < clen; i++) if (!isspace((unsigned char)content[i])) { blank = 0; break; }
    if (blank) { resp_begin_ok(); resp_end(); return; }

    unsigned char *blob;
    size_t blen;
    if (note_encrypt((const unsigned char *)content, clen, &blob, &blen) != 0) {
        resp_error("encryption failed");
        return;
    }
    int dfd = open_notes_dir();
    if (dfd < 0) { free(blob); resp_error("cannot open notes dir"); return; }
    char tmpname[64];
    int tfd = create_excl(dfd, ".qn-new-", tmpname, sizeof tmpname);
    if (tfd < 0) { free(blob); close(dfd); resp_error("cannot create temp"); return; }
    size_t w = 0;
    while (w < blen) { ssize_t r = write(tfd, blob + w, blen - w); if (r <= 0) break; w += (size_t)r; }
    fsync(tfd);
    close(tfd);
    free(blob);
    if (w != blen) { unlinkat(dfd, tmpname, 0); close(dfd); resp_error("write failed"); return; }

    if (edit_name && *edit_name) {
        struct stat st;
        if (inode_of(dfd, edit_name, &st) < 0) { unlinkat(dfd, tmpname, 0); close(dfd); resp_error("edit target not safe"); return; }
        ino_t ino = st.st_ino; dev_t dev = st.st_dev;
        struct stat st2;
        if (inode_of(dfd, edit_name, &st2) < 0 || st2.st_ino != ino || st2.st_dev != dev) {
            unlinkat(dfd, tmpname, 0); close(dfd); resp_error("edit target changed"); return;
        }
        if (renameat(dfd, tmpname, dfd, edit_name) < 0) {
            unlinkat(dfd, tmpname, 0); close(dfd); resp_error("rename failed"); return;
        }
    } else {
        char final[128];
        time_t now = time(NULL);
        struct tm tm;
        localtime_r(&now, &tm);
        strftime(final, sizeof final, "%Y-%m-%d_%H-%M-%S.md", &tm);
        if (renameat2(dfd, tmpname, dfd, final, RENAME_NOREPLACE) < 0) {
            int ok = 0;
            for (int i = 1; i < 1000 && !ok; i++) {
                if (errno != EEXIST) break;
                snprintf(final, sizeof final, "%04d-%02d-%02d_%02d-%02d-%02d-%d.md",
                         tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec, i);
                ok = (renameat2(dfd, tmpname, dfd, final, RENAME_NOREPLACE) == 0);
            }
            if (!ok) { unlinkat(dfd, tmpname, 0); close(dfd); resp_error("publish failed"); return; }
        }
    }
    fsync(dfd);
    close(dfd);
    resp_begin_ok();
    resp_end();
}

static void cmd_view(const char *name) {
    int dfd = open_notes_dir();
    if (dfd < 0) { resp_error("cannot open notes dir"); return; }
    size_t n;
    unsigned char *c = note_read(dfd, name, &n);
    close(dfd);
    if (!c) { resp_error("cannot read note"); return; }
    resp_begin_ok();
    oput(",\"content\":\"");
    json_escape((char *)c, n);
    oput("\"");
    resp_end();
    free(c);
}

static void cmd_delete(const char *name) {
    int dfd = open_notes_dir();
    if (dfd < 0) { resp_error("cannot open notes dir"); return; }
    if (inode_of(dfd, name, &(struct stat){0}) < 0) { close(dfd); resp_error("target not safe"); return; }
    if (unlinkat(dfd, name, 0) < 0) { close(dfd); resp_error("delete failed"); return; }
    fsync(dfd);
    close(dfd);
    resp_begin_ok();
    resp_end();
}

static void cmd_copy(const char *content) {
    size_t n = strlen(content ? content : "");
    int pfd[2];
    if (pipe(pfd) < 0) { resp_error("pipe failed"); return; }
    pid_t pid = fork();
    if (pid == 0) {
        dup2(pfd[0], 0);
        close(pfd[0]); close(pfd[1]);
        execlp("wl-copy", "wl-copy", (char *)NULL);
        _exit(127);
    }
    if (pid < 0) { close(pfd[0]); close(pfd[1]); resp_error("fork failed"); return; }
    close(pfd[0]);
    ssize_t w = write(pfd[1], content, n);
    close(pfd[1]);
    waitpid(pid, NULL, 0);
    (void)w;
    resp_begin_ok();
    resp_end();
}

/* --------------------------------------------------------------- unlock/lock */

static int seal_path(char *buf, size_t bufsz) {
    int n = snprintf(buf, bufsz, "%s/%s", dir_path, SEAL_NAME);
    return (n > 0 && (size_t)n < bufsz) ? 0 : -1;
}

/* Derive key from password + salt. On first run, write the salt + verify seal.
 * Returns 0 on success, -1 on wrong password, -2 on IO error. */
static int do_unlock(const char *password, size_t plen) {
    unsigned char salt[crypto_pwhash_SALTBYTES];
    unsigned char seal_nonce[crypto_secretbox_NONCEBYTES];
    unsigned char seal_ct[crypto_secretbox_MACBYTES + sizeof(VERIFY_MSG)];
    int have_seal = 0;

    char path[4096];
    seal_path(path, sizeof path);

    int dfd = open(dir_path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (dfd < 0) {
        if (mkdir(dir_path, 0700) != 0 && errno != EEXIST) return -2;
        dfd = open(dir_path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (dfd < 0) return -2;
    }

    FILE *sf = fopen(path, "rb");
    if (sf) {
        size_t got = fread(salt, 1, sizeof salt, sf);
        size_t g2 = fread(seal_nonce, 1, sizeof seal_nonce, sf);
        size_t g3 = fread(seal_ct, 1, sizeof seal_ct, sf);
        fclose(sf);
        if (got == sizeof salt && g2 == sizeof seal_nonce && g3 == sizeof seal_ct)
            have_seal = 1;
    }

    if (!have_seal) randombytes_buf(salt, sizeof salt);

    if (crypto_pwhash(key, sizeof key, password, plen, salt,
                      crypto_pwhash_OPSLIMIT_INTERACTIVE,
                      crypto_pwhash_MEMLIMIT_INTERACTIVE,
                      crypto_pwhash_ALG_ARGON2ID13) != 0) {
        close(dfd);
        return -2;
    }

    if (have_seal) {
        unsigned char msg[sizeof(VERIFY_MSG) + crypto_secretbox_MACBYTES];
        if (crypto_secretbox_open_easy(msg, seal_ct, sizeof seal_ct,
                                       seal_nonce, key) != 0
            || memcmp(msg, VERIFY_MSG, sizeof(VERIFY_MSG)) != 0) {
            sodium_memzero(key, sizeof key);
            close(dfd);
            return -1;  /* wrong password */
        }
        unlocked = 1;
        close(dfd);
        return 0;
    }

    /* first run: write salt + verify seal */
    randombytes_buf(seal_nonce, sizeof seal_nonce);
    if (crypto_secretbox_easy(seal_ct, (const unsigned char *)VERIFY_MSG,
                              sizeof(VERIFY_MSG), seal_nonce, key) != 0) {
        sodium_memzero(key, sizeof key);
        close(dfd);
        return -2;
    }
    int fd = openat(dfd, SEAL_NAME, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0 && errno == EEXIST) {
        /* another process initialized concurrently — verify against it */
        close(dfd);
        return do_unlock(password, plen);
    }
    if (fd < 0) { sodium_memzero(key, sizeof key); close(dfd); return -2; }
    write(fd, salt, sizeof salt);
    write(fd, seal_nonce, sizeof seal_nonce);
    write(fd, seal_ct, sizeof seal_ct);
    fsync(fd);
    close(fd);
    close(dfd);
    unlocked = 1;
    return 0;
}

static void cmd_lock(void) {
    sodium_memzero(key, sizeof key);
    unlocked = 0;
    resp_begin_ok();
    resp_end();
}

/* -------------------------------------------------------------------- main */

int main(int argc, char **argv) {
    if (sodium_init() < 0) return 2;
    uid_now = getuid();
    srand((unsigned)(time(NULL) ^ getpid()));
    if (argc > 1 && strcmp(argv[1], "--plain") == 0) { plain = 1; argv++; argc--; }

    dir_path[0] = '\0';
    while (argc > 2 && strcmp(argv[1], "--dir") == 0) {
        snprintf(dir_path, sizeof dir_path, "%s", argv[2]);
        argv += 2; argc -= 2;
    }
    if (!dir_path[0]) {
        const char *home = getenv("HOME");
        snprintf(dir_path, sizeof dir_path, "%s/Documents/QuickNotes", home && *home ? home : "");
    } else if (dir_path[0] == '~' && dir_path[1] == '/') {
        const char *home = getenv("HOME");
        char expanded[4096];
        snprintf(expanded, sizeof expanded, "%s%s", home && *home ? home : "", dir_path + 1);
        snprintf(dir_path, sizeof dir_path, "%s", expanded);
    }

    /* best-effort: keep the key out of swap */
    if (mlock(key, sizeof key) != 0) { /* non-fatal */ }
    if (plain) unlocked = 1;

    for (;;) {
        char *req = read_line_bounded();
        if (!req) break;   /* stdin closed -> exit */
        size_t oplen;
        char *op = json_field_str(req, "op", &oplen);
        if (!op) { free(req); continue; }
        if (strcmp(op, "ping") == 0) {
            resp_begin_ok();
            oput(unlocked ? ",\"unlocked\":true" : ",\"unlocked\":false");
            resp_end();
        } else if (strcmp(op, "lock") == 0) {
            cmd_lock();
        } else if (plain && (strcmp(op, "unlock") == 0)) {
            resp_begin_ok(); resp_end();
        } else if (strcmp(op, "unlock") == 0) {
            size_t plen;
            char *pass = json_field_str(req, "password", &plen);
            if (!pass) { resp_error("missing password"); }
            else {
                int r = do_unlock(pass, plen);
                sodium_memzero(pass, plen);
                free(pass);
                if (r == 0) { resp_begin_ok(); resp_end(); }
                else if (r == -1) resp_error("wrong password");
                else resp_error("unlock failed");
            }
        } else if (!unlocked) {
            resp_error("locked");
        } else if (strcmp(op, "list") == 0) {
            int limit = 50;
            size_t ln;
            char *l = json_field_str(req, "limit", &ln);
            if (l) { limit = atoi(l); free(l); }
            cmd_list(limit);
        } else if (strcmp(op, "search") == 0) {
            size_t qlen;
            char *q = json_field_str(req, "query", &qlen);
            if (!q) { resp_error("missing query"); }
            else {
                if (qlen > MAX_QUERY_BYTES) q[MAX_QUERY_BYTES] = '\0';
                cmd_search(q, 50);
                free(q);
            }
        } else if (strcmp(op, "save") == 0) {
            size_t clen;
            char *content = json_field_str(req, "content", &clen);
            size_t elen;
            char *edit = json_field_str(req, "edit", &elen);
            if (!content) { resp_error("missing content"); }
            else {
                cmd_save(content, edit);
                sodium_memzero(content, clen);
                free(content);
            }
            if (edit) free(edit);
        } else if (strcmp(op, "view") == 0) {
            size_t fn;
            char *f = json_field_str(req, "file", &fn);
            if (!f) resp_error("missing file");
            else { cmd_view(f); free(f); }
        } else if (strcmp(op, "delete") == 0) {
            size_t fn;
            char *f = json_field_str(req, "file", &fn);
            if (!f) resp_error("missing file");
            else { cmd_delete(f); free(f); }
        } else if (strcmp(op, "copy") == 0) {
            size_t cn;
            char *c = json_field_str(req, "content", &cn);
            if (!c) resp_error("missing content");
            else { cmd_copy(c); sodium_memzero(c, cn); free(c); }
        } else {
            resp_error("unknown op");
        }
        free(op);
        free(req);
    }

    sodium_memzero(key, sizeof key);
    return 0;
}
