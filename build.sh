#!/bin/sh
# Build quicklookd. QML degrades to compat/quicklookd.sh when the binary is
# missing, so a failed build is not fatal at runtime.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
SRC="$ROOT/src/quicklookd"
OUT="$ROOT/bin"

mkdir -p "$OUT"
chmod +x "$ROOT/compat/quicklookd.sh" "$ROOT/compat/quicklookd.py" 2>/dev/null || true

write_checksums() {
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$OUT" && sha256sum quicklookd > "$ROOT/CHECKSUMS.txt") || true
  elif command -v shasum >/dev/null 2>&1; then
    (cd "$OUT" && shasum -a 256 quicklookd > "$ROOT/CHECKSUMS.txt") || true
  fi
}

if ! command -v cargo >/dev/null 2>&1; then
  echo "build.sh: cargo not found; not installing a fake bin/quicklookd." >&2
  echo "build.sh: Service will use compat/quicklookd.sh (degraded fallback)." >&2
  exit 1
fi

if ! cargo build --release --manifest-path "$SRC/Cargo.toml"; then
  echo "build.sh: cargo build FAILED; not installing the POSIX fallback as bin/quicklookd." >&2
  echo "build.sh: the authentic helper did not compile. Service will use compat/quicklookd.sh." >&2
  exit 1
fi

BIN="$SRC/target/release/quicklookd"
if [ ! -x "$BIN" ]; then
  echo "build.sh: release binary missing after cargo build" >&2
  exit 1
fi
cp "$BIN" "$OUT/quicklookd"
chmod +x "$OUT/quicklookd"
write_checksums
echo "build.sh: wrote $OUT/quicklookd"
if [ -f "$ROOT/CHECKSUMS.txt" ]; then
  echo "build.sh: checksums -> $ROOT/CHECKSUMS.txt"
fi
