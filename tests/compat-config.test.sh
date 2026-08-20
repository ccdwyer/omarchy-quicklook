#!/bin/sh
# Compat helper must honor inline config (roots / extraExclude), not hard-coded HOME.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
export QUICKLOOK_PLUGIN_DIR="$ROOT"
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
export HOME="$WORKDIR/home"
export XDG_STATE_HOME="$WORKDIR/state"
export XDG_CACHE_HOME="$WORKDIR/cache"
mkdir -p "$HOME/keep" "$HOME/skipme" "$HOME/Documents"
printf 'keep-invoice\n' > "$HOME/keep/invoice-note.txt"
printf 'secret\n' > "$HOME/skipme/invoice-secret.txt"
printf 'docs\n' > "$HOME/Documents/other.txt"

python3 "$ROOT/compat/quicklookd.py" --oneshot '{"id":1,"cmd":"config","roots":["'"$HOME/keep"'"],"extraExclude":["skipme"]}' >/dev/null

out=$(python3 "$ROOT/compat/quicklookd.py" --oneshot '{"id":2,"cmd":"query","q":"invoice"}')
echo "$out" | grep -q invoice-note || { echo "FAIL expected keep/invoice-note"; echo "$out"; exit 1; }
echo "$out" | grep -q invoice-secret && { echo "FAIL leaked extraExclude path"; echo "$out"; exit 1; }
echo "$out" | grep -q Documents && { echo "FAIL searched hard-coded Documents"; echo "$out"; exit 1; }

st=$(python3 "$ROOT/compat/quicklookd.py" --oneshot '{"id":3,"cmd":"status"}')
echo "$st" | grep -q "$HOME/keep" || { echo "FAIL status roots"; echo "$st"; exit 1; }
echo "ok  compat config roots + extraExclude"

export QUICKLOOK_FORCE_SH=1
sh "$ROOT/compat/quicklookd.sh" --oneshot '{"id":4,"cmd":"config","roots":["'"$HOME/keep"'"],"extraExclude":["skipme"]}' >/dev/null
shout=$(sh "$ROOT/compat/quicklookd.sh" --oneshot '{"id":5,"cmd":"query","q":"invoice"}')
echo "$shout" | grep -q invoice-note || { echo "FAIL sh expected keep/invoice-note"; echo "$shout"; exit 1; }
echo "$shout" | grep -q invoice-secret && { echo "FAIL sh leaked extraExclude"; echo "$shout"; exit 1; }
echo "$shout" | grep -q Documents && { echo "FAIL sh searched Documents"; echo "$shout"; exit 1; }
shst=$(sh "$ROOT/compat/quicklookd.sh" --oneshot '{"id":6,"cmd":"status"}')
echo "$shst" | grep -q "$HOME/keep" || { echo "FAIL sh status roots"; echo "$shst"; exit 1; }
missing=$(sh "$ROOT/compat/quicklookd.sh" --oneshot '{"id":7,"cmd":"open","path":"/no/such/quicklook-file"}')
echo "$missing" | grep -q error || { echo "FAIL sh open missing should error"; echo "$missing"; exit 1; }
echo "ok  posix fallback config + search + open"
