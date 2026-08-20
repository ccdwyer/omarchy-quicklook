#!/usr/bin/env python3
"""POSIX/Python fallback for quicklookd when the Rust binary is missing.

Speaks the same newline-delimited JSON protocol. No nucleo, no sqlite, no
watches — demo corpus + a bounded find walk + basic previews.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

PLUGIN_DIR = Path(os.environ.get("QUICKLOOK_PLUGIN_DIR", Path(__file__).resolve().parent.parent))
SAMPLES = PLUGIN_DIR / "samples"
HOME = Path(os.environ.get("HOME", "/tmp"))
STATE = Path(os.environ.get("XDG_STATE_HOME", HOME / ".local/state")) / "quicklook"
CACHE = Path(os.environ.get("XDG_CACHE_HOME", HOME / ".cache")) / "quicklook"
SETTINGS_PATH = STATE / "compat-config.json"

DEFAULT_SKIP = (
    ".ssh",
    ".gnupg",
    ".password-store",
    "node_modules",
    "target",
    ".git",
    ".hg",
    ".svn",
    ".bzr",
    "__pycache__",
    ".venv",
    "venv",
    ".tox",
    ".mypy_cache",
    ".pytest_cache",
    ".cargo",
    ".rustup",
    ".npm",
    ".cache",
    ".Trash",
    ".local",
    "keyrings",
    "kwalletd",
    "Keychains",
)
SKIP_PATH_PARTS = (
    "/.ssh/",
    "/.gnupg/",
    "/.password-store/",
    "/.local/share/keyrings/",
    "/.local/share/kwalletd/",
    "/Library/Keychains/",
)
MEGAPIXELS = 20_000_000

SETTINGS = {
    "roots": [str(HOME)],
    "extraExclude": [],
    "watchCap": 2000,
    "cacheMb": 500,
    "maxFiles": 500000,
}


def _expand(p: str) -> str:
    if p == "~":
        return str(HOME)
    if p.startswith("~/"):
        return str(HOME / p[2:])
    return p


def load_settings() -> None:
    if not SETTINGS_PATH.is_file():
        return
    try:
        data = json.loads(SETTINGS_PATH.read_text())
    except (OSError, json.JSONDecodeError):
        return
    apply_settings(data, persist=False)


def apply_settings(data: dict, persist: bool = True) -> None:
    if not isinstance(data, dict):
        return
    if data.get("roots") is not None:
        roots = data["roots"]
        if isinstance(roots, str):
            roots = [r.strip() for r in roots.split(",") if r.strip()]
        SETTINGS["roots"] = [_expand(str(r)) for r in roots] or [str(HOME)]
    if data.get("extraExclude") is not None:
        extra = data["extraExclude"]
        if isinstance(extra, str):
            extra = [x.strip() for x in extra.split(",") if x.strip()]
        SETTINGS["extraExclude"] = [str(x) for x in extra]
    if data.get("watchCap") is not None:
        SETTINGS["watchCap"] = max(16, int(data["watchCap"] or 2000))
    if data.get("cacheMb") is not None:
        SETTINGS["cacheMb"] = max(16, int(data["cacheMb"] or 500))
    if data.get("maxFiles") is not None:
        SETTINGS["maxFiles"] = max(1000, int(data["maxFiles"] or 500000))
    if persist:
        try:
            STATE.mkdir(parents=True, exist_ok=True)
            SETTINGS_PATH.write_text(json.dumps(SETTINGS))
        except OSError:
            pass


def skip_parts() -> tuple[str, ...]:
    return DEFAULT_SKIP + tuple(SETTINGS["extraExclude"])


def is_secret_filename(name: str) -> bool:
    if name == ".env" or name.startswith(".env.") or name.endswith(".env"):
        return True
    if name in ("id_rsa", "id_ed25519") or name.startswith("id_rsa."):
        return True
    return False


def path_is_secret(path: Path) -> bool:
    s = str(path)
    if any(part in s for part in SKIP_PATH_PARTS):
        return True
    return is_secret_filename(path.name)


def hidden_or_heavy_dir(name: str, extra: list[str]) -> bool:
    if name in DEFAULT_SKIP or name in extra:
        return True
    return name.startswith(".") and name not in (".", "..")


def should_skip_result(path: Path, extra: list[str] | None = None) -> bool:
    extra = extra if extra is not None else list(SETTINGS["extraExclude"])
    roots = [Path(r) for r in SETTINGS["roots"] if r]
    if path_is_secret(path):
        return True
    for parent in [path] + list(path.parents):
        if any(parent == r or parent == Path(str(r)) for r in roots):
            break
        if hidden_or_heavy_dir(parent.name, extra):
            return True
    return False


load_settings()


def kind_of(path: Path, is_dir: bool = False) -> str:
    if is_dir or path.is_dir():
        return "dir"
    ext = path.suffix.lower().lstrip(".")
    name = path.name.lower()
    if name in ("makefile", "dockerfile"):
        return "code"
    if ext in ("png", "jpg", "jpeg", "webp", "svg", "gif", "bmp", "ico"):
        return "image"
    if ext == "pdf":
        return "pdf"
    if ext in ("csv", "tsv"):
        return "csv"
    if ext in ("mp4", "webm", "mkv", "mov", "avi"):
        return "video"
    if ext in (
        "rs", "js", "ts", "py", "go", "c", "h", "cpp", "java", "kt", "rb", "php",
        "sh", "lua", "qml", "json", "yaml", "yml", "toml", "md", "html", "css",
        "xml", "sql", "swift", "txt", "conf", "ini",
    ):
        return "code"
    return "hex"


def demo() -> list[dict]:
    names = ["invoice.pdf", "photo.png", "sales.csv", "themed.rs", "README.md"]
    out = []
    for i, name in enumerate(names):
        p = SAMPLES / name
        out.append(
            {
                "path": str(p),
                "name": name,
                "kind": kind_of(p),
                "score": 900 - i * 10,
                "mtime": int(p.stat().st_mtime * 1000) if p.exists() else 0,
                "size": p.stat().st_size if p.exists() else 0,
            }
        )
    return out


def fuzzy(hay: str, needle: str) -> int:
    h = hay.lower()
    n = needle.lower()
    if not n:
        return 1
    if n in h:
        return 800 - h.find(n)
    hi = 0
    score = 0
    for ch in n:
        pos = h.find(ch, hi)
        if pos < 0:
            return 0
        score += 8
        hi = pos + 1
    return score


def search(q: str) -> tuple[list[dict], str]:
    if not q.strip():
        return demo(), "demo"
    hits = []
    for item in demo():
        s = max(fuzzy(item["name"], q), fuzzy(item["path"], q))
        if s > 0:
            item = dict(item)
            item["score"] = s + 200
            hits.append(item)
    backend = "compat"
    found = find_names(q, 40)
    for item in found:
        if any(h["path"] == item["path"] for h in hits):
            continue
        hits.append(item)
    hits.sort(key=lambda x: (-x["score"], x["name"]))
    return hits[:40], backend


def _hits_from_paths(paths: list[str], q: str, cap: int) -> list[dict]:
    extra = list(SETTINGS["extraExclude"])
    out: list[dict] = []
    for line in paths:
        p = Path(line)
        if should_skip_result(p, extra):
            continue
        try:
            st = p.stat()
        except OSError:
            continue
        out.append(
            {
                "path": str(p),
                "name": p.name,
                "kind": kind_of(p, p.is_dir()),
                "score": fuzzy(p.name, q),
                "mtime": int(st.st_mtime * 1000),
                "size": st.st_size,
            }
        )
        if len(out) >= cap:
            break
    return out


def plocate_names(q: str, limit: int) -> list[dict] | None:
    binary = shutil.which("plocate") or shutil.which("locate")
    if not binary:
        return None
    try:
        proc = subprocess.run(
            [binary, "-il", str(limit), "--", q],
            capture_output=True,
            text=True,
            timeout=2,
        )
    except (subprocess.TimeoutExpired, OSError):
        return None
    if not proc.stdout.strip():
        return None
    hits = _hits_from_paths(proc.stdout.splitlines(), q, limit)
    roots = [Path(r) for r in SETTINGS["roots"] if r]
    if roots:
        hits = [
            h
            for h in hits
            if any(Path(h["path"]) == r or str(h["path"]).startswith(str(r) + "/") for r in roots)
        ]
    return hits or None


def find_names(q: str, limit: int) -> list[dict]:
    roots = [r for r in SETTINGS["roots"] if r]
    if not roots:
        roots = [str(HOME)]
    cap = min(int(limit), 40)
    q = "".join(ch for ch in q if ch.isalnum() or ch in "._-")
    if not q:
        return []
    located = plocate_names(q, cap)
    if located:
        return located
    if shutil.which("find") is None:
        return []
    skip = skip_parts()
    prune: list[str] = []
    for name in skip:
        if prune:
            prune.append("-o")
        prune.extend(["-name", name])
    if prune:
        prune.extend(["-o", "-name", ".*"])
    else:
        prune.extend(["-name", ".*"])
    cmd = ["find", *roots, "-mindepth", "1"]
    cmd.extend(["(", *prune, ")", "-prune", "-o", "-iname", f"*{q}*", "-print"])
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=2)
    except (subprocess.TimeoutExpired, OSError):
        return []
    return _hits_from_paths(proc.stdout.splitlines(), q, cap)


def _be_u32(data: bytes) -> int:
    return int.from_bytes(data, "big")


def image_dims(path: Path) -> tuple[int, int] | None:
    try:
        head = path.read_bytes()[: 96 * 1024]
    except OSError:
        return None
    if len(head) >= 24 and head[:8] == b"\x89PNG\r\n\x1a\n":
        return _be_u32(head[16:20]), _be_u32(head[20:24])
    if len(head) >= 10 and head[:6] in (b"GIF87a", b"GIF89a"):
        return int.from_bytes(head[6:8], "little"), int.from_bytes(head[8:10], "little")
    if head[:2] == b"\xff\xd8":
        i = 2
        while i + 9 < len(head):
            if head[i] != 0xFF:
                i += 1
                continue
            marker = head[i + 1]
            if marker in (0xC0, 0xC1, 0xC2, 0xC3):
                return int.from_bytes(head[i + 5 : i + 7], "big"), int.from_bytes(
                    head[i + 7 : i + 9], "big"
                )
            if marker in (0xD8, 0xD9):
                i += 2
                continue
            seglen = int.from_bytes(head[i + 2 : i + 4], "big")
            i += 2 + seglen
        return None
    if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        kind = head[12:16]
        if kind == b"VP8X" and len(head) >= 30:
            w = 1 + int.from_bytes(head[24:27], "little")
            h = 1 + int.from_bytes(head[27:30], "little")
            return w, h
        if kind == b"VP8 " and len(head) >= 26:
            return int.from_bytes(head[26:28], "little") & 0x3FFF, int.from_bytes(
                head[28:30], "little"
            ) & 0x3FFF
    return None


def preview_image(path: Path) -> dict:
    ext = path.suffix.lower().lstrip(".")
    if ext in ("svg", "gif"):
        return {"kind": "image", "path": str(path), "animated": ext == "gif"}
    dims = image_dims(path)
    if not dims or dims[0] <= 0 or dims[1] <= 0:
        return {
            "kind": "hex",
            "hex": "",
            "magic": "unverifiable image",
            "label": "can't render this — hex view",
            "path": str(path),
        }
    w, h = dims
    if w * h > MEGAPIXELS:
        return {
            "kind": "hex",
            "hex": "",
            "magic": f"image {w}x{h}",
            "label": "image exceeds 20 MP — hex view",
            "width": w,
            "height": h,
            "path": str(path),
        }
    return {"kind": "image", "path": str(path), "animated": False, "width": w, "height": h}


def preview(path_s: str, page: int = 1) -> dict:
    path = Path(path_s)
    if not path.exists():
        return {"kind": "hex", "magic": "missing", "label": "can't render this — hex view"}
    if path.is_dir():
        entries = []
        total = 0
        try:
            kids = sorted(path.iterdir(), key=lambda p: p.name)[:200]
        except OSError:
            kids = []
        for kid in kids:
            try:
                st = kid.stat()
                total += st.st_size if kid.is_file() else 0
                entries.append({"name": kid.name, "kind": kind_of(kid, kid.is_dir()), "size": st.st_size})
            except OSError:
                continue
        return {"kind": "dir", "entries": entries, "total_size": total, "path": str(path)}
    k = kind_of(path)
    if k == "image":
        return preview_image(path)
    if k == "code":
        data = path.read_bytes()[: 200 * 1024]
        large = path.stat().st_size > 200 * 1024
        text = data.decode("utf-8", errors="replace")
        html = "<pre>" + (
            text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
        ) + "</pre>"
        return {"kind": "code", "html": html, "lang": path.suffix.lstrip("."), "large": large,
                "capped": large, "label": "large file" if large else "", "path": str(path)}
    if k == "csv":
        text = path.read_text(errors="replace")
        first = text.split("\n", 1)[0]
        delim = ","
        if first.count("\t") > first.count(","):
            delim = "\t"
        rows = [ln.split(delim) for ln in text.splitlines()[:501]]
        headers = rows[0] if rows else []
        body = rows[1:501] if rows else []
        return {"kind": "csv", "headers": headers, "rows": body, "truncated": len(text.splitlines()) > 501}
    if k == "pdf":
        # Compat never runs pdftoppm: no rlimits here, and a shared raster
        # would stale across files. Isolated PDF children stay in quicklookd.
        has_poppler = shutil.which("pdftoppm") is not None
        return {
            "kind": "pdf",
            "need_poppler": not has_poppler,
            "render_error": has_poppler,
            "page": page,
            "page_count": 1,
            "label": (
                "install poppler for PDF previews"
                if not has_poppler
                else "compat mode does not rasterize PDFs — Enter opens the file"
            ),
            "magic": "PDF document",
        }
    head = path.read_bytes()[:256]
    hex_lines = []
    for i in range(0, len(head), 16):
        chunk = head[i:i + 16]
        hx = " ".join(f"{b:02x}" for b in chunk)
        asc = "".join(chr(b) if 32 <= b < 127 else "." for b in chunk)
        hex_lines.append(f"{i:08x}  {hx:<48} {asc}")
    return {"kind": "hex", "hex": "\n".join(hex_lines) or "(empty)", "magic": "data",
            "label": "can't render this — hex view", "path": str(path)}


def open_path(path_s: str, reveal: bool = False) -> dict:
    path = Path(path_s)
    if not path.exists():
        return {"ok": False, "error": "missing"}
    target = path if not reveal else (path if path.is_dir() else path.parent)
    opener = shutil.which("gio")
    args = ["open", str(target)] if opener else None
    if opener is None:
        opener = shutil.which("xdg-open") or shutil.which("open")
        args = [str(target)]
    if opener is None:
        return {"ok": False, "error": "no opener"}
    subprocess.Popen([opener, *args], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return {"ok": True}


def status() -> dict:
    return {
        "indexing": False,
        "progress": 1.0,
        "backend": "compat",
        "files": 5,
        "watchCount": 0,
        "watchCap": SETTINGS["watchCap"],
        "roots": list(SETTINGS["roots"]),
        "cacheBytes": 0,
        "cacheBudget": SETTINGS["cacheMb"] * 1024 * 1024,
        "poppler": shutil.which("pdftoppm") is not None,
        "plocate": shutil.which("plocate") is not None or shutil.which("locate") is not None,
        "ffmpeg": shutil.which("ffmpeg") is not None,
        "helper": "compat",
        "version": "1.0.0",
    }


def handle(req: dict) -> dict:
    rid = int(req.get("id") or 0)
    cmd = req.get("cmd") or ("query" if "q" in req else "preview" if "path" in req else "status")
    if cmd == "query":
        hits, backend = search(str(req.get("q") or ""))
        return {"id": rid, "kind": "results", "results": hits, "indexing": False, "progress": 1.0, "backend": backend}
    if cmd in ("preview", "prefetch", "page"):
        return {"id": rid, "kind": "preview", "preview": preview(str(req.get("path") or ""), int(req.get("page") or 1))}
    if cmd == "open":
        r = open_path(str(req.get("path") or ""), False)
        return {"id": rid, "kind": "ok" if r.get("ok") else "error", "error": r.get("error")}
    if cmd == "reveal":
        r = open_path(str(req.get("path") or ""), True)
        return {"id": rid, "kind": "ok" if r.get("ok") else "error", "error": r.get("error")}
    if cmd == "config":
        apply_settings(req, persist=True)
        body = {"id": rid, "kind": "status", "status": status(), "indexing": False, "progress": 1.0, "backend": "compat"}
        return body
    if cmd in ("status", "capabilities", "warmup", "theme", "select"):
        body = {"id": rid, "kind": "status" if cmd in ("status", "capabilities") else "ok"}
        if body["kind"] == "status":
            body["status"] = status()
            body["indexing"] = False
            body["progress"] = 1.0
            body["backend"] = "compat"
        return body
    return {"id": rid, "kind": "error", "error": f"unknown cmd {cmd}"}


def main() -> None:
    oneshot = "--oneshot" in sys.argv
    if oneshot:
        payload = ""
        if "--oneshot" in sys.argv:
            i = sys.argv.index("--oneshot")
            if i + 1 < len(sys.argv):
                payload = sys.argv[i + 1]
        if not payload:
            payload = sys.stdin.readline()
        try:
            req = json.loads(payload)
        except json.JSONDecodeError as e:
            print(json.dumps({"id": 0, "kind": "error", "error": str(e)}), flush=True)
            return
        print(json.dumps(handle(req), ensure_ascii=False), flush=True)
        return
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError as e:
            print(json.dumps({"id": 0, "kind": "error", "error": str(e)}), flush=True)
            continue
        print(json.dumps(handle(req), ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
