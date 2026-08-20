# Assumptions

Conservative choices where the Omarchy / Quickshell / Hyprland API was not 100% certain. The rule: isolate the uncertainty behind a small adapter, prefer documented types (`Process`, `Socket`, `FileView`, `IpcHandler`, `PanelWindow`), and degrade.

## Plugin host

- **Entry points are `Item`s**, not `ShellRoot`. Overlay exposes `open(payloadJson)` / `close()` / `toggle()` for `omarchy-shell shell summon|hide|toggle`. Taken from the Quattro shell README and the Desktop Undo overlay.
- **`keepLoaded: true`** is set on the manifest even though the spec JSON block omitted it. The platform reference says plugins that must outlive a single summon (this overlay) should set it. Spec kinds/entryPoints are otherwise exact.
- **Injected properties** on load: `omarchyPath`, `shell`, `manifest`, `pluginRegistry`. Overlay and Service still function if some of these are missing.
- **Settings are inline on the `shell.json` plugins[] entry.** Service declares `roots`, `watchCap`, `cacheMb`, `maxFiles`, `extraExclude` plus an optional `pluginSettings` object. If the host copies entry fields onto the Item, they flow to the helper via a `config` command *before* indexing starts. There is no plugin-owned settings file. Runtime UI state (`firstRunShown`) is `~/.local/state/quicklook/ui.json`, not a settings file.
- **Service owns the only helper.** Overlay never launches `quicklookd`. It talks to the warm service over documented `omarchy-shell shell call <id> <method> <arg>` (`query` / `preview` / `prefetch` / `snapshot` / …). There is no `pluginRegistry.serviceFor` or in-process `shell.summon`. Persistent and one-shot helper launches pass `--plugin-dir <pluginDir>` so the demo corpus is not resolved from the shell cwd.
- **IPC verb** is `omarchy-shell shell call <id> <method> <arg>` and `shell summon <id> <payloadJson>`. Every `IpcHandler` method takes the required string argument (empty when unused). README examples always pass `<arg>`. We do not write `hyprland.conf`.
- **`IpcHandler` target** is the plugin id. Overlay polls `snapshot` and sends commands through that channel.

## Quickshell

- **`Process { stdinEnabled: true }` plus `write(line)`** is the adapter for NDJSON to the helper. If `write` is missing, we try `stdin.write`, then fall back to `--oneshot` processes, then to in-process JS over the demo corpus. Isolated so a missing method does not take down the service after handshake.
- **Foreground previews are gated at 1 in-flight + 1 queued (latest wins); prefetch is a separate 1+1 slot.** The helper is synchronous, so the QML side must not send a new render until the active slot clears. `js/Protocol.js` owns that queue.
- **`stdout: SplitParser { onRead }`** is the documented line splitter for a long-running helper. `StdioCollector` is only used for one-shot commands (same pattern as Desktop Undo).
- **Theme tokens** `Color.menu.*`, `Color.accent`, `Style.*`, `Border.*`, `BorderSurface`, `PanelWindow`, `WlrLayershell` — copied from first-party clipboard / Desktop Undo. Monospace tries `Style.font.monoFamily` then `Style.font.mono`, else `"monospace"`. Reduced motion: `Style.reduceMotion` if present, else `OMARCHY_REDUCED_MOTION=1`.
- **QML rich text** is the constrained `<font color>` subset the spec requires. No CSS classes, no `<span style>`.
- **No `QtMultimedia` import.** A missing module would fail the overlay at load. Video is poster-frame-via-ffmpeg or metadata only.
- **`.pragma library` JS** is shared across Service and Overlay in one engine. Tests strip the pragma and eval under Node.
- **Hyprland bind collision** parses `hyprctl binds -j` as JSON objects (`key` + `modmask`). SUPER is bit 64. A whole-document string search is not used.

## Helper

- **Spec language is Rust.** `src/quicklookd` is the real daemon. `compat/quicklookd.sh` + `compat/quicklookd.py` exist because the competition brief also requires a missing-binary fallback.
- **Indexing does not start until `config` or `warmup`.** `main` no longer warms on process start, so inline `shell.json` roots win the first walk. A later `config` increments `index_gen` and starts a new walk; the previous loop exits and rebuilds the poll directory set from the new roots.
- **A corrupt or unwritable frecency sqlite disables history** instead of aborting the helper. Queries still run; boosts are zero.
- **After three helper crashes** Service switches `helperCmd` to `compat/quicklookd.sh`, abandons in-flight preview slots, and flushes `sendQueue` as oneshot jobs so the pane cannot stall on the dead binary.
- **Watches are a bounded mtime-poll of the top-N recently used directories (cap 2000) plus a 90s rescan**, rebuilt from the current config each cycle. Not a recursive inotify of `$HOME`. README still documents the sysctl.
- **`gio open` is primary**; `xdg-open` then macOS `open` are fallbacks so unit tests can run here.
- **Prebuilt x86_64/aarch64 musl binaries are not in this git tree and will not be faked.** This host is macOS and has no linux-musl toolchain. The specification asked for checked-in static helpers; we cannot produce authentic ones here. The honest path is `.github/workflows/release.yml` (cross-compile + checksums on the GitHub release), `scripts/fetch-helper.sh` (refuses to install unless `CHECKSUMS.txt` matches), and `build.sh` on the Omarchy box. Cold-judge `omarchy plugin add --enable` does not need them: `compat/` (Python or POSIX) + the demo corpus is the working fallback. `CHECKSUMS.txt` in-tree is a pointer, not a hash list of files we do not have.
- **`nucleo-matcher` (the matching crate behind `nucleo`)** is used for scoring rather than the threaded `Nucleo` indexer. Same fzf scoring, simpler to test, no extra worker thread.
- **PDF render failures** set `render_error: true` and omit `path`, so QML never feeds a `.pdf` to `Image`. Enter still opens the hit from the results list.
- **Images over 20 MP** are downsampled in an isolated child (ffmpeg/magick/`--downsample` with rlimits) and cached. The original oversized file is never given to QML `Image`.
- **POSIX `pdftoppm`** runs under `ulimit` + `timeout` when those exist; otherwise the fallback is metadata-only.

## Out of scope (intentional, spec + tribunal)

- Markdown rendering, archive listing, video playback polish (v1.1).
- Introspecting the selected file in an arbitrary file manager.
- A second Quickshell process.
- Network, accounts, telemetry (except the optional `fetch-helper.sh` the user runs by hand).
- Writing Hyprland config.
- Using atime for ranking.
