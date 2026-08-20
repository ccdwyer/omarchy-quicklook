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

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

reply_preview() {
  id="$1"
  line="$2"
  path=$(printf '%s' "$line" | sed -n 's/.*"path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  base=$(printf '%s' "$path" | sed 's|.*/||')
  ext=$(printf '%s' "$base" | awk -F. '{print tolower($NF)}')
  case "$ext" in
    png|jpg|jpeg|webp|svg|gif|bmp|ico)
      printf '{"id":%s,"kind":"preview","preview":{"kind":"image","path":"%s","animated":%s}}\n' \
        "$id" "$(json_escape "$path")" "$( [ "$ext" = gif ] && echo true || echo false )"
      ;;
    pdf)
      printf '{"id":%s,"kind":"preview","preview":{"kind":"pdf","need_poppler":true,"render_error":false,"label":"install poppler for PDF previews","magic":"PDF document"}}\n' "$id"
      ;;
    *)
      printf '{"id":%s,"kind":"preview","preview":{"kind":"hex","hex":"","magic":"data","label":"can'\''t render this — hex view","path":"%s"}}\n' \
        "$id" "$(json_escape "$path")"
      ;;
  esac
}

handle_line() {
  line="$1"
  id=$(printf '%s' "$line" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
  [ -n "$id" ] || id=0
  case "$line" in
    *'"cmd":"status"'*|*'cmd": "status"'*|*'cmd":"config"'*|*'cmd": "config"'*) reply_status "$id" ;;
    *'"cmd":"preview"'*|*'cmd": "preview"'*|*'cmd":"prefetch"'*|*'cmd": "prefetch"'*|*'cmd":"page"'*|*'cmd": "page"'*)
      reply_preview "$id" "$line"
      ;;
    *'"q":'*|*'cmd":"query"'*|*'cmd": "query"'*) reply_demo "$id" ;;
    *'"cmd":"theme"'*|*'cmd":"select"'*|*'cmd":"warmup"'*|*'cmd":"open"'*|*'cmd":"reveal"'*)
      printf '{"id":%s,"kind":"ok"}\n' "$id"
      ;;
    *)
      # Unknown: still return a usable hex preview so the pane never sticks.
      reply_preview "$id" "$line"
      ;;
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
