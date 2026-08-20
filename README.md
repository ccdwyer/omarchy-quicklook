# QuickLook

Fuzzy-find any file and preview it instantly: images, syntax-highlighted code, PDFs, CSVs. Space pins the preview fullscreen; Enter opens it. The most-missed macOS feature, native to Omarchy.

Indexes `$HOME` by default (skips `.ssh`, `.gnupg`, password-store, keyrings, `node_modules`, `target`, `.git`, and other hidden directories). Preview cache is LRU-capped at 500 MB under `~/.cache/quicklook`. Selection history lives in `~/.local/state/quicklook/`. Nothing leaves the machine.

This is an Omarchy shell plugin (service + overlay). It runs inside the long-lived `omarchy-shell` process. It does not start a second Quickshell instance.

![QuickLook demo corpus — invoice, photo, table, Rust, README](demo.gif)

Five-file demo corpus the overlay shows before you type (invoice, photo, 5k-row CSV, themed Rust, README). Generated off-device from the shipped samples; a live Hyprland capture is not possible on the macOS authoring host.

## Install

```sh
omarchy plugin add <git-url> --enable
```

That is the whole cold path. The installer does not run build hooks. On first summon the overlay talks to the **service-owned** helper over `omarchy-shell io.github.chris.quicklook` (Python `compat/` when the Rust binary is missing). Invoice PDF pages rasterize through resource-limited `pdftoppm` when Poppler is installed; images over 20 MP are downsampled before QML sees them. No `build.sh` is required to get a working finder.

The full Rust helper (`nucleo` ranking, sqlite frecency, isolated PDF children, 20 MP downsample) is optional. **This git tree does not and will not contain Linux prebuilts** — the authoring host is macOS, and fake binaries are worse than none.

1. Source build on the Omarchy box (the supported path when no release assets exist yet):

   ```sh
   ~/.config/omarchy/plugins/io.github.chris.quicklook/build.sh
   ```

2. After a tagged release, `.github/workflows/release.yml` cross-compiles musl `quicklookd` for `x86_64` and `aarch64` and publishes `CHECKSUMS.txt`. Fetch + verify:

   ```sh
   QUICKLOOK_RELEASE_REPO=<owner/repo> ~/.config/omarchy/plugins/io.github.chris.quicklook/scripts/fetch-helper.sh
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
| Super+Alt+. | Alternate toggle if Super+. collides |
| ↑ ↓ | Move selection (preview follows) |
| Space | Pin / unpin fullscreen preview |
| j / k | Next / previous PDF page when pinned |
| Enter | Open with `gio open` |
| Ctrl+Enter | Reveal parent folder |
| Esc | Unpin, then close |
| ? | Indexed roots, watch cap, cache use |

On first load the plugin writes Super+. to `~/.config/hypr/bindings.lua` if that combo is free, then pops an Omarchy notification with the key it assigned. Occupied shortcuts are skipped; Super+. falls back to Super+Alt+.. Super+Shift+P is Omarchy's Google Photos bind and is never stolen. Super+Ctrl+. is Transcode and is not used. It never unbinds someone else's key, and it will not notify again once its bind is already live.

Lua binds show dispatcher `__lua` plus a description — "ours" is plugin id in `arg` or description `QuickLook`.

```
bind = SUPER, period, exec, omarchy-shell shell toggle io.github.chris.quicklook '{}'
bind = SUPER ALT, period, exec, omarchy-shell shell toggle io.github.chris.quicklook '{}'
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
| PDF | `pdftoppm` in a disposable subprocess with CPU/memory rlimits and a wall-clock kill. No poppler → designed empty state. A failed render returns `render_error` + hex, never the raw PDF path (QML `Image` cannot display a PDF). Enter still opens. |
| CSV / TSV | First 500 rows as a zebra table; delimiter sniffing. |
| Directories | Entry listing + total size. |
| Anything else | Hex head + `file`-style magic. Never a blank pane. |

Video is **not** a player in 1.0. If `ffmpeg` is present the helper extracts a poster frame; otherwise the row shows metadata only.

## Settings

Settings are inline on the `shell.json` `plugins[]` entry. There is no separate config file for widget settings. The helper (Rust and the Python fallback) applies `roots`, `extraExclude`, `watchCap`, `cacheMb`, and `maxFiles` from a `config` command before indexing.

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

`shell summon` / `hide` / `toggle` are host verbs for the overlay kind. Helper
verbs (`status`, `query`, `preview`, `snapshot`, `theme`, `prefetch`, `warmup`)
live on the **service `IpcHandler`**. `omarchy-shell shell call <id> <method>`
hits the overlay loader only — it does not reach the service. The supported
path is the plugin IpcHandler; always pass the string argument:

```sh
omarchy-shell shell toggle io.github.chris.quicklook '{}'
omarchy-shell shell summon io.github.chris.quicklook '{"path":"/tmp/file.pdf"}'
omarchy-shell shell hide io.github.chris.quicklook
omarchy-shell io.github.chris.quicklook status ''
omarchy-shell io.github.chris.quicklook query invo
omarchy-shell io.github.chris.quicklook preview '{"path":"/tmp/file.pdf","page":1}'
omarchy-shell io.github.chris.quicklook snapshot ''
omarchy-shell io.github.chris.quicklook theme '{"bg":"#1e1e2e","fg":"#cdd6f4","accent":"#89b4fa"}'
omarchy-shell io.github.chris.quicklook prefetch /tmp/file.pdf
omarchy-shell io.github.chris.quicklook warmup ''
omarchy-shell io.github.chris.quicklook installBinds ''
```

`preview` takes either a bare path or a `{"path":…,"page":N}` object. Overlay
root adapters (`query` / `preview` / `snapshot` / `status` / `theme` /
`prefetch` / `warmup`) forward to that same target (or `serviceFor` when the
host injects it).

The same IpcHandler is also reachable via `quickshell ipc`:

```sh
quickshell ipc -p "$OMARCHY_PATH/shell" call io.github.chris.quicklook ping ''
quickshell ipc -p "$OMARCHY_PATH/shell" call io.github.chris.quicklook preview '{"path":"/tmp/file.pdf"}'
```

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
- **Helper binary.** `bin/quicklookd` is not in this git tree (see `bin/README.md` and `CHECKSUMS.txt`). Cold-judge `plugin add --enable` uses `compat/` (Python when present, POSIX `find` + real `gio open` otherwise). `build.sh` compiles from source. `.github/workflows/release.yml` is how Linux musl binaries and verified hashes are produced — they are not invented on macOS.
- **Keybinds auto-assign on first load.** Occupied combos are skipped. Never `hl.unbind`. No notify once binds are already live. First open of the overlay repeats the table and the privacy sentence. The first-run card is persisted in `~/.local/state/quicklook/ui.json`.

## v1.1 roadmap

- Markdown rendering
- Archive listing
- Video playback polish (only if QtMultimedia *and* codecs exist on the shell build)

## Tests (off-device)

```sh
node tests/run.js
sh tests/protocol.test.sh
sh tests/compat-config.test.sh
cargo test --manifest-path src/quicklookd/Cargo.toml
```

## Remove

```sh
omarchy plugin remove io.github.chris.quicklook
```
