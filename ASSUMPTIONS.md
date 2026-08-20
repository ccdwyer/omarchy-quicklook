# Assumptions

Conservative choices where the Omarchy / Quickshell / Hyprland API was not 100% certain. The rule: isolate the uncertainty behind a small adapter, prefer documented types (`Process`, `Socket`, `FileView`, `IpcHandler`, `PanelWindow`), and degrade.

## Plugin host

- **Entry points are `Item`s**, not `ShellRoot`. Overlay exposes `open(payloadJson)` / `close()` / `toggle()` for `omarchy-shell shell summon|hide|toggle`. Taken from the Quattro shell README and the Desktop Undo overlay.
- **`keepLoaded: true`** is set on the manifest even though the spec JSON block omitted it. The platform reference says plugins that must outlive a single summon (this overlay) should set it. Spec kinds/entryPoints are otherwise exact.
- **Injected properties** on load: `omarchyPath`, `shell`, `manifest`, `pluginRegistry`. Overlay and Service still function if some of these are missing.
- **Settings are inline on the `shell.json` plugins[] entry.** Service declares `roots`, `watchCap`, `cacheMb`, `maxFiles`, `extraExclude` only. The host copies those fields onto the Item; they flow to the helper via a `config` command *before* indexing starts. There is no nested `pluginSettings` object and no plugin-owned settings file. Runtime UI state (`firstRunShown`) is `~/.local/state/quicklook/ui.json`, not a settings file.
- **Service owns the only helper.** Overlay never launches `quicklookd`. It talks to the warm service over documented `omarchy-shell shell call <id> <method> <arg>` (`query` / `preview` / `prefetch` / `snapshot` / …). There is no `pluginRegistry.serviceFor` or in-process `shell.summon`. Persistent and one-shot helper launches pass `--plugin-dir <pluginDir>` so the demo corpus is not resolved from the shell cwd.
- **IPC verb** is `omarchy-shell shell call <id> <method> <arg>` and `shell summon <id> <payloadJson>`. Every `IpcHandler` method takes the required string argument (empty when unused). README examples always pass `<arg>`. We do not write `hyprland.conf`.
- **Two distinct IPC surfaces.** (1) `omarchy-shell shell call <id> <method> <arg>` invokes the method **on the loaded entry-point root** — so every callable verb (`status`, `query`, `preview`, `snapshot`, `theme`, `open`, `reveal`, `prefetch`, `warmup`) is a **root-level** string-in/string-out adapter that parses its own JSON argument (`preview` accepts a bare path or `{"path":…,"page":N}`). (2) A separate `IpcHandler { target: <id> }` exposes the same verbs for direct `quickshell ipc call` use; its typed methods just delegate to the root adapters. The two are not conflated: the overlay's `snapshot` poll and commands go over `shell call` (surface 1).

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
- **POSIX `pdftoppm`** requires `timeout` as the wall-clock watchdog (plus `ulimit`s). If `timeout` is missing, previews stay metadata-only.
- **`build.sh` never copies `compat/` onto `bin/quicklookd`.** A failed or missing cargo build exits non-zero and leaves the authentic helper absent; Service already selects `compat/quicklookd.sh` by name.

### External processes (every untrusted-file spawn is killable)

Every subprocess that touches an untrusted file runs in **its own process group**
and is bounded three ways: a wall-clock deadline that TERMs then KILLs the whole
group (descendants included, so a TERM-ignoring child cannot outlive it), a hard
**96 KiB cap** on captured stdout/stderr that is drained concurrently (so a
flooding child can neither exhaust memory nor deadlock on a full pipe), and CPU /
file-size rlimits. `RLIMIT_NPROC` is deliberately **not** set: it counts the real
user's entire existing process table, so any absolute cap makes fork /
`pthread_create` fail on a normally-busy machine (it would break threaded tools
like `pdftoppm`); fork bombs are bounded by `RLIMIT_CPU` + the group kill instead.
`RLIMIT_AS` is applied on Linux only (unreliable on macOS/Darwin, where it breaks
exec). If the process-group guarantee cannot be established (`setsid` fails, or no
`setsid`/GNU-`timeout` in the POSIX fallback), the path-consuming feature is
**disabled / metadata-only** rather than run unbounded.

Rust helper (`run_limited` = process-group + wall-clock group kill + capped drain + rlimits):

| Binary | When | Bound |
|---|---|---|
| `plocate` / `locate` | cold query | `run_limited` 2s / 128 MB / 2s CPU |
| `pdftoppm` | PDF raster | `run_limited` 8s / 512 MB / 8s CPU |
| `pdfinfo` | PDF page count | `run_limited` 1.5s / 64 MB / 2s CPU; `/Count` scan fallback |
| `ffmpeg` / `magick` / `convert` | image downsample, video poster | `run_limited` 6–12s / 512 MB |
| `quicklookd --downsample` | isolated `image` crate resize | `run_limited` 12s / 512 MB |
| `file -b` | hex magic fallback after `infer` | `run_limited` 800 ms / 32 MB / 1s CPU |
| `gio` / `xdg-open` / `open` | Enter / reveal (user-initiated) | `run_limited` 8s / 128 MB |

Python `compat/` (`run_killable`: new session / `setsid`, wait, then SIGTERM to the process group and SIGKILL 1s later):

| Binary | Bound |
|---|---|
| `plocate` / `locate` | 2s + group kill + rlimits |
| `find` | 2s + group kill + rlimits |
| `pdftoppm` / `pdfinfo` | 8s / 2s + group kill + rlimits |
| `ffmpeg` / `magick` / `convert` | 12s + group kill + rlimits |
| `gio` / `xdg-open` / `open` | 8s + `start_new_session=True` + group SIGTERM then SIGKILL |

POSIX `compat/quicklookd.sh` (`run_watchdog`: GNU `timeout --kill-after=1s` when available — it already uses a new process group — otherwise `setsid`/`os.setsid` plus TERM then unconditional KILL of the **group**. `watchdog_ok` is false if neither isolation method exists; path-consuming features then degrade to metadata-only):

| Binary | Bound |
|---|---|
| `plocate` / `locate` / `find` | `run_watchdog` 2s |
| `pdftoppm` / `ffmpeg` / `magick` / `convert` | `run_watchdog` 8s + ulimits |
| `dd` / `od` / `head` / `ls` (user files) | `run_watchdog` 1s |
| `gio` / `xdg-open` / `open` | `run_watchdog` 8s (foreground; never `&`) |
| directory sizes | `stat` metadata, not `wc` of file contents |

Perl `SIGALRM` is not used. A child that traps `TERM` is still reaped by `KILL`.

## Out of scope (intentional, spec + tribunal)

- Markdown rendering, archive listing, video playback polish (v1.1).
- Introspecting the selected file in an arbitrary file manager.
- A second Quickshell process.
- Network, accounts, telemetry (except the optional `fetch-helper.sh` the user runs by hand).
- Writing Hyprland config.
- Using atime for ranking.
