# ghpo.quicknote

Quick note for the Omarchy bar. Adds a button next to the clock that opens a
dialog for a fast note. Pressing `Enter` (or the Save button) writes it to
`~/Documents/QuickNotes/` as a timestamped markdown file; `Esc` (or Close)
discards.

Since **v2.0.0** the notes can be **encrypted at rest** and **synced to a
private git remote** — everything optional and configurable per widget.

## Features

- One-keynote dialog: type, `Enter` saves, `Shift+Enter` adds a newline.
- Recent-notes list (newest first) with click-to-edit, keyboard navigation
  (`↑`/`↓`, `Enter` loads, `Alt+Enter` copies, `Ctrl+Enter` opens in your
  editor, `Delete` asks before removing).
- Text search and automatic `#tag` detection/filtering from note content.
- Delete requires confirmation.
- **Encrypted storage** (optional): notes are encrypted before they ever touch
  disk. See [Encryption & security](#encryption--security).
- **LOCKED screen**: while the key is not in memory the dialog hides the
  editor, search box and Save/Close buttons and shows a LOCKED screen with an
  Unlock button.
- **Change password**: re-encrypts every note with a new key (two-phase, so a
  failure leaves your notes untouched).
- **Git sync**: pull + commit + push to a private remote from inside the app,
  with a live log window, an editable remote, a copy-public-key button and an
  SSH-key setup guide.
- **Seal backup**: exports the `.quicknote-seal` (the salt needed to unlock
  the same notes on another machine) to a location you choose.
- The `?` button opens an in-dialog guide with embedded MIDI (Darude –
  Sandstorm) played by a self-contained C synthesizer — no external player or
  soundfont needed.

## Screenshots

The note button lives in the bar, right next to the clock:

![Icon next to the clock](screenshot-icon.png)

Click it to open the dialog — recent notes on the left, search + editor on the
right:

![Quick note dialog](preview.png)

The editor has an animated neon border:

![Demo](demo.gif)

Delete asks for confirmation:

![Delete confirmation](screenshot-delete.png)

The `?` button opens an in-dialog guide:

![Help overlay](screenshot-help.png)

## Install

```bash
omarchy plugin add https://github.com/ghpo/ghpo.quicknote.git --enable
```

or, from a local checkout:

```bash
omarchy plugin add /path/to/ghpo.quicknote --enable
```

Place it wherever you want:

```bash
omarchy plugin enable ghpo.quicknote --section center --after omarchy.clock
```

### Requirements

A C compiler (`cc`/`gcc`/`clang`) and the `libsodium` headers are needed to
build the storage daemon on first use — both are standard on Arch/Omarchy. No
other external runtime is required.

## Configuration

Per-widget settings in `shell.json` (the widget's layout entry):

| Key         | Default                    | Description                                          |
|-------------|----------------------------|------------------------------------------------------|
| `icon`      | `󰎚` (note)                 | Glyph shown on the bar button                        |
| `notesDir`  | `~/Documents/QuickNotes`   | Where the note files are saved                       |
| `encryption`| `false`                    | Encrypt all notes at rest (`true`/`false`)           |
| `gitRemote` | `""`                       | Optional SSH git remote to sync to (empty = no sync) |

Example:

```json
{
  "id": "ghpo.quicknote",
  "icon": "󰎚",
  "notesDir": "~/Documents/QuickNotes",
  "encryption": true,
  "gitRemote": "git@github.com:USER/notes.git"
}
```

## Usage

### Opening

Click the note icon in the bar. The keybinding `Ctrl+Alt+Enter` should run the
ships-in-the-plugin helper so it passes the same settings as the icon (a bare
`toggle` opens in plain mode):

```lua
-- ~/.config/hypr/bindings.lua
o.bind("CTRL + ALT + RETURN", "Quick note",
       "${HOME}/.config/omarchy/plugins/ghpo.quicknote/quicknote-open.sh")
```

### Encrypted mode — first run and LOCKED screen

When `encryption: true` and the app has no key in memory, the dialog shows a
**LOCKED** screen. Press **Unlock** and set a password the first time (this
creates the `.quicknote-seal` in the notes folder) or enter it afterwards.
While unlocked the footer offers:

- **Lock** — forgets the key (back to the LOCKED screen).
- **Pass** — change the password; every note is decrypted and re-encrypted
  with a new key, then the remote is re-synced if one is configured.
- **Seal** — back up the `.quicknote-seal` (folder picker).
- **Sync** — open the sync window (below).

### Sync window

Click **Sync** (any time you are unlocked) to open the live log. It shows every
step (`fetching → merging → committing → pushing`) and a clear OK / FAILED
result. In the same window you can:

- edit the **Git remote** and press **Save remote** (persisted into
  `shell.json`, so the bar button uses it from then on),
- **Copy public key** and read the built-in **SSH key help**,
- press **Sync now** to re-run.

SSH setup in short: `ssh-keygen -t ed25519` → `ssh-add ~/.ssh/id_ed25519` →
paste `~/.ssh/id_ed25519.pub` into GitHub → Settings → SSH and GPG keys →
verify with `ssh -T git@github.com`. The remote must use the SSH form
`git@github.com:USER/REPO.git`.

> The `.quicknote-seal` is intentionally **not** committed to the repo (it is
> gitignored by the sync helper). If you rely on the remote as a backup, back
> up the seal with the **Seal** button too — a new machine needs both the
> ciphertexts and the salt to decrypt.

## Encryption & security

Encryption is performed by `quicknote-crypto`, a small long-lived C daemon
(libsodium) that the plugin starts on demand. The UI never sees raw files in
encrypted mode.

### Cryptography

- **Key derivation**: Argon2id (`crypto_pwhash`, interactive limits) derives a
  32-byte key from your password and a random 16-byte salt.
- **Encryption**: XChaCha20-Poly1305 (`crypto_secretbox_easy`) per note, each
  file with its own random 24-byte nonce. File layout on disk is
  `nonce ‖ ciphertext ‖ tag`.
- **Seal** (`.quicknote-seal`): stores the salt plus an encrypted
  "verification" constant used to confirm the password. It contains **no key
  and no password**. Losing it is not a secret leak, but without it (or a
  backup) new machines cannot derive the key, so keep a copy.

### Key handling

- The derived key exists **only in the daemon's memory** and is zeroized on
  `Lock` and on exit. It is never written to disk, never passed in argv, and
  never logged.
- Memory is best-effort `mlock`ed to keep it out of swap.
- Password material is zeroized after use.

### Storage hardening

- Note files are created `0600`, owned by you, inside a directory you own.
- Access is descriptor-relative and `O_NOFOLLOW`; the notes directory is held
  as an open fd and leaves are opened with `openat(..., O_NOFOLLOW)` with
  inode checks, so a symlink/FIFO swap cannot be substituted between check and
  use.
- Renames use `RENAME_NOREPLACE`/exclusive creation; temp writes are fsync'd
  before publish; reads and writes are bounded (no unbounded allocation).
- Password changes re-encrypt every note **two-phase**: all new ciphertexts
  are written to temp files first, then atomically renamed over the originals,
  and the seal is rewritten last — a mid-run failure leaves the directory
  usable.

### What it protects and what it does not

Encryption protects the notes **at rest**: anyone who copies the notes folder
or clones a synced repository gets only ciphertext (the seal is not
committed), so without your salt there is nothing to run an offline guess
against.

The practical security level is that of your **password**. Argon2id makes
brute force slow, but a short/weak password can still be cracked offline by
whoever obtains both the ciphertext and the salt. Use a long, unique
passphrase (a sentence works well). This is not a trusted desktop vault:

- it does **not** protect against malware/keyloggers running as your user, or
  against someone using your unlocked session (the key is in memory while
  unlocked),
- the remote is trusted to be the repository you configure — a malicious
  remote could still receive your (encrypted) commits.

### Sync + recovery checklist

1. Set `encryption: true`, unlock, and confirm a note round-trips.
2. Set `gitRemote`, open **Sync**, confirm **OK**.
3. Press **Seal** and store a copy outside the machine (the salt is not in the
   repo on purpose).
4. To restore on a new machine: clone/install, drop the backed-up
   `.quicknote-seal` into the notes folder, then Unlock with the password and
   run Sync.

## Files

- `manifest.json` — plugin manifest (bar-widget + overlay), schema for
  `icon`/`notesDir`/`encryption`/`gitRemote`
- `QuickNoteButton.qml` — the bar button (reads settings at click time)
- `QuickNoteFlow.qml` — the note dialog overlay
- `quicknote.sh` — wrapper that builds and execs the storage daemon
- `quicknote-crypto.c` — the storage daemon (encryption, key in RAM,
  descriptor/no-follow file IO, JSON line protocol)
- `quicknote-git.sh` — sync helper (verbose pull/commit/push, ~-safe)
- `quicknote-open.sh` — open/toggle the dialog with the stored settings
- `save-note.sh` — argv-compatible save wrapper
- `quicknote-audio.c`, `quicknote-music.ulaw`, `play-music.sh`,
  `darude-sandstorm.mid` — embedded MIDI playback for the help overlay
- `NeonBorder.qml` — animated editor border
- `LICENSE` — MIT

## License

MIT. See [LICENSE](LICENSE).
