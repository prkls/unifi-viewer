#!/usr/bin/env python3
"""Cut the menus this app has no use for out of mpv's macOS menu bar.

    trim-mpv-menu.py <mpv source directory>

mpv builds its menu bar in Swift, in osdep/mac/menu_bar.swift, and it cannot be
changed at runtime: the items send commands straight to mpv, where no key
binding or script can reach them. Since this app builds its own mpv
(tools/build-mpv.sh), the menus can be cut down at the source instead.

Out go Audio, Subtitle and Playback, which do nothing for a live video-only
camera feed, and the Video menu's zoom items, which do nothing here either.

The edits are checked rather than assumed: each one must match exactly once, or
this stops. Running it twice is harmless — it notices the work is already done.
Whatever is removed here, remember mpv is GPL software: this script is part of
the source published with every release.
"""
import re
import sys
from datetime import date

MENUS_TO_DROP = ["audio", "subtitle", "playback", "video"]

# GPLv2 section 2(a): a modified file must carry a prominent notice saying it
# was changed, and when. mpv is GPL software, so this goes at the top of every
# file this script touches.
NOTICE_MARK = "Modified for UniFi Viewer"
NOTICE = """\
// {mark} on {when} by tools/trim-mpv-menu.py.
// Changed: removed the Audio, Subtitle, Playback and Video menus, which do
// nothing for a live video-only camera feed, and pointed the Help menu at
// UniFi Viewer instead of mpv. The unmodified source of this file is published
// with every UniFi Viewer release.

"""

# mpv's Help menu sends people to mpv for help with an app that is not mpv.
HELP_OLD = """\
            Config(name: "mpv Website…", action: #selector(url(_:)), target: self, url: "https://mpv.io"),
            Config(name: "mpv on GitHub…", action: #selector(url(_:)), target: self, url: "https://github.com/mpv-player/mpv"),
            Config(type: .separator),
            Config(name: "Online Manual…", action: #selector(url(_:)), target: self, url: "https://mpv.io/manual/master/"),
            Config(name: "Online Wiki…", action: #selector(url(_:)), target: self, url: "https://github.com/mpv-player/mpv/wiki"),
            Config(name: "Release Notes…", action: #selector(url(_:)), target: self, url: "https://github.com/mpv-player/mpv/blob/master/RELEASE_NOTES"),
            Config(name: "Keyboard Shortcuts…", action: #selector(url(_:)), target: self, url: "https://github.com/mpv-player/mpv/blob/master/etc/input.conf"),
            Config(type: .separator),
            Config(name: "Report Issue…", action: #selector(url(_:)), target: self, url: "https://github.com/mpv-player/mpv/issues/new/choose")
"""

HELP_NEW = """\
            Config(name: "UniFi Viewer Website…", action: #selector(url(_:)), target: self, url: "https://prkls.github.io/unifi-viewer"),
            Config(name: "UniFi Viewer on GitHub…", action: #selector(url(_:)), target: self, url: "https://github.com/prkls/unifi-viewer"),
            Config(type: .separator),
            Config(name: "Report Issue…", action: #selector(url(_:)), target: self, url: "https://github.com/prkls/unifi-viewer/issues/new"),
            Config(type: .separator),
            Config(name: "Built with mpv…", action: #selector(url(_:)), target: self, url: "https://mpv.io")
"""

# The Video menu's zoom items, with the separator that follows them, as one
# block: a separator line on its own appears a dozen times in this file. Only
# needed if the Video menu itself is kept; dropping the menu takes them along.
ZOOM_BLOCK = """\
            Config(name: "Zoom Out", action: #selector(command(_:)), target: self, command: "add panscan -0.1"),
            Config(name: "Zoom In", action: #selector(command(_:)), target: self, command: "add panscan 0.1"),
            Config(name: "Reset Zoom", action: #selector(command(_:)), target: self, command: "set panscan 0"),
            Config(type: .separator),
"""


def drop_block(text, name):
    """Remove `let <name>MenuConfigs = [ ... ]`, brackets and all."""
    start = text.find(f"        let {name}MenuConfigs = [\n")
    if start == -1:
        return text, False
    end = text.find("\n        ]\n", start)
    if end == -1:
        sys.exit(f"trim-mpv-menu.py: cannot find the end of {name}MenuConfigs")
    return text[:start] + text[end + len("\n        ]\n"):], True


def drop_line(text, needle, what):
    """Remove the one line containing `needle`."""
    lines = text.splitlines(keepends=True)
    matches = [i for i, line in enumerate(lines) if needle in line]
    if not matches:
        return text, False
    if len(matches) > 1:
        sys.exit(f"trim-mpv-menu.py: {what} appears {len(matches)} times, expected one")
    del lines[matches[0]]
    return "".join(lines), True


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: trim-mpv-menu.py <mpv source directory>")
    path = f"{sys.argv[1]}/osdep/mac/menu_bar.swift"
    try:
        original = open(path).read()
    except OSError as error:
        sys.exit(f"trim-mpv-menu.py: {error}")

    text = original
    changed = []

    for name in MENUS_TO_DROP:
        text, gone = drop_block(text, name)
        registration = f'Config(name: "{name.capitalize()}", configs: {name}MenuConfigs),'
        text, unregistered = drop_line(text, registration, registration)
        if gone != unregistered:
            sys.exit(f"trim-mpv-menu.py: {name} menu half removed; mpv's source has changed")
        if gone:
            changed.append(name.capitalize())

    helps = text.count(HELP_OLD)
    if helps > 1:
        sys.exit(f"trim-mpv-menu.py: the help menu appears {helps} times, expected one")
    if helps == 1:
        text = text.replace(HELP_OLD, HELP_NEW)
        changed.append("Help menu pointed at UniFi Viewer")

    zooms = text.count(ZOOM_BLOCK)
    if zooms > 1:
        sys.exit(f"trim-mpv-menu.py: the zoom block appears {zooms} times, expected one")
    if zooms == 1:
        text = text.replace(ZOOM_BLOCK, "")
        changed.append("Video zoom")

    if text == original:
        print("mpv's menus are already trimmed")
        return

    # A menu left with nothing in it, or a stray double separator, would mean
    # the edits no longer match what mpv's source looks like.
    for name in MENUS_TO_DROP:
        if f"{name}MenuConfigs" in text:
            sys.exit(f"trim-mpv-menu.py: {name}MenuConfigs is still referenced")
    if re.search(r"Config\(type: \.separator\),\s*\n\s*Config\(type: \.separator\),", text):
        sys.exit("trim-mpv-menu.py: the edits left two separators together")

    if NOTICE_MARK not in text:
        text = NOTICE.format(mark=NOTICE_MARK, when=date.today().isoformat()) + text

    open(path, "w").write(text)
    print("trimmed mpv's menus: " + ", ".join(dict.fromkeys(changed)))


if __name__ == "__main__":
    main()
