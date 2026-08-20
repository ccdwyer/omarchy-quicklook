# QuickLook

Fuzzy-find any file and preview it instantly: images, syntax-highlighted code, PDFs, CSVs. Space pins the preview fullscreen; Enter opens it. The most-missed macOS feature, native to Omarchy.

Indexes `$HOME` by default (skips `.ssh`, `.gnupg`, password-store, keyrings, `node_modules`, `target`, `.git`, and other hidden directories). Preview cache is LRU-capped at 500 MB under `~/.cache/quicklook`. Selection history lives in `~/.local/state/quicklook/`. Nothing leaves the machine.

This is an Omarchy shell plugin (service + overlay). It runs inside the long-lived `omarchy-shell` process. It does not start a second Quickshell instance.

## Install

```sh
omarchy plugin add <git-url> --enable
```

Then build the helper (Rust `quicklookd`; QML falls back to `compat/quicklookd.sh` if the binary is missing):

```sh
~/.config/omarchy/plugins/io.github.chris.quicklook/build.sh
```

Reload if the shell was already running:

```sh
omarchy-shell shell rescanPlugins
```

PDF previews need Poppler (`pdftoppm`):

```sh
pacman -S poppler
```

`plocate` is optional but makes the first typed query fast before the background index finishes:

```sh
pacman -S plocate
sudo updatedb
```

## Usage

| Combo | Action |
|---|---|
| Super+. | Toggle finder + preview (default) |
| Super+Shift+P | Alternate toggle if Super+. collides |
| ↑ ↓ | Move selection (preview follows) |
| Space | Pin / unpin fullscreen preview |
| j / k | Next / previous PDF page when pinned |
| Enter | Open with `gio open` |
| Ctrl+Enter | Reveal parent folder |
| Esc | Unpin, then close |
| ? | Indexed roots, watch cap, cache use |

The plugin does **not** write Hyprland config. Bind it yourself. `bindings.lua` is a snippet with a first-run collision check against `hyprctl binds -j`.

```
bind = SUPER, period, exec, omarchy-shell shell toggle io.github.chris.quicklook '{}'
bind = SUPER SHIFT, P, exec, omarchy-shell shell toggle io.github.chris.quicklook '{}'
```

Summon a specific file from a terminal or file-manager custom action (the Wayland-honest stand-in for “Space in Finder”):

```sh
omarchy-shell shell summon io.github.chris.quicklook '{"path":"/abs/invoice.pdf"}'
# or, from this plugin dir:
bin/quicklook /abs/invoice.pdf
```

Before you type, the overlay shows a five-file demo corpus (invoice PDF, photo, 5k-row CSV, themed Rust, a README) so the first second is already useful while `$HOME` walks in the background.

## What renders in 1.0

| Format | How |
|---|---|
| Images (png/jpg/webp/svg/gif) | QML `Image` / `AnimatedImage`. Helper downsamples stills over 20 MP. |
| Code / text (~40 langs) | `syntect` → `<font color>` spans only (QML rich text has no CSS classes). Files over 200 KB are truncated and labeled “large file”. |
| PDF | `pdftoppm` in a disposable subprocess with CPU/memory rlimits and a wall-clock kill. No poppler → designed empty state, Enter still opens. |
| CSV / TSV | First 500 rows as a zebra table; delimiter sniffing. |
| Directories | Entry listing + total size. |
| Anything else | Hex head + `file`-style magic. Never a blank pane. |

Video is **not** a player in 1.0. If `ffmpeg` is present the helper extracts a poster frame; otherwise the row shows metadata only.

## Settings

Settings are inline on the `shell.json` `plugins[]` entry. There is no separate config file.

```json
{
  "id": "io.github.chris.quicklook",
  "roots": ["~/Documents", "~/Downloads", "~/Desktop"],
  "watchCap": 2000,
  "cacheMb": 500,
  "maxFiles": 500000
}
```

Omit `roots` to index `$HOME` (with the default exclude list). Watch coverage, cache use, poppler/plocate, and helper identity are visible from `?` in the overlay.

Power users who later want a denser inotify fan-out:

```sh
# documented, not required for 1.0 (we poll the top-N recent directories)
sysctl fs.inotify.max_user_watches
```

## IPC

```sh
omarchy-shell shell toggle io.github.chris.quicklook '{}'
omarchy-shell shell summon io.github.chris.quicklook '{"path":"/tmp/file.pdf"}'
omarchy-shell shell hide io.github.chris.quicklook
omarchy-shell shell call io.github.chris.quicklook status
omarchy-shell shell call io.github.chris.quicklook query invo
```

The service also registers an `IpcHandler` target of the same id (`qs ipc call io.github.chris.quicklook ping`).

Helper protocol (newline-delimited JSON on stdin/stdout, testable without the shell):

```sh
echo '{"q":"invo","id":41}' | bin/quicklookd --plugin-dir . --root ./samples
bin/quicklookd --oneshot '{"id":1,"cmd":"status"}'
```

## Honest limitations

- **Not macOS Quick Look on a file-manager selection.** Wayland does not expose the selected path of an arbitrary app. 1.0 is finder-first; `summon … '{"path":"…"}'` is the bridge.
- **Space is pin, not a search character.** Queries are path fragments without spaces.
- **Close is not a renderer for every format.** Markdown, archives, and video playback are v1.1. Hostile PDFs can only take down a `pdftoppm` child, never the shell.
- **Index cap 500k files**, watch/poll cap 2000 directories, preview cache 500 MB. Huge homes still get a cold path (`plocate` or a bounded walk) plus the demo corpus.
- **Frecency uses selection history + mtime, never atime** (relatime lies).
- **Helper binary.** `bin/quicklookd` is produced by `build.sh`. Missing binary → `compat/quicklookd.sh` (Python 3 when present). Name-only results and basic previews still work; nucleo / sqlite / watches do not.
- **No prebuilt musl binaries in this tree.** This checkout was authored on macOS; run `build.sh` on the Omarchy box. Checksums are written to `CHECKSUMS.txt` when the Linux binary is built.
- **Keybinds are yours to add.** First open of the overlay repeats the table and the privacy sentence.

## v1.1 roadmap

- Markdown rendering
- Archive listing
- Video playback polish (only if QtMultimedia *and* codecs exist on the shell build)

## Tests (off-device)

```sh
node tests/run.js
sh tests/protocol.test.sh
cargo test --manifest-path src/quicklookd/Cargo.toml
```

## Remove

```sh
omarchy plugin remove io.github.chris.quicklook
```
