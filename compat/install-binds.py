#!/usr/bin/env python3
"""Install or remove a marked o.bind block in ~/.config/hypr/bindings.lua.

Writes happen only for an explicit Set hotkey / Remove click. Never unbind
anyone else's keys.
"""

import os
import sys


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
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)


def install(plugin_id: str, block: str) -> int:
    if not block.endswith("\n"):
        block += "\n"
    path = bindings_path()
    begin, end = markers(plugin_id)
    chunk = f"{begin}\n{block}{end}\n"
    text = ""
    if os.path.isfile(path):
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
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
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
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
