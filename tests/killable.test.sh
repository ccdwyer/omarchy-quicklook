#!/bin/sh
# Behavioral: TERM-ignoring descendants in the process group must be reaped.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

ignore="$WORKDIR/ignore-term"
cat > "$ignore" << 'EOF'
#!/bin/sh
trap '' TERM
sleep 30
EOF
chmod +x "$ignore"

parent="$WORKDIR/parent"
cat > "$parent" << 'EOF'
#!/bin/sh
# TERM-responsive leader that leaves a TERM-ignoring descendant.
"$1" &
echo $! > "$2"
wait
EOF
chmod +x "$parent"

# Early-leader-exit leader: spawns a TERM-ignoring descendant that inherits
# stdout, then EXITS IMMEDIATELY. This is the regression case — the leader
# returns cleanly while the descendant keeps the pipes open, which used to hang
# the drain join on the normal-exit path. The post-exit unconditional group KILL
# must reap the descendant and the call must return promptly.
parent_early="$WORKDIR/parent-early"
cat > "$parent_early" << 'EOF'
#!/bin/sh
"$1" &
echo $! > "$2"
# no wait: leader exits now, descendant lingers holding stdout
EOF
chmod +x "$parent_early"

alive() {
  kill -0 "$1" 2>/dev/null
}

# --- Shell watchdog: descendant PID must disappear, on BOTH backends ---
# Run once with whatever backend the host has (GNU timeout if present) and once
# with the portable setsid path forced, so the portable group-kill is covered
# even on hosts that ship GNU coreutils.
run_shell_case() {
  label="$1"
  forceportable="$2"
  descfile="$WORKDIR/desc-$label.pid"
  : > "$descfile"
  set +e
  env QUICKLOOK_FORCE_SH=1 QUICKLOOK_FORCE_PORTABLE="$forceportable" \
    sh "$ROOT/compat/quicklookd.sh" --watchdog-selftest 2 "$parent" "$ignore" "$descfile"
  st=$?
  set -e
  sleep 1
  if [ ! -s "$descfile" ]; then
    echo "FAIL shell parent ($label) did not record descendant pid"
    exit 1
  fi
  dpid=$(tr -d ' \n' < "$descfile")
  if alive "$dpid"; then
    echo "FAIL shell watchdog ($label) left TERM-ignoring descendant pid $dpid alive"
    kill -KILL "$dpid" 2>/dev/null || true
    exit 1
  fi
  echo "ok  shell watchdog ($label) KILL reaps TERM-ignoring descendant (status $st, pid $dpid)"
}

run_shell_case "host-default" ""
run_shell_case "forced-portable" "1"

# --- Shell watchdog: EARLY leader exit must still reap the descendant ---
# The leader exits at once; without the post-exit unconditional group KILL the
# TERM-ignoring descendant would survive (and, in the capturing paths, hold the
# pipe open). run_watchdog must return promptly AND leave no descendant alive.
run_shell_early_case() {
  label="$1"
  forceportable="$2"
  descfile="$WORKDIR/desc-early-$label.pid"
  : > "$descfile"
  set +e
  start=$(date +%s)
  env QUICKLOOK_FORCE_SH=1 QUICKLOOK_FORCE_PORTABLE="$forceportable" \
    sh "$ROOT/compat/quicklookd.sh" --watchdog-selftest 5 "$parent_early" "$ignore" "$descfile"
  st=$?
  end=$(date +%s)
  set -e
  if [ "$((end - start))" -ge 4 ]; then
    echo "FAIL shell early-exit ($label) did not return promptly ($((end - start))s)"
    exit 1
  fi
  sleep 1
  if [ ! -s "$descfile" ]; then
    echo "FAIL shell early-exit parent ($label) did not record descendant pid"
    exit 1
  fi
  dpid=$(tr -d ' \n' < "$descfile")
  if alive "$dpid"; then
    echo "FAIL shell early-exit ($label) left TERM-ignoring descendant pid $dpid alive"
    kill -KILL "$dpid" 2>/dev/null || true
    exit 1
  fi
  echo "ok  shell early-leader-exit ($label) reaps descendant + returns promptly (status $st, pid $dpid)"
}

run_shell_early_case "host-default" ""
run_shell_early_case "forced-portable" "1"

# --- GNU-timeout branch: early leader exit must also reap the descendant ---
# The GNU path now wraps `timeout` in its own process group (setsid) and reaps
# the whole group after the leader exits, identical to the portable path. It is
# the branch a Linux judge machine actually takes. With FORCE_PORTABLE unset the
# script prefers GNU timeout when present, so this deterministically exercises
# gnu_group_watchdog wherever a GNU-style timeout exists; on hosts without one
# (e.g. stock macOS) it is skipped and covered in Linux CI.
if { command -v timeout >/dev/null 2>&1 && timeout --kill-after=1s 1s true >/dev/null 2>&1; } \
   || { command -v gtimeout >/dev/null 2>&1 && gtimeout --kill-after=1s 1s true >/dev/null 2>&1; }; then
  run_shell_early_case "gnu-timeout" ""
else
  echo "ok  shell GNU-timeout early-exit branch: skipped (no GNU timeout on host; exercised in Linux CI)"
fi

# --- Python process-group: same descendant case ---
python3 - << PY
import os, stat, sys, time, subprocess, importlib.util
from pathlib import Path

root = Path("$ROOT")
work = Path("$WORKDIR")
spec = importlib.util.spec_from_file_location("ql", root / "compat" / "quicklookd.py")
ql = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ql)

ignore = work / "py-ignore-term"
ignore.write_text("#!/bin/sh\ntrap '' TERM\nsleep 30\n")
ignore.chmod(ignore.stat().st_mode | stat.S_IXUSR)
parent = work / "py-parent"
parent.write_text("#!/bin/sh\n\"\$1\" &\necho \$! > \"\$2\"\nwait\n")
parent.chmod(parent.stat().st_mode | stat.S_IXUSR)
pidfile = work / "py-desc.pid"
pidfile.write_text("")

def run_case(limits, tag):
    pidfile.write_text("")
    start = time.monotonic()
    try:
        ql.run_killable(
            [str(parent), str(ignore), str(pidfile)],
            timeout_s=2,
            capture_output=True,
            limits=limits,
        )
        sys.stderr.write("FAIL python run_killable (%s) returned without timeout\n" % tag)
        sys.exit(1)
    except subprocess.TimeoutExpired:
        pass
    elapsed = time.monotonic() - start
    if elapsed >= 8:
        sys.stderr.write("FAIL python run_killable (%s) too slow: %.1fs\n" % (tag, elapsed))
        sys.exit(1)
    time.sleep(0.3)
    raw = pidfile.read_text().strip()
    if not raw.isdigit():
        sys.stderr.write("FAIL python parent (%s) did not record descendant pid: %r\n" % (tag, raw))
        sys.exit(1)
    dpid = int(raw)
    try:
        os.kill(dpid, 0)
    except OSError:
        print("ok  python process-group KILL reaps TERM-ignoring descendant [%s] (%.1fs, pid %d)" % (tag, elapsed, dpid))
    else:
        try:
            os.kill(dpid, 9)
        except OSError:
            pass
        sys.stderr.write("FAIL python (%s) left TERM-ignoring descendant pid %d alive\n" % (tag, dpid))
        sys.exit(1)

# Exercise BOTH the production limits=True branch (setsid + rlimits, the path a
# judge actually runs) and the limits=False branch.
run_case(True, "limits=production")
run_case(False, "limits=off")

# --- Early leader exit: leader returns cleanly, descendant lingers ---
# The regression: run_killable's normal-exit path used to skip the group kill and
# then join the drains with a 2s timeout, leaking the TERM-ignoring descendant
# and its reader thread. The fix group-kills whenever the group is non-empty
# before joining, so this must return a CompletedProcess (NOT a timeout), return
# promptly, and leave no descendant alive.
parent_early = work / "py-parent-early"
parent_early.write_text("#!/bin/sh\n\"\$1\" &\necho \$! > \"\$2\"\n")  # no wait: exits now
parent_early.chmod(parent_early.stat().st_mode | stat.S_IXUSR)

def run_early_case(limits, tag):
    pidfile.write_text("")
    start = time.monotonic()
    try:
        cp = ql.run_killable(
            [str(parent_early), str(ignore), str(pidfile)],
            timeout_s=8,
            capture_output=True,
            limits=limits,
        )
    except subprocess.TimeoutExpired:
        sys.stderr.write("FAIL python early-exit (%s) hung into a timeout\n" % tag)
        sys.exit(1)
    elapsed = time.monotonic() - start
    if elapsed >= 4:
        sys.stderr.write("FAIL python early-exit (%s) did not return promptly: %.1fs\n" % (tag, elapsed))
        sys.exit(1)
    time.sleep(0.3)
    raw = pidfile.read_text().strip()
    if not raw.isdigit():
        sys.stderr.write("FAIL python early-exit parent (%s) did not record descendant pid: %r\n" % (tag, raw))
        sys.exit(1)
    dpid = int(raw)
    try:
        os.kill(dpid, 0)
    except OSError:
        print("ok  python early-leader-exit reaps descendant, no hang [%s] (%.1fs, pid %d)" % (tag, elapsed, dpid))
    else:
        try:
            os.kill(dpid, 9)
        except OSError:
            pass
        sys.stderr.write("FAIL python early-exit (%s) left descendant pid %d alive\n" % (tag, dpid))
        sys.exit(1)

run_early_case(True, "limits=production")
run_early_case(False, "limits=off")

# --- Flooding output must be bounded (no OOM / no deadlock) ---
flood = work / "py-flood"
flood.write_text("#!/bin/sh\nexec yes ABCDEFGHIJKLMNOP\n")
flood.chmod(flood.stat().st_mode | stat.S_IXUSR)
start = time.monotonic()
try:
    ql.run_killable([str(flood)], timeout_s=1, capture_output=True, limits=True)
    sys.stderr.write("FAIL flooding child did not time out\n")
    sys.exit(1)
except subprocess.TimeoutExpired as exc:
    out = exc.output or b""
    if isinstance(out, str):
        out = out.encode()
    if len(out) > ql.OUTPUT_CAP:
        sys.stderr.write("FAIL captured output %d exceeds cap %d\n" % (len(out), ql.OUTPUT_CAP))
        sys.exit(1)
elapsed = time.monotonic() - start
if elapsed >= 6:
    sys.stderr.write("FAIL flooding child not killed promptly: %.1fs\n" % elapsed)
    sys.exit(1)
print("ok  python flooding output bounded to <= %d bytes (%.1fs)" % (ql.OUTPUT_CAP, elapsed))
PY
