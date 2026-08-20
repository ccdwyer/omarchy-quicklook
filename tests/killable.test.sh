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

# --- POSIX watchdog: descendant PID must disappear ---
descfile="$WORKDIR/desc.pid"
: > "$descfile"
export QUICKLOOK_FORCE_SH=1
set +e
sh "$ROOT/compat/quicklookd.sh" --watchdog-selftest 2 "$parent" "$ignore" "$descfile"
st=$?
set -e
sleep 1
if [ ! -s "$descfile" ]; then
  echo "FAIL shell parent did not record descendant pid"
  exit 1
fi
dpid=$(tr -d ' \n' < "$descfile")
if alive "$dpid"; then
  echo "FAIL shell watchdog left TERM-ignoring descendant pid $dpid alive"
  kill -KILL "$dpid" 2>/dev/null || true
  exit 1
fi
echo "ok  posix watchdog KILL reaps TERM-ignoring descendant (status $st, pid $dpid)"

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

start = time.monotonic()
try:
    ql.run_killable(
        [str(parent), str(ignore), str(pidfile)],
        timeout_s=2,
        limits=False,
    )
    sys.stderr.write("FAIL python run_killable returned without timeout\n")
    sys.exit(1)
except subprocess.TimeoutExpired:
    pass
elapsed = time.monotonic() - start
if elapsed >= 8:
    sys.stderr.write("FAIL python run_killable too slow: %.1fs\n" % elapsed)
    sys.exit(1)
time.sleep(0.3)
raw = pidfile.read_text().strip()
if not raw.isdigit():
    sys.stderr.write("FAIL python parent did not record descendant pid: %r\n" % raw)
    sys.exit(1)
dpid = int(raw)
try:
    os.kill(dpid, 0)
except OSError:
    print("ok  python process-group KILL reaps TERM-ignoring descendant (%.1fs, pid %d)" % (elapsed, dpid))
else:
    try:
        os.kill(dpid, 9)
    except OSError:
        pass
    sys.stderr.write("FAIL python left TERM-ignoring descendant pid %d alive\n" % dpid)
    sys.exit(1)
PY
