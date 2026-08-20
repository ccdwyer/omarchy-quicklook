# Assumptions

Conservative choices where the Omarchy / Quickshell / Hyprland API was not 100% certain. The rule: isolate the uncertainty behind a small adapter, prefer documented types (`Process`, `Socket`, `FileView`, `IpcHandler`, `PanelWindow`), and degrade.

## Plugin host

- **Entry points are `Item`s**, not `ShellRoot`. Overlay exposes `open(payloadJson)` / `close()` / `toggle()` for `omarchy-shell shell summon|hide|toggle`. Taken from the Quattro shell README and the Desktop Undo overlay.
- **`keepLoaded: true`** is set on the manifest even though the spec JSON block omitted it. The platform reference says plugins that must outlive a single summon (this overlay) should set it. Spec kinds/entryPoints are otherwise exact.
- **Injected properties** on load: `omarchyPath`, `shell`, `manifest`, `pluginRegistry`. Overlay and Service still function if some of these are missing.
- **Settings are inline on the `shell.json` plugins[] entry.** Service declares `roots`, `watchCap`, `cacheMb`, `maxFiles`, `extraExclude` only. The host copies those fields onto the Item; they flow to the helper via a `config` command *before* indexing starts. There is no nested `pluginSettings` object and no plugin-owned settings file. Runtime UI state (`firstRunShown`) is `~/.local/state/quicklook/ui.json`, not a settings file.
- **Service owns the only helper.** Overlay never launches `quicklookd`. It talks to the warm service over `omarchy-shell io.github.chris.quicklook <method> <arg>` (`query` / `preview` / `prefetch` / `snapshot` / …), or in-process `pluginRegistry.serviceFor` / `shell.serviceFor` when the host injects them. There is no in-process `shell.summon`. Persistent and one-shot helper launches pass `--plugin-dir <pluginDir>` so the demo corpus is not resolved from the shell cwd.
- **IPC verb** is `omarchy-shell io.github.chris.quicklook <method> <arg>` (service IpcHandler) and `shell summon <id> <payloadJson>` (overlay). `shell call <id>` hits the overlay loader only and is not the service path. Every `IpcHandler` method takes the required string argument (empty when unused). README examples always pass `<arg>`. We do not write `hyprland.conf`.
- **Two distinct IPC surfaces.** (1) Overlay `open` / `close` / `toggle` for `shell summon|hide|toggle`. Overlay also exposes root adapters `query` / `preview` / `snapshot` / `status` / `theme` / `prefetch` / `warmup` that forward to the service (the current preview payload is `previewResult` so it does not collide with the `preview` adapter). (2) Service `IpcHandler { target: <id> }` is the supported bind path: `omarchy-shell io.github.chris.quicklook <method> <arg>`. Overlay IPC fallback uses that target, never `shell call`.

## Quickshell

- **`Process { stdinEnabled: true }` plus `write(line)`** is the adapter for NDJSON to the helper. If `write` is missing, we try `stdin.write`, then fall back to `--oneshot` processes, then to in-process JS over the demo corpus. Isolated so a missing method does not take down the service after handshake.
- **Foreground previews are gated at 1 in-flight + 1 queued (latest wins); prefetch is a separate 1+1 slot.** The helper is synchronous, so the QML side must not send a new render until the active slot clears. `js/Protocol.js` owns that queue.
- **`stdout: SplitParser { onRead }`** is the documented line splitter for a long-running helper. `StdioCollector` is only used for one-shot commands (same pattern as Desktop Undo).
- **Theme tokens** `Color.menu.*`, `Color.accent`, `Style.*`, `Border.*`, `BorderSurface`, `PanelWindow`, `WlrLayershell` — copied from first-party clipboard / Desktop Undo. Monospace tries `Style.font.monoFamily` then `Style.font.mono`, else `"monospace"`. Reduced motion: `Style.reduceMotion` if present, else `OMARCHY_REDUCED_MOTION=1`.
- **QML rich text** is the constrained `<font color>` subset the spec requires. No CSS classes, no `<span style>`.
- **No `QtMultimedia` import.** A missing module would fail the overlay at load. Video is poster-frame-via-ffmpeg or metadata only.
- **`.pragma library` JS** is shared across Service and Overlay in one engine. Tests strip the pragma and eval under Node.
- **Hyprland bind collision** parses `hyprctl binds -j` as JSON objects (`key` + `modmask`). SUPER is bit 64. A whole-document string search is not used. Lua binds are dispatcher `__lua` plus a description; "ours" is plugin id in `arg` or description `QuickLook`.

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
and is bounded three ways: a group TERM→grace→**unconditional KILL** applied on
**every** leader-exit path — not only on timeout, but also when the leader exits
cleanly while a descendant is still alive — performed *before* the drain threads
are joined. That ordering is the load-bearing part: a TERM-ignoring descendant
that inherits the pipes can no longer hang the join or leak, because the group is
guaranteed dead (SIGKILL is uncatchable) before we wait on the pipes. On a clean
exit with an already-empty group the kill is skipped, so a well-behaved tool adds
no latency. Second bound: a hard **96 KiB cap** on captured stdout/stderr, drained
concurrently (so a flooding child can neither exhaust memory nor deadlock on a
full pipe). Third: CPU / file-size rlimits. `RLIMIT_NPROC` is deliberately **not**
set: it counts the real user's entire existing process table, so any absolute cap
makes fork / `pthread_create` fail on a normally-busy machine (it would break
threaded tools like `pdftoppm`); fork bombs are bounded by `RLIMIT_CPU` + the
group kill instead. This holds in **all three** impls — the POSIX shell no longer
sets `ulimit -u` either. `RLIMIT_AS` is applied on **Linux only** in all three
(Rust gates it on `target_os = "linux"`, Python on `sys.platform == "linux"`, the
POSIX shell on `uname -s = Linux`; unreliable on macOS/Darwin, where a low
address-space cap makes `dyld`/exec fail).
The process group is **mandatory**: `watchdog_ok` is true only when a new session
can be forged (`setsid`, or python `os.setsid`). GNU `timeout` alone does **not**
qualify — `--kill-after` bounds only its direct child, so a descendant outliving
the leader would leak — so the GNU branch is itself run under `setsid` and reaped
as a group. If no session-isolation method exists at all, the path-consuming
feature is **disabled / metadata-only** rather than run unbounded.

Rust helper (`run_limited` = process-group + wall-clock group kill + capped drain + rlimits):

| Binary | When | Bound |
|---|---|---|
| `plocate` / `locate` | cold query | `run_limited` 2s / 128 MB / 2s CPU |
| `pdftoppm` | PDF raster | `run_limited` 8s / 512 MB / 8s CPU |
| `pdfinfo` | PDF page count | `run_limited` 1.5s / 64 MB / 2s CPU; `/Count` scan fallback |
| `ffmpeg` / `magick` / `convert` | image downsample, video poster | `run_limited` 6–12s / 512 MB |
| `quicklookd --downsample` | isolated `image` crate resize | `run_limited` 12s / 512 MB |
| `file -b` | hex magic fallback after `infer` | `run_limited` 800 ms / 32 MB / 1s CPU |
| `gio` / `xdg-open` / `open` | Enter / reveal (user-initiated) | **detached** (`setsid` + spawn, no wait). `run_limited` reaps the process group when the opener exits and would kill the app it just launched. Overlay Enter also calls `Quickshell.execDetached(["xdg-open", path])` from the shell session. |

Python `compat/` (`run_killable`: new session / `setsid`; on timeout, or on a clean exit while the group is still non-empty, SIGTERM the process group then SIGKILL ~1s later — *before* joining the drain threads):

| Binary | Bound |
|---|---|
| `plocate` / `locate` | 2s + group kill + rlimits |
| `find` | 2s + group kill + rlimits |
| `pdftoppm` / `pdfinfo` | 8s / 2s + group kill + rlimits |
| `ffmpeg` / `magick` / `convert` | 12s + group kill + rlimits |
| `gio` / `xdg-open` / `open` | 8s + `start_new_session=True` + group SIGTERM then SIGKILL |

POSIX `compat/quicklookd.sh` (`run_watchdog`: both backends run the command under a new session via `spawn_group` — `setsid` or python `os.setsid` — and then `reap_group` after `wait`: if the process group still has members, TERM → 1s grace → **unconditional group `kill -KILL`**, on every exit path (normal *and* timed-out); skipped when the group is already empty so a clean tool adds no latency. GNU `timeout --kill-after=1s` is used for the direct-child bound when present but is itself wrapped in the session/group so a descendant that outlives it is still reaped — there is no unprotected foreground GNU path. `watchdog_ok` is false when neither `setsid` nor `os.setsid` is available, and path-consuming features then degrade to metadata-only):

| Binary | Bound |
|---|---|
| `plocate` / `locate` / `find` | `run_watchdog` 2s |
| `pdftoppm` / `ffmpeg` / `magick` / `convert` | `run_watchdog` 8s + ulimits |
| `dd` / `od` / `head` / `ls` (user files) | `run_watchdog` 1s |
| `gio` / `xdg-open` / `open` | `run_watchdog` 8s; portal/D-Bus launch returns fast leaving an empty group, so `reap_group` skips it and the opened app survives |
| directory sizes | `stat` metadata, not `wc` of file contents |

Perl `SIGALRM` is not used. A child that traps `TERM` is still reaped by `KILL`.

## Out of scope (intentional, spec + tribunal)

- Markdown rendering, archive listing, video playback polish (v1.1).
- Introspecting the selected file in an arbitrary file manager.
- A second Quickshell process.
- Network, accounts, telemetry (except the optional `fetch-helper.sh` the user runs by hand).
- Writing Hyprland config: first load does **not** assign a bind. The bar chip offers **Set hotkey**; only that click writes a marked `o.bind` block (never Super+Shift+P or Super+Ctrl+.). Occupied combos are skipped or replaced with Super+Alt+.. **Remove** on the chip (and `install-binds.py --remove`) strips that block. Never `hl.unbind`.
- Using atime for ranking.
