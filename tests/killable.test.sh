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
