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
    "keyrings",
    "kwalletd",
)

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


def find_names(q: str, limit: int) -> list[dict]:
    if shutil.which("find") is None:
        return []
    roots = [r for r in SETTINGS["roots"] if r]
    if not roots:
        roots = [str(HOME)]
    cap = min(int(limit), 40)
    out: list[dict] = []
    try:
        proc = subprocess.run(
            ["find", *roots, "-maxdepth", "6", "-iname", f"*{q}*", "-print"],
            capture_output=True,
            text=True,
            timeout=2,
        )
    except (subprocess.TimeoutExpired, OSError):
        return out
    skip = skip_parts()
    for line in proc.stdout.splitlines():
        if any(f"/{s}/" in line or line.endswith("/" + s) for s in skip):
            continue
        p = Path(line)
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
    return out[: min(cap, SETTINGS["maxFiles"])]


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
        return {"kind": "image", "path": str(path), "animated": path.suffix.lower() == ".gif"}
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
        if not shutil.which("pdftoppm"):
            return {"kind": "pdf", "need_poppler": True, "page": page, "page_count": 1,
                    "label": "install poppler for PDF previews", "magic": "PDF document"}
        CACHE.mkdir(parents=True, exist_ok=True)
        dest_prefix = CACHE / "compat-pdf"
        try:
            subprocess.run(
                ["pdftoppm", "-f", str(page), "-l", str(page), "-png", "-r", "120",
                 "-singlefile", str(path), str(dest_prefix)],
                timeout=8,
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except (subprocess.TimeoutExpired, OSError):
            return {"kind": "pdf", "label": "couldn't render this page", "need_poppler": False,
                    "render_error": True}
        png = Path(str(dest_prefix) + ".png")
        if png.is_file():
            return {"kind": "pdf", "path": str(png), "page": page, "page_count": 1, "need_poppler": False}
        return {"kind": "pdf", "label": "couldn't render this page", "need_poppler": False,
                "render_error": True}
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
