#!/usr/bin/env python3
"""Install or remove a marked o.bind block in ~/.config/hypr/bindings.lua.

Writes happen only for an explicit Set hotkey / Remove click. Never unbind
anyone else's keys.
"""

import os
import stat
import tempfile
import sys



def _refuse_symlink(path: str) -> None:
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return
    if stat.S_ISLNK(st.st_mode):
        raise OSError("refusing symlink: %s" % path)
    if not stat.S_ISREG(st.st_mode):
        raise OSError("not a regular file: %s" % path)


def read_text_nofollow(path: str) -> str:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(path, flags)
    try:
        data = os.read(fd, 4_000_000)
    finally:
        os.close(fd)
    return data.decode("utf-8")


def write_text_atomic(path: str, text: str) -> None:
    parent = os.path.dirname(path) or "."
    os.makedirs(parent, exist_ok=True)
    pst = os.lstat(parent)
    if stat.S_ISLNK(pst.st_mode):
        raise OSError("refusing symlink directory: %s" % parent)
    _refuse_symlink(path)
    fd, tmp = tempfile.mkstemp(prefix=".bindings.", suffix=".tmp", dir=parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
        st = os.lstat(path)
        if stat.S_ISLNK(st.st_mode):
            raise OSError("refusing to leave a symlink at %s" % path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def bindings_path() -> str:
    config_home = os.environ.get("XDG_CONFIG_HOME") or os.path.join(
        os.path.expanduser("~"), ".config"
    )
    return os.path.join(config_home, "hypr", "bindings.lua")


def markers(plugin_id):
    return "-- BEGIN %s" % plugin_id, "-- END %s" % plugin_id


def strip_block(text, begin, end):
    if begin not in text or end not in text:
        return text, False
    pre = text[: text.index(begin)]
    post = text[text.index(end) + len(end) :].lstrip("\n")
    text = pre.rstrip()
    if post:
        text = text + "\n\n" + post.lstrip()
    if text and not text.endswith("\n"):
        text += "\n"
    return text, True


def write_text(path: str, text: str) -> None:
    write_text_atomic(path, text)


def install(plugin_id: str, block: str) -> int:
    if not block.endswith("\n"):
        block += "\n"
    path = bindings_path()
    begin, end = markers(plugin_id)
    chunk = f"{begin}\n{block}{end}\n"
    text = ""
    if os.path.islink(path):
        print("error: refusing symlink %s" % path, file=sys.stderr)
        return 1
    if os.path.isfile(path):
        text = read_text_nofollow(path)
    if begin in text and end in text:
        pre = text[: text.index(begin)]
        post = text[text.index(end) + len(end) :].lstrip("\n")
        text = pre.rstrip() + "\n\n" + chunk
        if post:
            text = text.rstrip() + "\n" + post
            if not text.endswith("\n"):
                text += "\n"
    else:
        if text and not text.endswith("\n"):
            text += "\n"
        text = text.rstrip() + "\n\n" + chunk
        if not text.endswith("\n"):
            text += "\n"
    write_text(path, text)
    print("ok")
    return 0


def remove(plugin_id: str) -> int:
    path = bindings_path()
    if not os.path.isfile(path):
        print("ok")
        return 0
    begin, end = markers(plugin_id)
    text = read_text_nofollow(path)
    text, found = strip_block(text, begin, end)
    if found:
        write_text(path, text)
    print("ok")
    return 0


def usage() -> None:
    print(
        "usage: install-binds.py PLUGIN_ID LUA_BLOCK\n"
        "       install-binds.py --remove PLUGIN_ID",
        file=sys.stderr,
    )


def main() -> int:
    argv = sys.argv[1:]
    if not argv:
        usage()
        return 2
    if argv[0] == "--remove":
        if len(argv) < 2:
            usage()
            return 2
        return remove(argv[1])
    if len(argv) >= 2 and argv[1] == "--remove":
        return remove(argv[0])
    if len(argv) < 2:
        usage()
        return 2
    return install(argv[0], argv[1])


if __name__ == "__main__":
    raise SystemExit(main())
