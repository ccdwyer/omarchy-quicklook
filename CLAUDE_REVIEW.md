# Claude Fable 5 — Final Review: QuickLook

**Verdict: APPROVED for submission** (final gate, after GPT-5.6 Sol PASS at round 13 — the most-contested plugin of the field)

Pipeline: Grok implemented → GPT-5.6 Sol gated (13 rounds) → Fable 5 agents applied the last fixes → Claude final review.

## What I verified independently
- **Subprocess isolation against hostile files (the entire back half of the review, since this renders arbitrary input):** the Rust helper spawns every path-consuming child in its OWN process group (`process_group(0)`), concurrently drains stdout/stderr capped at 96 KiB (no OOM, no full-pipe deadlock), and on EVERY exit path — normal or timeout — does group TERM → grace → unconditional group KILL before joining drains (a TERM-ignoring descendant can't hang or leak). The Python and POSIX-shell fallbacks mirror this (`setsid`/`os.setsid` + `reap_group`), and the shell disables a path rather than run it unprotected when no session-isolation exists.
- **The RLIMIT_NPROC landmine:** a Fable 5 fix caught that an absolute NPROC cap (counting the user's *entire* process table) would have broken `pdftoppm` in the primary path on any busy judge machine — removed across Rust/Python/shell, with a comment explaining why. This was a real bug the earlier rounds hadn't surfaced.
- **Shell-call IPC (Quattro):** root-level string adapters `snapshot(arg)`, `preview(arg)` (JSON-parsing), `theme(arg)` are exposed on the loaded service entry point; the `IpcHandler` delegates to them, so `omarchy-shell shell call <id> <method> <arg>` hits real methods.
- **Architecture:** single service-owned helper (overlay uses the warm index, no double home-scan); helper crash → restart; shell never blocks on a hostile file.
- **Manifest:** overlay + service kinds, keepLoaded; poppler/plocate optional; no build hook on install.
- **Tests:** 29 node + Rust behavioral (early-leader-exit descendant reaping, flooding bound) + killable shell/python cases; all green.

## Accepted residual (non-blocking, from GPT's warnings)
- Pure-shell PDF fallback reports 1 page (multi-page nav needs the Rust/Python helper); pure-shell CSV doesn't honor quoted delimiters. Both are documented degraded-mode limits, only hit when both real helpers are absent.

The most-hardened plugin here — renders arbitrary files locally and can't be hung, OOM'd, or leaked by a hostile one. Approved.
