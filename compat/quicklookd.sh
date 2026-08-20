#!/bin/sh
# Fallback helper when bin/quicklookd is missing. Prefers Python 3 for JSON;
# otherwise answers status + demo-corpus queries with a tiny POSIX responder.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
export QUICKLOOK_PLUGIN_DIR="${QUICKLOOK_PLUGIN_DIR:-$ROOT}"

if command -v python3 >/dev/null 2>&1; then
  exec python3 "$ROOT/compat/quicklookd.py" "$@"
fi

oneshot=0
payload=""
if [ "${1:-}" = "--oneshot" ]; then
  oneshot=1
  payload="${2:-}"
fi

demo_results() {
  samp="$ROOT/samples"
  printf '%s' "[{\"path\":\"$samp/invoice.pdf\",\"name\":\"invoice.pdf\",\"kind\":\"pdf\",\"score\":900,\"mtime\":0,\"size\":0},{\"path\":\"$samp/photo.png\",\"name\":\"photo.png\",\"kind\":\"image\",\"score\":880,\"mtime\":0,\"size\":0},{\"path\":\"$samp/sales.csv\",\"name\":\"sales.csv\",\"kind\":\"csv\",\"score\":860,\"mtime\":0,\"size\":0},{\"path\":\"$samp/themed.rs\",\"name\":\"themed.rs\",\"kind\":\"code\",\"score\":840,\"mtime\":0,\"size\":0},{\"path\":\"$samp/README.md\",\"name\":\"README.md\",\"kind\":\"code\",\"score\":820,\"mtime\":0,\"size\":0}]"
}

reply_status() {
  id="$1"
  printf '{"id":%s,"kind":"status","indexing":false,"progress":1,"backend":"compat","status":{"indexing":false,"progress":1,"backend":"compat","files":5,"watchCount":0,"watchCap":2000,"roots":[],"cacheBytes":0,"cacheBudget":524288000,"poppler":false,"plocate":false,"ffmpeg":false,"helper":"compat","version":"1.0.0"}}\n' "$id"
}

reply_demo() {
  id="$1"
  printf '{"id":%s,"kind":"results","results":%s,"indexing":false,"progress":1,"backend":"demo"}\n' "$id" "$(demo_results)"
}

handle_line() {
  line="$1"
  id=$(printf '%s' "$line" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
  [ -n "$id" ] || id=0
  case "$line" in
    *'"cmd":"status"'*|*'cmd": "status"'*) reply_status "$id" ;;
    *'"q":'*|*'cmd":"query"'*) reply_demo "$id" ;;
    *) printf '{"id":%s,"kind":"error","error":"compat-shell: install python3 for previews"}\n' "$id" ;;
  esac
}

if [ "$oneshot" -eq 1 ]; then
  if [ -z "$payload" ]; then
    IFS= read -r payload || payload="{}"
  fi
  handle_line "$payload"
  exit 0
fi

while IFS= read -r line; do
  [ -n "$line" ] || continue
  handle_line "$line"
done
