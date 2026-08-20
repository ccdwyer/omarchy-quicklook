#!/bin/sh
# Optional: download a musl quicklookd from the latest GitHub release.
# Not required — the plugin runs without it via compat/.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
OUT="$ROOT/bin"
REPO="${QUICKLOOK_RELEASE_REPO:-}"

if [ -z "$REPO" ]; then
  echo "fetch-helper: set QUICKLOOK_RELEASE_REPO=owner/repo to download a musl build" >&2
  echo "fetch-helper: or run $ROOT/build.sh to compile locally" >&2
  exit 1
fi

arch=$(uname -m)
case "$arch" in
  x86_64|amd64) target=x86_64-unknown-linux-musl ;;
  aarch64|arm64) target=aarch64-unknown-linux-musl ;;
  *) echo "fetch-helper: unsupported arch $arch" >&2; exit 1 ;;
esac

asset="quicklookd-$target"
url="https://github.com/$REPO/releases/latest/download/$asset"
mkdir -p "$OUT"
tmp=$(mktemp)
if ! command -v curl >/dev/null 2>&1; then
  echo "fetch-helper: curl required" >&2
  exit 1
fi
if ! curl -fsSL "$url" -o "$tmp"; then
  echo "fetch-helper: download failed ($url)" >&2
  rm -f "$tmp"
  exit 1
fi
chmod +x "$tmp"
mv "$tmp" "$OUT/quicklookd"
echo "fetch-helper: wrote $OUT/quicklookd"
