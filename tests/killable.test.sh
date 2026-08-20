#!/bin/sh
# Behavioral: TERM-ignoring children must still be reaped by KILL.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

fake="$WORKDIR/ignore-term"
cat > "$fake" << 'EOF'
#!/bin/sh
trap '' TERM
sleep 30
EOF
chmod +x "$fake"

# --- POSIX watchdog (real helper entry) ---
start=$(date +%s)
export QUICKLOOK_FORCE_SH=1
set +e
sh "$ROOT/compat/quicklookd.sh" --watchdog-selftest 2 "$fake"
st=$?
set -e
end=$(date +%s)
elapsed=$((end - start))
if [ "$elapsed" -ge 8 ]; then
  echo "FAIL shell watchdog left TERM-ignoring child alive too long (${elapsed}s)"
  exit 1
fi
# Child must be gone.
if pgrep -f "$fake" >/dev/null 2>&1; then
  # pgrep -f can match this script; check exact pid file
  leftover=$(ps -ax -o pid= -o command= | grep -F "$fake" | grep -v grep || true)
  if [ -n "$leftover" ]; then
    echo "FAIL shell watchdog did not KILL TERM-ignoring child: $leftover"
    exit 1
  fi
fi
echo "ok  posix watchdog KILL reaps TERM-ignoring child (${elapsed}s, status $st)"

# --- Python process-group opener ---
python3 - << PY
import os, stat, sys, time, subprocess, importlib.util
from pathlib import Path

root = Path(os.environ.get("QUICKLOOK_PLUGIN_DIR", "$ROOT"))
work = Path("$WORKDIR")
spec = importlib.util.spec_from_file_location("ql", root / "compat" / "quicklookd.py")
ql = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ql)

fake = work / "py-ignore-term"
fake.write_text("#!/bin/sh\ntrap '' TERM\nsleep 30\n")
fake.chmod(fake.stat().st_mode | stat.S_IXUSR)

start = time.monotonic()
try:
    ql.run_killable([str(fake)], timeout_s=2, limits=False)
    sys.stderr.write("FAIL python run_killable returned without timeout\n")
    sys.exit(1)
except subprocess.TimeoutExpired:
    pass
elapsed = time.monotonic() - start
if elapsed >= 8:
    sys.stderr.write("FAIL python run_killable too slow: %.1fs\n" % elapsed)
    sys.exit(1)

# Hung fake opener via open_path
bindir = work / "bin"
bindir.mkdir(exist_ok=True)
gio = bindir / "gio"
gio.write_text("#!/bin/sh\ntrap '' TERM\nsleep 30\n")
gio.chmod(gio.stat().st_mode | stat.S_IXUSR)
os.environ["PATH"] = str(bindir) + os.pathsep + os.environ.get("PATH", "")
target = work / "doc.txt"
target.write_text("x\n")
start = time.monotonic()
result = ql.open_path(str(target))
elapsed = time.monotonic() - start
if elapsed >= 12:
    sys.stderr.write("FAIL python open_path too slow: %.1fs\n" % elapsed)
    sys.exit(1)
if result.get("ok") is True:
    sys.stderr.write("FAIL hung opener reported ok: %s\n" % result)
    sys.exit(1)
print("ok  python process-group KILL reaps TERM-ignoring opener (%.1fs)" % elapsed)
PY
