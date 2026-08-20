# Assumptions

Conservative choices where the Omarchy / Quickshell / Hyprland API was not 100% certain. The rule: isolate the uncertainty behind a small adapter, prefer documented types (`Process`, `Socket`, `FileView`, `IpcHandler`, `PanelWindow`), and degrade.

## Plugin host

- **Entry points are `Item`s**, not `ShellRoot`. Overlay exposes `open(payloadJson)` / `close()` / `toggle()` for `omarchy-shell shell summon|hide|toggle`. Taken from the Quattro shell README and the Desktop Undo overlay.
- **`keepLoaded: true`** is set on the manifest even though the spec JSON block omitted it. The platform reference says plugins that must outlive a single summon (this overlay) should set it. Spec kinds/entryPoints are otherwise exact.
- **Injected properties** on load: `omarchyPath`, `shell`, `manifest`, `pluginRegistry`. Overlay and Service still function if some of these are missing.
- **Settings are inline on the `shell.json` plugins[] entry.** Service declares `roots`, `watchCap`, `cacheMb`, `maxFiles`, `extraExclude` plus an optional `pluginSettings` object. If the host copies entry fields onto the Item, they flow to the helper via a `config` command. There is no plugin-owned settings file.
- **Third-party service lookup is not first-party `shell.firstPartyServiceFor`.** Overlay tries, in order: `pluginRegistry.serviceFor`, `shell.serviceFor`, `shell.firstPartyServiceFor`, then degrades to the demo corpus + `gio open`.
- **IPC verb** is `omarchy-shell shell call <id> <method> <arg>` and `shell summon <id> <payloadJson>`. Confirmed in `quattro-shell-reference.md`. README keybinds use that; we do not write `hyprland.conf`.
- **`IpcHandler` target** is the plugin id. `shell call` is the primary path; IpcHandler is extra.

## Quickshell

- **`Process { stdinEnabled: true }` plus `write(line)`** is the adapter for NDJSON to the helper. If `write` is missing, we try `stdin.write`, then fall back to `--oneshot` processes, then to in-process JS over the demo corpus. Isolated so a missing method does not take down the service after handshake.
- **`stdout: SplitParser { onRead }`** is the documented line splitter for a long-running helper. `StdioCollector` is only used for one-shot commands (same pattern as Desktop Undo).
- **Theme tokens** `Color.menu.*`, `Color.accent`, `Style.*`, `Border.*`, `BorderSurface`, `PanelWindow`, `WlrLayershell` — copied from first-party clipboard / Desktop Undo. Monospace tries `Style.font.monoFamily` then `Style.font.mono`, else `"monospace"`. Reduced motion: `Style.reduceMotion` if present, else `OMARCHY_REDUCED_MOTION=1`.
- **QML rich text** is the constrained `<font color>` subset the spec requires. No CSS classes, no `<span style>`.
- **No `QtMultimedia` import.** A missing module would fail the overlay at load. Video is poster-frame-via-ffmpeg or metadata only.
- **`.pragma library` JS** is shared across Service and Overlay in one engine. Tests strip the pragma and eval under Node.

## Helper

- **Spec language is Rust.** `src/quicklookd` is the real daemon. `compat/quicklookd.sh` + `compat/quicklookd.py` exist because the competition brief also requires a missing-binary fallback.
- **Watches are a bounded mtime-poll of the top-N recently used directories (cap 2000) plus a 90s rescan**, not a recursive inotify of `$HOME`. This stays under `fs.inotify.max_user_watches` without depending on a Linux-only crate compiling on the macOS authoring host. README still documents the sysctl.
- **`gio open` is primary**; `xdg-open` then macOS `open` are fallbacks so unit tests can run here.
- **Prebuilt x86_64/aarch64 musl binaries are not shipped.** This tree was authored on macOS without a musl toolchain. `build.sh` produces the helper on the Omarchy box and writes `CHECKSUMS.txt`. Deviation from the spec’s “ship prebuilt” line; runtime still degrades without the binary.
- **`nucleo-matcher` (the matching crate behind `nucleo`)** is used for scoring rather than the threaded `Nucleo` indexer. Same fzf scoring, simpler to test, no extra worker thread.

## Out of scope (intentional, spec + tribunal)

- Markdown rendering, archive listing, video playback polish (v1.1).
- Introspecting the selected file in an arbitrary file manager.
- A second Quickshell process.
- Network, accounts, telemetry.
- Writing Hyprland config.
- Using atime for ranking.
