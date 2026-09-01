# ghpo.quicknote

Quick note for the Omarchy bar. Adds a button next to the clock that opens a
dialog for a fast note; pressing Enter (or Salvar) saves it to
`~/Documents/QuickNotes/` as a timestamped markdown file. Esc (or Fechar)
discards.

![Preview](preview.png)

## Install

```bash
omarchy plugin add https://github.com/ghpo/ghpo.quicknote.git --enable
```

or, from a local checkout:

```bash
omarchy plugin add /path/to/ghpo.quicknote --enable
```

Enable it with a placement if you want it elsewhere:

```bash
omarchy plugin enable ghpo.quicknote --section center --after omarchy.clock
```

## Usage

- Click the note icon in the bar (or press `Ctrl+Alt+Enter` — add that
  binding yourself, it is user config, not part of the plugin):

  ```lua
  -- ~/.config/hypr/bindings.lua
  o.bind("CTRL + ALT + RETURN", "Quick note", "omarchy-shell shell toggle ghpo.quicknote")
  ```

- Type the note. `Enter` saves, `Shift+Enter` inserts a newline, `Esc` closes
  without saving.

## Settings

Per-widget settings in `shell.json` (the widget's layout entry):

| Key       | Default                    | Description                     |
|-----------|----------------------------|---------------------------------|
| `icon`    | `󰎚` (note)                 | Glyph shown on the bar button   |
| `notesDir`| `~/Documents/QuickNotes`   | Where the note files are saved  |

Example:

```json
{ "id": "ghpo.quicknote", "icon": "󰎚", "notesDir": "~/Documents/QuickNotes" }
```

## Layout

- `manifest.json` — plugin manifest (bar-widget + overlay)
- `QuickNoteButton.qml` — the bar button
- `QuickNoteFlow.qml` — the note dialog overlay
- `save-note.sh` — saves the note (shipped inside the plugin)
- `LICENSE` — MIT
- `preview.png` — marketplace preview image

The button summons the dialog through `omarchy-shell shell summon
ghpo.quicknote`, passing the configured `notesDir` in the payload.

## License

MIT. See [LICENSE](LICENSE).
