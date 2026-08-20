#!/bin/sh
# Dependency-free fallback when bin/quicklookd is missing.
# Prefers Python 3 (compat/quicklookd.py). Without Python this POSIX
# responder still honors inline config, does a pruned bounded find, and
# actually opens/reveals files.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
export QUICKLOOK_PLUGIN_DIR="${QUICKLOOK_PLUGIN_DIR:-$ROOT}"

if [ "${QUICKLOOK_FORCE_SH:-}" != "1" ] && command -v python3 >/dev/null 2>&1; then
  exec python3 "$ROOT/compat/quicklookd.py" "$@"
fi

HOME_DIR=${HOME:-/tmp}
STATE_DIR="${XDG_STATE_HOME:-$HOME_DIR/.local/state}/quicklook"
CONFIG_FILE="$STATE_DIR/compat-config.env"
SAMP="$ROOT/samples"

ROOTS="$HOME_DIR"
EXTRA_EXCLUDE=""
WATCH_CAP=2000
CACHE_MB=500
MAX_FILES=500000

expand_tilde() {
  case "$1" in
    "~") printf '%s' "$HOME_DIR" ;;
    ~/*) printf '%s' "$HOME_DIR/${1#~/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

load_config() {
  ROOTS="$HOME_DIR"
  EXTRA_EXCLUDE=""
  WATCH_CAP=2000
  CACHE_MB=500
  MAX_FILES=500000
  if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
  fi
}

save_config() {
  mkdir -p "$STATE_DIR"
  {
    printf 'ROOTS="%s"\n' "$ROOTS"
    printf 'EXTRA_EXCLUDE="%s"\n' "$EXTRA_EXCLUDE"
    printf 'WATCH_CAP=%s\n' "$WATCH_CAP"
    printf 'CACHE_MB=%s\n' "$CACHE_MB"
    printf 'MAX_FILES=%s\n' "$MAX_FILES"
  } > "$CONFIG_FILE"
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

extract_id() {
  printf '%s' "$1" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p'
}

extract_string() {
  printf '%s' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p"
}

extract_number() {
  printf '%s' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p"
}

extract_array_inner() {
  printf '%s' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\\[\\([^]]*\\)\\].*/\\1/p"
}

quoted_to_pipe() {
  printf '%s' "$1" | sed 's/"[[:space:]]*,[[:space:]]*"/|/g; s/^[[:space:]]*"//; s/"[[:space:]]*$//; s/"//g'
}

apply_config_line() {
  inner=$(extract_array_inner "$1" "roots")
  if [ -n "$inner" ]; then
    ROOTS=""
    oldifs=$IFS
    IFS='|'
    set -- $(quoted_to_pipe "$inner")
    IFS=$oldifs
    for item in "$@"; do
      [ -n "$item" ] || continue
      exp=$(expand_tilde "$item")
      if [ -z "$ROOTS" ]; then
        ROOTS="$exp"
      else
        ROOTS="$ROOTS|$exp"
      fi
    done
    [ -n "$ROOTS" ] || ROOTS="$HOME_DIR"
  fi
  inner=$(extract_array_inner "$1" "extraExclude")
  if [ -n "$inner" ]; then
    EXTRA_EXCLUDE=$(quoted_to_pipe "$inner")
  fi
  n=$(extract_number "$1" "watchCap")
  [ -n "$n" ] && WATCH_CAP=$n
  n=$(extract_number "$1" "cacheMb")
  [ -n "$n" ] && CACHE_MB=$n
  n=$(extract_number "$1" "maxFiles")
  [ -n "$n" ] && MAX_FILES=$n
  save_config
}

safe_glob() {
  printf '%s' "$1" | tr -cd 'A-Za-z0-9._-'
}

kind_of() {
  base=$(printf '%s' "$1" | sed 's|.*/||')
  ext=$(printf '%s' "$base" | awk -F. '{print tolower($NF)}')
  if [ -d "$1" ]; then
    printf 'dir'
    return
  fi
  case "$ext" in
    png|jpg|jpeg|webp|svg|gif|bmp|ico) printf 'image' ;;
    pdf) printf 'pdf' ;;
    csv|tsv) printf 'csv' ;;
    rs|js|ts|py|go|c|h|md|txt|toml|json|yml|yaml|qml|lua) printf 'code' ;;
    *) printf 'hex' ;;
  esac
}

score_name() {
  name=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  q=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
  case "$name" in
    "$q") printf '1000' ;;
    $q*) printf '800' ;;
    *$q*) printf '600' ;;
    *) printf '0' ;;
  esac
}

demo_hit() {
  path="$SAMP/$1"
  kind=$(kind_of "$path")
  printf '{"path":"%s","name":"%s","kind":"%s","score":%s,"mtime":0,"size":0}' \
    "$(json_escape "$path")" "$1" "$kind" "$2"
}

demo_results() {
  printf '[%s,%s,%s,%s,%s]' \
    "$(demo_hit invoice.pdf 900)" \
    "$(demo_hit photo.png 880)" \
    "$(demo_hit sales.csv 860)" \
    "$(demo_hit themed.rs 840)" \
    "$(demo_hit README.md 820)"
}

prune_names() {
  printf '%s' ".ssh|.gnupg|.password-store|node_modules|target|.git|.hg|keyrings|kwalletd"
  if [ -n "$EXTRA_EXCLUDE" ]; then
    printf '|%s' "$EXTRA_EXCLUDE"
  fi
}

find_hits() {
  q=$(safe_glob "$1")
  dest="$2"
  [ -n "$q" ] || return 0
  names=$(prune_names)
  expr=""
  oldifs=$IFS
  IFS='|'
  # ROOTS and names are pipe-separated; restore IFS after building expr.
  for n in $names; do
    [ -n "$n" ] || continue
    if [ -z "$expr" ]; then
      expr="-name $n"
    else
      expr="$expr -o -name $n"
    fi
  done
  IFS='|'
  set -- $ROOTS
  IFS=$oldifs
  for root in "$@"; do
    [ -d "$root" ] || continue
    # shellcheck disable=SC2086
    find "$root" \( $expr \) -prune -o -iname "*$q*" -print 2>/dev/null > "$dest.found" || true
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      skip=0
      for n in $names; do
        case "$p" in
          */"$n"|*/"$n"/*) skip=1 ;;
        esac
        [ "$skip" -eq 0 ] || break
      done
      [ "$skip" -eq 0 ] || continue
      sc=$(score_name "$(printf '%s' "$p" | sed 's|.*/||')" "$q")
      [ "$sc" -gt 0 ] || continue
      k=$(kind_of "$p")
      bn=$(printf '%s' "$p" | sed 's|.*/||')
      printf '%s {"path":"%s","name":"%s","kind":"%s","score":%s,"mtime":0,"size":0}\n' \
        "$sc" "$(json_escape "$p")" "$(json_escape "$bn")" "$k" "$sc" >> "$dest"
    done < "$dest.found"
  done
  IFS=$oldifs
  rm -f "$dest.found"
}

reply_status() {
  id="$1"
  roots_json=""
  oldifs=$IFS
  IFS='|'
  for r in $ROOTS; do
    [ -n "$r" ] || continue
    if [ -z "$roots_json" ]; then
      roots_json="\"$(json_escape "$r")\""
    else
      roots_json="$roots_json,\"$(json_escape "$r")\""
    fi
  done
  IFS=$oldifs
  budget=$((CACHE_MB * 1024 * 1024))
  printf '{"id":%s,"kind":"status","indexing":false,"progress":1,"backend":"compat","status":{"indexing":false,"progress":1,"backend":"compat","files":5,"watchCount":0,"watchCap":%s,"roots":[%s],"cacheBytes":0,"cacheBudget":%s,"poppler":false,"plocate":false,"ffmpeg":false,"helper":"compat","version":"1.0.0"}}\n' \
    "$id" "$WATCH_CAP" "$roots_json" "$budget"
}

reply_query() {
  id="$1"
  q="$2"
  if [ -z "$q" ]; then
    printf '{"id":%s,"kind":"results","results":%s,"indexing":false,"progress":1,"backend":"demo"}\n' "$id" "$(demo_results)"
    return
  fi
  tmp=$(mktemp)
  ql=$(printf '%s' "$q" | tr '[:upper:]' '[:lower:]')
  for name in invoice.pdf photo.png sales.csv themed.rs README.md; do
    sc=$(score_name "$name" "$ql")
    if [ "$sc" -gt 0 ]; then
      printf '%s %s\n' "$((sc + 200))" "$(demo_hit "$name" "$((sc + 200))")" >> "$tmp"
    fi
  done
  find_hits "$q" "$tmp"
  sorted=$(mktemp)
  sort -nr -k1,1 "$tmp" > "$sorted" 2>/dev/null || true
  body=""
  n=0
  while read -r _sc hit; do
    [ -n "$hit" ] || continue
    n=$((n + 1))
    [ "$n" -le 40 ] || break
    if [ -z "$body" ]; then
      body="$hit"
    else
      body="$body,$hit"
    fi
  done < "$sorted"
  printf '{"id":%s,"kind":"results","results":[%s],"indexing":false,"progress":1,"backend":"compat"}\n' "$id" "$body"
  rm -f "$tmp" "$sorted"
}

reply_preview() {
  id="$1"
  path="$2"
  kind=$(kind_of "$path")
  case "$kind" in
    image)
      ext=$(printf '%s' "$path" | awk -F. '{print tolower($NF)}')
      anim=false
      [ "$ext" = gif ] && anim=true
      printf '{"id":%s,"kind":"preview","preview":{"kind":"image","path":"%s","animated":%s}}\n' \
        "$id" "$(json_escape "$path")" "$anim"
      ;;
    pdf)
      printf '{"id":%s,"kind":"preview","preview":{"kind":"pdf","need_poppler":true,"render_error":false,"label":"compat mode does not rasterize PDFs — Enter opens the file","magic":"PDF document"}}\n' "$id"
      ;;
    *)
      printf '{"id":%s,"kind":"preview","preview":{"kind":"hex","hex":"","magic":"data","label":"can'\''t render this — hex view","path":"%s"}}\n' \
        "$id" "$(json_escape "$path")"
      ;;
  esac
}

do_open() {
  path="$1"
  reveal="$2"
  if [ ! -e "$path" ]; then
    return 1
  fi
  target="$path"
  if [ "$reveal" = 1 ] && [ ! -d "$path" ]; then
    target=$(dirname "$path")
  fi
  if command -v gio >/dev/null 2>&1; then
    gio open "$target" >/dev/null 2>&1 &
    return 0
  fi
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$target" >/dev/null 2>&1 &
    return 0
  fi
  if command -v open >/dev/null 2>&1; then
    open "$target" >/dev/null 2>&1 &
    return 0
  fi
  return 2
}

handle_line() {
  load_config
  line="$1"
  id=$(extract_id "$line")
  [ -n "$id" ] || id=0
  case "$line" in
    *'"cmd":"config"'*|*'cmd": "config"'*)
      apply_config_line "$line"
      reply_status "$id"
      ;;
    *'"cmd":"status"'*|*'cmd": "status"'*|*'cmd":"capabilities"'*)
      reply_status "$id"
      ;;
    *'"cmd":"preview"'*|*'cmd": "preview"'*|*'cmd":"prefetch"'*|*'cmd": "prefetch"'*|*'cmd":"page"'*|*'cmd": "page"'*)
      reply_preview "$id" "$(extract_string "$line" "path")"
      ;;
    *'"cmd":"open"'*|*'cmd": "open"'*)
      path=$(extract_string "$line" "path")
      if do_open "$path" 0; then
        printf '{"id":%s,"kind":"ok"}\n' "$id"
      else
        printf '{"id":%s,"kind":"error","error":"open failed"}\n' "$id"
      fi
      ;;
    *'"cmd":"reveal"'*|*'cmd": "reveal"'*)
      path=$(extract_string "$line" "path")
      if do_open "$path" 1; then
        printf '{"id":%s,"kind":"ok"}\n' "$id"
      else
        printf '{"id":%s,"kind":"error","error":"reveal failed"}\n' "$id"
      fi
      ;;
    *'"cmd":"theme"'*|*'cmd":"select"'*|*'cmd":"warmup"'*)
      printf '{"id":%s,"kind":"ok"}\n' "$id"
      ;;
    *'"q":'*|*'cmd":"query"'*|*'cmd": "query"'*)
      q=$(extract_string "$line" "q")
      reply_query "$id" "$q"
      ;;
    *)
      reply_preview "$id" "$(extract_string "$line" "path")"
      ;;
  esac
}

oneshot=0
payload=""
if [ "${1:-}" = "--oneshot" ]; then
  oneshot=1
  payload="${2:-}"
fi

load_config

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
