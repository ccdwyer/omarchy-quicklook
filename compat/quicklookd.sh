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

# One watchdog for every path-consuming command: new process group, TERM the
# group, grace, then UNCONDITIONAL KILL of the group. GNU timeout already
# uses a new process group + --kill-after. The portable path needs setsid
# (or python os.setsid). If neither isolation method exists, skip.
TIMEOUT_BIN=""
TIMEOUT_STYLE=""
HAVE_SETSID=0
SETSID_PY=0

init_watchdog() {
  if command -v timeout >/dev/null 2>&1; then
    if timeout --kill-after=1s 1s true >/dev/null 2>&1; then
      TIMEOUT_BIN=timeout
      TIMEOUT_STYLE=gnu-long
    elif timeout -k 1 1 true >/dev/null 2>&1; then
      TIMEOUT_BIN=timeout
      TIMEOUT_STYLE=gnu-short
    fi
  fi
  if [ -z "$TIMEOUT_STYLE" ] && command -v gtimeout >/dev/null 2>&1; then
    if gtimeout --kill-after=1s 1s true >/dev/null 2>&1; then
      TIMEOUT_BIN=gtimeout
      TIMEOUT_STYLE=gnu-long
    fi
  fi
  if command -v setsid >/dev/null 2>&1; then
    HAVE_SETSID=1
  elif command -v python3 >/dev/null 2>&1; then
    SETSID_PY=1
  fi
}

init_watchdog

watchdog_ok() {
  # GNU timeout creates and kills a process group. Otherwise we need setsid.
  if [ -n "$TIMEOUT_STYLE" ]; then
    return 0
  fi
  [ "$HAVE_SETSID" = 1 ] || [ "$SETSID_PY" = 1 ]
}

spawn_group() {
  if [ "$HAVE_SETSID" = 1 ]; then
    setsid "$@" &
    return
  fi
  python3 -c 'import os, sys
os.setsid()
os.execvp(sys.argv[1], sys.argv[1:])
' "$@" &
}

# Portable: own process group, TERM the group, then KILL the group.
portable_watchdog() {
  secs=$1
  shift
  spawn_group "$@"
  pid=$!
  pgid=$pid
  (
    n=0
    while [ "$n" -lt "$secs" ]; do
      sleep 1
      n=$((n + 1))
      kill -0 "$pid" 2>/dev/null || exit 0
    done
    kill -TERM -"$pgid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    sleep 1
    kill -KILL -"$pgid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  ) &
  killer=$!
  st=0
  wait "$pid" || st=$?
  # Unconditional group KILL even if the leader already exited.
  kill -KILL -"$pgid" 2>/dev/null || true
  kill -KILL "$killer" 2>/dev/null || true
  wait "$killer" 2>/dev/null || true
  return $st
}

run_watchdog() {
  secs=$1
  shift
  [ "$#" -ge 1 ] || return 1
  watchdog_ok || return 124
  case "$TIMEOUT_STYLE" in
    gnu-long)
      "$TIMEOUT_BIN" --kill-after=1s "${secs}s" "$@"
      ;;
    gnu-short)
      "$TIMEOUT_BIN" -k 1 "$secs" "$@"
      ;;
    *)
      portable_watchdog "$secs" "$@"
      ;;
  esac
}

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

# Config is a tagged line file (never sourced / eval'd).
#   R<TAB>absolute-root
#   E<TAB>exclude-name
#   W<TAB>watchCap
#   C<TAB>cacheMb
#   M<TAB>maxFiles
load_config() {
  ROOTS="$HOME_DIR"
  EXTRA_EXCLUDE=""
  WATCH_CAP=2000
  CACHE_MB=500
  MAX_FILES=500000
  [ -f "$CONFIG_FILE" ] || return 0
  loaded_roots=""
  while IFS= read -r line || [ -n "$line" ]; do
    tag=${line%%	*}
    val=${line#*	}
    case "$tag" in
      R)
        [ -n "$val" ] || continue
        if [ -z "$loaded_roots" ]; then
          loaded_roots=$val
        else
          loaded_roots="$loaded_roots|$val"
        fi
        ;;
      E)
        [ -n "$val" ] || continue
        if [ -z "$EXTRA_EXCLUDE" ]; then
          EXTRA_EXCLUDE=$val
        else
          EXTRA_EXCLUDE="$EXTRA_EXCLUDE|$val"
        fi
        ;;
      W) WATCH_CAP=$val ;;
      C) CACHE_MB=$val ;;
      M) MAX_FILES=$val ;;
    esac
  done < "$CONFIG_FILE"
  [ -n "$loaded_roots" ] && ROOTS=$loaded_roots
}

save_config() {
  mkdir -p "$STATE_DIR"
  : > "$CONFIG_FILE"
  oldifs=$IFS
  IFS='|'
  for r in $ROOTS; do
    [ -n "$r" ] || continue
    printf 'R\t%s\n' "$r" >> "$CONFIG_FILE"
  done
  for e in $EXTRA_EXCLUDE; do
    [ -n "$e" ] || continue
    printf 'E\t%s\n' "$e" >> "$CONFIG_FILE"
  done
  IFS=$oldifs
  printf 'W\t%s\n' "$WATCH_CAP" >> "$CONFIG_FILE"
  printf 'C\t%s\n' "$CACHE_MB" >> "$CONFIG_FILE"
  printf 'M\t%s\n' "$MAX_FILES" >> "$CONFIG_FILE"
}

json_escape() {
  # JSON string contents: \, ", C0 controls (including newline).
  printf '%s' "$1" | od -An -t u1 -v | awk '
    BEGIN { ORS="" }
    {
      for (i = 1; i <= NF; i++) {
        n = $i + 0
        if (n == 92) printf "\\\\"
        else if (n == 34) printf "\\\""
        else if (n == 10) printf "\\n"
        else if (n == 13) printf "\\r"
        else if (n == 9) printf "\\t"
        else if (n < 32) printf "\\u%04x", n
        else printf "%c", n
      }
    }
  '
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
    "$q"*) printf '800' ;;
    *"$q"*) printf '600' ;;
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
  printf '%s' ".ssh|.gnupg|.password-store|node_modules|target|.git|.hg|.svn|.bzr|__pycache__|.venv|venv|.tox|.mypy_cache|.pytest_cache|.cargo|.rustup|.npm|.cache|.Trash|.local|keyrings|kwalletd|Keychains"
  if [ -n "$EXTRA_EXCLUDE" ]; then
    printf '|%s' "$EXTRA_EXCLUDE"
  fi
}

is_secret_file() {
  case "$1" in
    .env|.env.*|*.env) return 0 ;;
    id_rsa|id_ed25519|id_rsa.*) return 0 ;;
  esac
  return 1
}

path_is_secret() {
  case "$1" in
    */.ssh/*|*/.gnupg/*|*/.password-store/*|*/.local/share/keyrings/*|*/.local/share/kwalletd/*|*/Library/Keychains/*)
      return 0
      ;;
  esac
  is_secret_file "$(printf '%s' "$1" | sed 's|.*/||')"
}

hidden_ancestor() {
  # Skip hidden/heavy directories unless they are an explicit root.
  cur=$(dirname "$1")
  while [ -n "$cur" ] && [ "$cur" != "/" ]; do
    skip_this=0
    oldifs=$IFS
    IFS='|'
    for r in $ROOTS; do
      [ "$cur" = "$r" ] && skip_this=1
    done
    IFS=$oldifs
    [ "$skip_this" -eq 0 ] || return 1
    base=$(printf '%s' "$cur" | sed 's|.*/||')
    case "$base" in
      .*) return 0 ;;
    esac
    oldifs=$IFS
    IFS='|'
    for n in $(prune_names); do
      [ "$base" = "$n" ] && return 0
    done
    IFS=$oldifs
    np=$(dirname "$cur")
    [ "$np" = "$cur" ] && break
    cur=$np
  done
  return 1
}

append_hit() {
  dest="$1"
  p="$2"
  q="$3"
  path_is_secret "$p" && return 0
  hidden_ancestor "$p" && return 0
  sc=$(score_name "$(printf '%s' "$p" | sed 's|.*/||')" "$q")
  [ "$sc" -gt 0 ] || return 0
  k=$(kind_of "$p")
  bn=$(printf '%s' "$p" | sed 's|.*/||')
  printf '%s {"path":"%s","name":"%s","kind":"%s","score":%s,"mtime":0,"size":0}\n' \
    "$sc" "$(json_escape "$p")" "$(json_escape "$bn")" "$k" "$sc" >> "$dest"
}

run_capped_find() {
  root="$1"
  q="$2"
  out="$3"
  names=$(prune_names)
  set -f
  set -- find "$root" -mindepth 1 -maxdepth 6 '(' -name '.*'
  oldifs=$IFS
  IFS='|'
  for n in $names; do
    [ -n "$n" ] || continue
    set -- "$@" -o -name "$n"
  done
  IFS=$oldifs
  set -- "$@" ')' -prune -o -iname "*$q*" -print
  set +f
  run_watchdog 2 "$@" > "$out" 2>/dev/null || true
}

find_hits() {
  q=$(safe_glob "$1")
  dest="$2"
  [ -n "$q" ] || return 0
  raw=$(mktemp)
  located=$(mktemp)
  if command -v plocate >/dev/null 2>&1; then
    run_watchdog 2 plocate -il 40 -- "$q" > "$located" 2>/dev/null || true
  elif command -v locate >/dev/null 2>&1; then
    run_watchdog 2 locate -il 40 -- "$q" > "$located" 2>/dev/null || true
  fi
  if [ -s "$located" ]; then
    while IFS= read -r lp; do
      [ -n "$lp" ] || continue
      under=0
      oldifs=$IFS
      IFS='|'
      for root in $ROOTS; do
        case "$lp" in
          "$root"|"$root"/*) under=1 ;;
        esac
      done
      IFS=$oldifs
      [ "$under" -eq 1 ] && printf '%s\n' "$lp" >> "$raw"
    done < "$located"
  fi
  rm -f "$located"
  if [ ! -s "$raw" ]; then
    oldifs=$IFS
    IFS='|'
    set -- $ROOTS
    IFS=$oldifs
    : > "$raw"
    for root in "$@"; do
      [ -d "$root" ] || continue
      part=$(mktemp)
      run_capped_find "$root" "$q" "$part"
      cat "$part" >> "$raw" 2>/dev/null || true
      rm -f "$part"
    done
  fi
  n=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    n=$((n + 1))
    [ "$n" -le 80 ] || break
    append_hit "$dest" "$p" "$q"
  done < "$raw"
  rm -f "$raw"
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
  poppler=false
  command -v pdftoppm >/dev/null 2>&1 && poppler=true
  plocate=false
  { command -v plocate >/dev/null 2>&1 || command -v locate >/dev/null 2>&1; } && plocate=true
  printf '{"id":%s,"kind":"status","indexing":false,"progress":1,"backend":"compat","status":{"indexing":false,"progress":1,"backend":"compat","files":5,"watchCount":0,"watchCap":%s,"roots":[%s],"cacheBytes":0,"cacheBudget":%s,"poppler":%s,"plocate":%s,"ffmpeg":false,"helper":"compat","version":"1.0.0"}}\n' \
    "$id" "$WATCH_CAP" "$roots_json" "$budget" "$poppler" "$plocate"
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

png_wh() {
  hex=$(read_user_file dd if="$1" bs=1 skip=16 count=8 2>/dev/null | od -An -tx1 | tr -cd '0-9a-f')
  [ "${#hex}" -ge 16 ] || return 1
  w=$(printf '%d' "0x$(printf '%s' "$hex" | cut -c1-8)")
  h=$(printf '%d' "0x$(printf '%s' "$hex" | cut -c9-16)")
  [ "$w" -gt 0 ] && [ "$h" -gt 0 ] || return 1
  printf '%s %s' "$w" "$h"
}

gif_wh() {
  hex=$(read_user_file dd if="$1" bs=1 skip=6 count=4 2>/dev/null | od -An -tx1 | tr -cd '0-9a-f')
  [ "${#hex}" -ge 8 ] || return 1
  w=$(printf '%d' "0x$(printf '%s' "$hex" | cut -c3-4)$(printf '%s' "$hex" | cut -c1-2)")
  h=$(printf '%d' "0x$(printf '%s' "$hex" | cut -c7-8)$(printf '%s' "$hex" | cut -c5-6)")
  [ "$w" -gt 0 ] && [ "$h" -gt 0 ] || return 1
  printf '%s %s' "$w" "$h"
}

svg_wh() {
  head=$(read_user_file dd if="$1" bs=1 count=8192 2>/dev/null)
  vb=$(printf '%s' "$head" | tr '\n' ' ' | sed -n 's/.*[Vv]iew[Bb]ox=["'\'']\([^"'\'']*\)["'\''].*/\1/p')
  if [ -n "$vb" ]; then
    set -- $vb
    if [ "$#" -ge 4 ]; then
      w=$(printf '%s' "$3" | tr -cd '0-9.')
      h=$(printf '%s' "$4" | tr -cd '0-9.')
      w=${w%%.*}
      h=${h%%.*}
      [ -n "$w" ] && [ -n "$h" ] && [ "$w" -gt 0 ] && [ "$h" -gt 0 ] || return 1
      printf '%s %s' "$w" "$h"
      return 0
    fi
  fi
  w=$(printf '%s' "$head" | tr '\n' ' ' | sed -n 's/.*[Ww]idth=["'\'']\([0-9.][0-9.]*\).*/\1/p')
  h=$(printf '%s' "$head" | tr '\n' ' ' | sed -n 's/.*[Hh]eight=["'\'']\([0-9.][0-9.]*\).*/\1/p')
  w=${w%%.*}
  h=${h%%.*}
  [ -n "$w" ] && [ -n "$h" ] && [ "$w" -gt 0 ] && [ "$h" -gt 0 ] || return 1
  printf '%s %s' "$w" "$h"
}

read_user_file() {
  run_watchdog 1 "$@"
}

hex_head() {
  read_user_file od -An -tx1 -N 256 "$1" 2>/dev/null | tr -s ' ' | sed 's/^ //'
}

html_escape_file() {
  read_user_file head -c 204800 "$1" 2>/dev/null | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
}

csv_preview_json() {
  path="$1"
  read_user_file head -n 501 "$path" 2>/dev/null | awk '
    function esc(s) {
      gsub(/\\/, "\\\\", s)
      gsub(/"/, "\\\"", s)
      return s
    }
    function arr(line,    n, i, out, a) {
      n = split(line, a, FS)
      out = "["
      for (i = 1; i <= n; i++) {
        if (i > 1) out = out ","
        out = out "\"" esc(a[i]) "\""
      }
      return out "]"
    }
    BEGIN { headers = "[]"; rows = ""; nbody = 0 }
    NR == 1 {
      line = $0
      c = gsub(/,/, ",", line)
      line = $0
      t = gsub(/\t/, "\t", line)
      line = $0
      s = gsub(/;/, ";", line)
      line = $0
      p = gsub(/\|/, "|", line)
      FS = ","
      if (t > c && t >= s && t >= p) FS = "\t"
      else if (s > c && s >= t && s >= p) FS = ";"
      else if (p > c && p >= t && p >= s) FS = "|"
      $0 = $0
      headers = arr($0)
      next
    }
    {
      if (nbody) rows = rows ","
      rows = rows arr($0)
      nbody++
    }
    END {
      trunc = (NR > 501) ? "true" : "false"
      printf "{\"kind\":\"csv\",\"headers\":%s,\"rows\":[%s],\"truncated\":%s}", headers, rows, trunc
    }
  '
}

dir_preview_json() {
  path="$1"
  tmp=$(mktemp)
  read_user_file ls -1 "$path" 2>/dev/null | head -n 200 > "$tmp"
  entries=""
  while IFS= read -r name || [ -n "$name" ]; do
    [ -n "$name" ] || continue
    full="$path/$name"
    k=$(kind_of "$full")
    sz=0
    if [ -f "$full" ] && watchdog_ok; then
      sz=$(run_watchdog 1 stat -c %s "$full" 2>/dev/null) || \
        sz=$(run_watchdog 1 stat -f %z "$full" 2>/dev/null) || sz=0
      [ -n "$sz" ] || sz=0
    fi
    ent="{\"name\":\"$(json_escape "$name")\",\"kind\":\"$k\",\"size\":$sz}"
    if [ -z "$entries" ]; then
      entries="$ent"
    else
      entries="$entries,$ent"
    fi
  done < "$tmp"
  rm -f "$tmp"
  printf '{"kind":"dir","entries":[%s],"path":"%s"}' "$entries" "$(json_escape "$path")"
}

isolation_ok() {
  watchdog_ok
}

run_isolated() {
  watchdog_ok || return 1
  (
    ulimit -t 8 2>/dev/null || true
    ulimit -v 524288 2>/dev/null || true
    ulimit -f 65536 2>/dev/null || true
    ulimit -u 32 2>/dev/null || true
    run_watchdog 8 "$@"
  ) >/dev/null 2>&1 || true
}

run_pdftoppm() {
  path="$1"
  page="$2"
  dest="$3"
  prefix="${dest%.png}"
  if ! isolation_ok; then
    return 1
  fi
  run_isolated pdftoppm -f "$page" -l "$page" -png -r 140 -singlefile "$path" "$prefix"
}

downsample_image() {
  src="$1"
  dest="$2"
  nw="$3"
  nh="$4"
  if ! isolation_ok; then
    return 1
  fi
  if command -v ffmpeg >/dev/null 2>&1; then
    run_isolated ffmpeg -nostdin -hide_banner -loglevel error -i "$src" -vf "scale=${nw}:${nh}" -frames:v 1 -y "$dest"
    [ -s "$dest" ] && return 0
  fi
  if command -v magick >/dev/null 2>&1; then
    run_isolated magick "$src" -resize "${nw}x${nh}" "$dest"
    [ -s "$dest" ] && return 0
  fi
  if command -v convert >/dev/null 2>&1; then
    run_isolated convert "$src" -resize "${nw}x${nh}" "$dest"
    [ -s "$dest" ] && return 0
  fi
  return 1
}

reply_preview() {
  id="$1"
  path="$2"
  page="${3:-1}"
  [ -n "$page" ] || page=1
  kind=$(kind_of "$path")
  case "$kind" in
    image)
      ext=$(printf '%s' "$path" | awk -F. '{print tolower($NF)}')
      wh=""
      case "$ext" in
        png) wh=$(png_wh "$path") || wh="" ;;
        gif) wh=$(gif_wh "$path") || wh="" ;;
        svg) wh=$(svg_wh "$path") || wh="" ;;
        *) wh="" ;;
      esac
      if [ -n "$wh" ]; then
        set -- $wh
        w=$1
        h=$2
        pix=$((w * h))
        if [ "$pix" -le 20000000 ] && [ "$w" -gt 0 ] && [ "$h" -gt 0 ]; then
          anim=false
          [ "$ext" = gif ] && anim=true
          printf '{"id":%s,"kind":"preview","preview":{"kind":"image","path":"%s","animated":%s,"width":%s,"height":%s}}\n' \
            "$id" "$(json_escape "$path")" "$anim" "$w" "$h"
        elif [ "$w" -gt 0 ] && [ "$h" -gt 0 ]; then
          nw=$w
          nh=$h
          # integer sqrt-ish shrink so nw*nh <= 20e6
          while [ $((nw * nh)) -gt 20000000 ]; do
            nw=$((nw / 2))
            nh=$((nh / 2))
            [ "$nw" -gt 0 ] && [ "$nh" -gt 0 ] || break
          done
          [ "$nw" -gt 0 ] || nw=1
          [ "$nh" -gt 0 ] || nh=1
          cache_dir="${XDG_CACHE_HOME:-$HOME_DIR/.cache}/quicklook/previews"
          mkdir -p "$cache_dir" 2>/dev/null || cache_dir="/tmp/quicklook-previews"
          mkdir -p "$cache_dir"
          dest="$cache_dir/ds-$$.png"
          if downsample_image "$path" "$dest" "$nw" "$nh" && [ -s "$dest" ]; then
            printf '{"id":%s,"kind":"preview","preview":{"kind":"image","path":"%s","animated":false,"width":%s,"height":%s,"label":"downsampled"}}\n' \
              "$id" "$(json_escape "$dest")" "$nw" "$nh"
          else
            printf '{"id":%s,"kind":"preview","preview":{"kind":"hex","hex":"%s","magic":"image %sx%s","label":"image exceeds 20 MP — hex view","width":%s,"height":%s,"path":"%s"}}\n' \
              "$id" "$(json_escape "$(hex_head "$path")")" "$w" "$h" "$w" "$h" "$(json_escape "$path")"
          fi
        fi
      else
        printf '{"id":%s,"kind":"preview","preview":{"kind":"hex","hex":"%s","magic":"unverifiable image","label":"can'\''t render this — hex view","path":"%s"}}\n' \
          "$id" "$(json_escape "$(hex_head "$path")")" "$(json_escape "$path")"
      fi
      ;;
    pdf)
      if command -v pdftoppm >/dev/null 2>&1 && isolation_ok; then
        cache_dir="${XDG_CACHE_HOME:-$HOME_DIR/.cache}/quicklook/pdf"
        mkdir -p "$cache_dir" 2>/dev/null || cache_dir="/tmp/quicklook-pdf"
        mkdir -p "$cache_dir"
        dest="$cache_dir/p${page}-$$.png"
        run_pdftoppm "$path" "$page" "$dest"
        if [ ! -s "$dest" ] && [ -s "${dest%.png}-1.png" ]; then
          dest="${dest%.png}-1.png"
        fi
        if [ -s "$dest" ]; then
          printf '{"id":%s,"kind":"preview","preview":{"kind":"pdf","path":"%s","page":%s,"page_count":1,"need_poppler":false}}\n' \
            "$id" "$(json_escape "$dest")" "$page"
        else
          printf '{"id":%s,"kind":"preview","preview":{"kind":"pdf","need_poppler":false,"render_error":true,"page":%s,"page_count":1,"label":"couldn'\''t render this page","magic":"PDF document","hex":"%s"}}\n' \
            "$id" "$page" "$(json_escape "$(hex_head "$path")")"
        fi
      elif command -v pdftoppm >/dev/null 2>&1; then
        printf '{"id":%s,"kind":"preview","preview":{"kind":"pdf","need_poppler":false,"page":%s,"page_count":1,"label":"PDF metadata only — no isolated renderer","magic":"PDF document"}}\n' \
          "$id" "$page"
      else
        printf '{"id":%s,"kind":"preview","preview":{"kind":"pdf","need_poppler":true,"page":%s,"page_count":1,"label":"install poppler for PDF previews","magic":"PDF document","path":"%s"}}\n' \
          "$id" "$page" "$(json_escape "$path")"
      fi
      ;;
    code)
      printf '{"id":%s,"kind":"preview","preview":{"kind":"code","html":"<pre>%s</pre>","lang":"text","path":"%s"}}\n' \
        "$id" "$(json_escape "$(html_escape_file "$path")")" "$(json_escape "$path")"
      ;;
    csv)
      printf '{"id":%s,"kind":"preview","preview":%s}\n' "$id" "$(csv_preview_json "$path")"
      ;;
    dir)
      printf '{"id":%s,"kind":"preview","preview":%s}\n' "$id" "$(dir_preview_json "$path")"
      ;;
    *)
      printf '{"id":%s,"kind":"preview","preview":{"kind":"hex","hex":"%s","magic":"data","label":"can'\''t render this — hex view","path":"%s"}}\n' \
        "$id" "$(json_escape "$(hex_head "$path")")" "$(json_escape "$path")"
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
  watchdog_ok || return 2
  if command -v gio >/dev/null 2>&1; then
    run_watchdog 8 gio open "$target" >/dev/null 2>&1 || true
    return 0
  fi
  if command -v xdg-open >/dev/null 2>&1; then
    run_watchdog 8 xdg-open "$target" >/dev/null 2>&1 || true
    return 0
  fi
  if command -v open >/dev/null 2>&1; then
    run_watchdog 8 open "$target" >/dev/null 2>&1 || true
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
      reply_preview "$id" "$(extract_string "$line" "path")" "$(extract_number "$line" "page")"
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
      reply_preview "$id" "$(extract_string "$line" "path")" "$(extract_number "$line" "page")"
      ;;
  esac
}

oneshot=0
payload=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --plugin-dir)
      shift
      if [ -n "${1:-}" ]; then
        export QUICKLOOK_PLUGIN_DIR="$1"
        SAMP="$1/samples"
      fi
      ;;
    --oneshot)
      oneshot=1
      shift
      payload="${1:-}"
      ;;
    --watchdog-selftest)
      shift
      secs=${1:-2}
      [ "$#" -gt 0 ] && shift
      run_watchdog "$secs" "$@"
      exit $?
      ;;
    *)
      break
      ;;
  esac
  [ "$#" -gt 0 ] && shift
done

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
