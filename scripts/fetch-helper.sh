#!/bin/sh
# Optional: download a musl quicklookd from the latest GitHub release.
# Verifies the published CHECKSUMS.txt before installing.
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
base="https://github.com/$REPO/releases/latest/download"
mkdir -p "$OUT"
tmp=$(mktemp)
sumfile=$(mktemp)
cleanup() { rm -f "$tmp" "$sumfile"; }
trap cleanup EXIT

if ! command -v curl >/dev/null 2>&1; then
  echo "fetch-helper: curl required" >&2
  exit 1
fi
if ! curl -fsSL "$base/CHECKSUMS.txt" -o "$sumfile"; then
  echo "fetch-helper: could not download CHECKSUMS.txt from $base" >&2
  exit 1
fi
if ! curl -fsSL "$base/$asset" -o "$tmp"; then
  echo "fetch-helper: download failed ($base/$asset)" >&2
  exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  got=$(sha256sum "$tmp" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  got=$(shasum -a 256 "$tmp" | awk '{print $1}')
else
  echo "fetch-helper: need sha256sum or shasum to verify the download" >&2
  exit 1
fi

expected=$(awk -v a="$asset" '$2 == a { print $1; exit }' "$sumfile")
if [ -z "$expected" ]; then
  echo "fetch-helper: $asset not listed in CHECKSUMS.txt" >&2
  cat "$sumfile" >&2
  exit 1
fi
if [ "$expected" != "$got" ]; then
  echo "fetch-helper: checksum mismatch for $asset" >&2
  echo "  expected $expected" >&2
  echo "  got      $got" >&2
  exit 1
fi

chmod +x "$tmp"
mv "$tmp" "$OUT/quicklookd"
trap - EXIT
echo "fetch-helper: wrote $OUT/quicklookd (sha256 $got)"
