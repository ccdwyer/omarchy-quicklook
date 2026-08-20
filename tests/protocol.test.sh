#!/bin/sh
# Oneshot protocol smoke against the helper if it has been built.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
BIN=""
if [ -x "$ROOT/bin/quicklookd" ]; then
  BIN="$ROOT/bin/quicklookd"
elif [ -x "$ROOT/src/quicklookd/target/debug/quicklookd" ]; then
  BIN="$ROOT/src/quicklookd/target/debug/quicklookd"
else
  echo "skip  no quicklookd binary (compat path)"
  if command -v python3 >/dev/null 2>&1; then
    export QUICKLOOK_PLUGIN_DIR="$ROOT"
    out=$(python3 "$ROOT/compat/quicklookd.py" --oneshot '{"q":"invoice","id":41}')
    echo "$out" | grep -q '"kind":' || { echo "FAIL compat results"; echo "$out"; exit 1; }
    echo "$out" | grep -q results || { echo "FAIL compat kind"; echo "$out"; exit 1; }
    echo "$out" | grep -q invoice.pdf || { echo "FAIL compat invoice"; echo "$out"; exit 1; }
    echo "ok  compat oneshot query"
    exit 0
  fi
  echo "skip  no python3 either"
  exit 0
fi

export QUICKLOOK_PLUGIN_DIR="$ROOT"
out=$("$BIN" --plugin-dir "$ROOT" --root "$ROOT/samples" --oneshot '{"q":"invoice","id":41}')
echo "$out" | grep -q '"id":41' || { echo "FAIL id"; echo "$out"; exit 1; }
echo "$out" | grep -q results || { echo "FAIL kind"; echo "$out"; exit 1; }
echo "$out" | grep -q invoice.pdf || { echo "FAIL invoice rank"; echo "$out"; exit 1; }
echo "ok  oneshot query"

st=$("$BIN" --plugin-dir "$ROOT" --oneshot '{"id":2,"cmd":"status"}')
echo "$st" | grep -q '"kind":"status"' || { echo "FAIL status"; echo "$st"; exit 1; }
echo "ok  oneshot status"
