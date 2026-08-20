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

# Privacy: match exclude.rs — no .env, SSH keys, or hidden secret dirs.
mkdir -p "$HOME/vault/.ssh" "$HOME/vault/.hidden"
printf 'x\n' > "$HOME/vault/.env"
printf 'x\n' > "$HOME/vault/.env.local"
printf 'x\n' > "$HOME/vault/id_rsa"
printf 'x\n' > "$HOME/vault/id_ed25519"
printf 'x\n' > "$HOME/vault/.ssh/invoice-key"
printf 'x\n' > "$HOME/vault/.hidden/invoice-hid.txt"
printf 'ok\n' > "$HOME/vault/ok-invoice.txt"
unset QUICKLOOK_FORCE_SH
python3 "$ROOT/compat/quicklookd.py" --oneshot '{"id":8,"cmd":"config","roots":["'"$HOME/vault"'"]}' >/dev/null
pout=$(python3 "$ROOT/compat/quicklookd.py" --oneshot '{"id":9,"cmd":"query","q":"invoice"}')
echo "$pout" | grep -q ok-invoice || { echo "FAIL privacy kept public invoice"; echo "$pout"; exit 1; }
echo "$pout" | grep -q invoice-key && { echo "FAIL leaked .ssh key name"; echo "$pout"; exit 1; }
echo "$pout" | grep -q invoice-hid && { echo "FAIL leaked hidden dir"; echo "$pout"; exit 1; }
echo "$pout" | grep -q id_rsa && { echo "FAIL leaked id_rsa"; echo "$pout"; exit 1; }
echo "$pout" | grep -q '.env' && { echo "FAIL leaked .env"; echo "$pout"; exit 1; }
export QUICKLOOK_FORCE_SH=1
sh "$ROOT/compat/quicklookd.sh" --oneshot '{"id":10,"cmd":"config","roots":["'"$HOME/vault"'"]}' >/dev/null
spout=$(sh "$ROOT/compat/quicklookd.sh" --oneshot '{"id":11,"cmd":"query","q":"invoice"}')
echo "$spout" | grep -q ok-invoice || { echo "FAIL sh privacy kept public invoice"; echo "$spout"; exit 1; }
echo "$spout" | grep -q invoice-key && { echo "FAIL sh leaked .ssh"; echo "$spout"; exit 1; }
echo "$spout" | grep -q invoice-hid && { echo "FAIL sh leaked hidden"; echo "$spout"; exit 1; }
echo "$spout" | grep -q id_rsa && { echo "FAIL sh leaked id_rsa"; echo "$spout"; exit 1; }
echo "ok  privacy exclusions python + posix"

# Oversized / unverifiable images become hex, not raw Image paths.
python3 - << 'PY'
import json, os, struct, subprocess, sys
from pathlib import Path
root = os.environ["QUICKLOOK_PLUGIN_DIR"]
home = Path(os.environ["HOME"])
png = home / "vault" / "huge.png"
# Valid PNG signature + IHDR claiming 8000x8000 (64 MP)
ihdr = struct.pack(">IIBBBBB", 8000, 8000, 8, 2, 0, 0, 0)
raw = b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR" + ihdr + b"\x00\x00\x00\x00" + b"IEND"
png.write_bytes(raw)
out = subprocess.check_output(
    [sys.executable, f"{root}/compat/quicklookd.py", "--oneshot",
     json.dumps({"id": 12, "cmd": "preview", "path": str(png)})],
    text=True,
)
msg = json.loads(out)
kind = msg.get("preview", {}).get("kind")
if kind == "image":
    sys.stderr.write("FAIL huge png still image: %s\n" % out)
    sys.exit(1)
print("ok  python oversized image rejected")
junk = home / "vault" / "junk.png"
junk.write_bytes(b"\x00\x01 not a png")
out = subprocess.check_output(
    [sys.executable, f"{root}/compat/quicklookd.py", "--oneshot",
     json.dumps({"id": 13, "cmd": "preview", "path": str(junk)})],
    text=True,
)
kind = json.loads(out).get("preview", {}).get("kind")
if kind == "image":
    sys.stderr.write("FAIL junk png still image\n")
    sys.exit(1)
print("ok  python unverifiable image rejected")
# GIF/SVG without established dims must not pass through as Image.
svg = home / "vault" / "bomb.svg"
svg.write_text("<svg xmlns='http://www.w3.org/2000/svg'><rect width='100%' height='100%'/></svg>")
out = subprocess.check_output(
    [sys.executable, f"{root}/compat/quicklookd.py", "--oneshot",
     json.dumps({"id": 14, "cmd": "preview", "path": str(svg)})],
    text=True,
)
kind = json.loads(out).get("preview", {}).get("kind")
if kind == "image":
    sys.stderr.write("FAIL percent svg still image\n")
    sys.exit(1)
print("ok  python unverifiable svg rejected")
ok_svg = home / "vault" / "ok.svg"
ok_svg.write_text("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'><rect width='16' height='16'/></svg>")
out = subprocess.check_output(
    [sys.executable, f"{root}/compat/quicklookd.py", "--oneshot",
     json.dumps({"id": 15, "cmd": "preview", "path": str(ok_svg)})],
    text=True,
)
prev = json.loads(out).get("preview", {})
if prev.get("kind") != "image" or prev.get("width") != 16:
    sys.stderr.write("FAIL viewBox svg: %s\n" % out)
    sys.exit(1)
print("ok  python viewBox svg accepted")
PY

# Structured CSV / directory descriptors (not generic code text).
csvp="$HOME/vault/sales.csv"
printf 'date,sku,qty\n2024-01-01,W,1\n' > "$csvp"
unset QUICKLOOK_FORCE_SH
csvout=$(python3 "$ROOT/compat/quicklookd.py" --oneshot "{\"id\":16,\"cmd\":\"preview\",\"path\":\"$csvp\"}")
echo "$csvout" | grep -q '"kind": "csv"' || echo "$csvout" | grep -q '"kind":"csv"' || { echo "FAIL python csv kind"; echo "$csvout"; exit 1; }
echo "$csvout" | grep -q '"headers"' || { echo "FAIL python csv headers"; echo "$csvout"; exit 1; }
dirp="$HOME/vault"
dirout=$(python3 "$ROOT/compat/quicklookd.py" --oneshot "{\"id\":17,\"cmd\":\"preview\",\"path\":\"$dirp\"}")
echo "$dirout" | grep -q '"kind": "dir"' || echo "$dirout" | grep -q '"kind":"dir"' || { echo "FAIL python dir kind"; echo "$dirout"; exit 1; }
echo "$dirout" | grep -q '"entries"' || { echo "FAIL python dir entries"; echo "$dirout"; exit 1; }
export QUICKLOOK_FORCE_SH=1
shcsv=$(sh "$ROOT/compat/quicklookd.sh" --oneshot "{\"id\":18,\"cmd\":\"preview\",\"path\":\"$csvp\"}")
echo "$shcsv" | grep -q '"kind":"csv"' || { echo "FAIL sh csv kind"; echo "$shcsv"; exit 1; }
echo "$shcsv" | grep -q '"headers"' || { echo "FAIL sh csv headers"; echo "$shcsv"; exit 1; }
shdir=$(sh "$ROOT/compat/quicklookd.sh" --oneshot "{\"id\":19,\"cmd\":\"preview\",\"path\":\"$dirp\"}")
echo "$shdir" | grep -q '"kind":"dir"' || { echo "FAIL sh dir kind"; echo "$shdir"; exit 1; }
echo "$shdir" | grep -q '"entries"' || { echo "FAIL sh dir entries"; echo "$shdir"; exit 1; }
echo "ok  csv/dir structured descriptors python + posix"

# Invoice PDF: rasterize when pdftoppm exists; never hand a .pdf to Image.
pdf="$ROOT/samples/invoice.pdf"
if [ -f "$pdf" ]; then
  unset QUICKLOOK_FORCE_SH
  pdfout=$(python3 "$ROOT/compat/quicklookd.py" --oneshot "{\"id\":20,\"cmd\":\"preview\",\"path\":\"$pdf\"}")
  echo "$pdfout" | grep -q '"kind": "pdf"' || echo "$pdfout" | grep -q '"kind":"pdf"' || { echo "FAIL python pdf kind"; echo "$pdfout"; exit 1; }
  echo "$pdfout" | grep -q '\.pdf"' && { echo "FAIL python pdf path is raw pdf"; echo "$pdfout"; exit 1; }
  if command -v pdftoppm >/dev/null 2>&1; then
    echo "$pdfout" | grep -q '"need_poppler": true' && { echo "FAIL python should rasterize"; echo "$pdfout"; exit 1; }
    echo "$pdfout" | grep -q '\.png' || echo "$pdfout" | grep -q 'render_error' || {
      echo "FAIL python pdf neither raster nor render_error"; echo "$pdfout"; exit 1
    }
  fi
  export QUICKLOOK_FORCE_SH=1
  shpdf=$(sh "$ROOT/compat/quicklookd.sh" --oneshot "{\"id\":21,\"cmd\":\"preview\",\"path\":\"$pdf\"}")
  echo "$shpdf" | grep -q '"kind":"pdf"' || { echo "FAIL sh pdf kind"; echo "$shpdf"; exit 1; }
  echo "ok  pdf preview python + posix"
fi
