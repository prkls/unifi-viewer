#!/usr/bin/env python3
"""Make mpv's macOS menu bar this app's menu bar.

    mpv-menus.py <mpv source directory>

mpv builds its menu bar in Swift, in osdep/mac/menu_bar.swift, and it cannot be
changed at runtime: the items send commands straight to mpv, where no key
binding or script can reach them. Since this app builds its own mpv
(tools/build-mpv.sh), the menus are changed at the source instead.

What changes:
  - Audio, Subtitle, Playback and Video go. None of them does anything for a
    live video-only camera feed.
  - File keeps Close and Save Screenshot. Opening files, URLs and playlists is
    not what this app is for.
  - The app menu is about UniFi Viewer, not mpv: its own About box, Camera
    Settings in place of mpv's config-file items, which opened a dialog about a
    file that does not exist here, and its own Hide and Quit wording. Quit and
    Remember Position goes, being meaningless for a live stream.
  - Help points at this project, with a credit to mpv at the end.

The edits are checked rather than assumed: each one must match exactly once, or
this stops, so a future mpv that moves these lines fails the build instead of
quietly shipping the old menus. Running it twice is harmless.

mpv is GPL software. Every file changed here gets a notice saying so, and the
unmodified source is published with each release.
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
// {mark} on {when} by tools/mpv-menus.py.
// Changed: removed the Audio, Subtitle, Playback and Video menus, cut the File
// menu down to Save Screenshot (now on Cmd+S) and Close, dropped the log file
// item, made the app menu UniFi Viewer's rather than mpv's, and pointed Help at
// this project. The unmodified source of this file is published with every
// UniFi Viewer release.

"""

# mpv's File menu offers to open files, URLs and playlists. This app plays the
# cameras you configured and nothing else. What is left is the screenshot,
# first and on Cmd+S because it is the item anyone comes to this menu for, and
# Close under it. Screenshots land on the Desktop, named after the camera and
# the time (see --screenshot-template in view.sh).
FILE_OLD = """\
            Config(name: "Open File…", key: "o", action: #selector(openFiles), target: self),
            Config(name: "Open URL…", key: "O", action: #selector(openUrl), target: self),
            Config(name: "Open Playlist…", action: #selector(openPlaylist), target: self),
            Config(type: .separator),
            Config(name: "Close", key: "w", action: #selector(NSWindow.performClose(_:))),
            Config(name: "Save Screenshot", action: #selector(command(_:)), target: self, command: "async screenshot")
"""

FILE_NEW = """\
            Config(name: "Save Screenshot", key: "s", action: #selector(command(_:)), target: self, command: "async screenshot"),
            Config(name: "Close", key: "w", action: #selector(NSWindow.performClose(_:)))
"""

# mpv's app menu is about mpv: its About box, and two items that open mpv
# config files this app does not use — selecting them offered to create an
# mpv.conf. Camera Settings takes their place, using the same exit code the
# comma key uses, which view.sh answers by opening the settings window.
APP_OLD = """\
            Config(name: "About mpv", action: #selector(about), target: self),
            Config(type: .separator),
            Config(
                name: "Settings…",
                key: ",",
                action: #selector(settings(_:)),
                target: self,
                url: "mpv.conf"
            ),
            Config(
                name: "Keyboard Shortcuts Config…",
                action: #selector(settings(_:)),
                target: self,
                url: "input.conf"
            ),
            Config(type: .separator),
            Config(name: "Services", type: .menuServices),
            Config(type: .separator),
            Config(name: "Hide mpv", key: "h", action: #selector(NSApp.hide(_:))),
"""

APP_NEW = """\
            Config(name: "About UniFi Viewer", action: #selector(about), target: self),
            Config(type: .separator),
            Config(name: "Camera Settings…", key: ",", action: #selector(command(_:)), target: self, command: "quit 20"),
            Config(type: .separator),
            Config(name: "Services", type: .menuServices),
            Config(type: .separator),
            Config(name: "Hide UniFi Viewer", key: "h", action: #selector(NSApp.hide(_:))),
"""

QUIT_OLD = """\
            Config(name: "Quit and Remember Position", action: #selector(command(_:)), target: self, command: "quit-watch-later"),
            Config(name: "Quit mpv", key: "q", action: #selector(command(_:)), target: self, command: "quit")
"""

QUIT_NEW = """\
            Config(name: "Quit UniFi Viewer", key: "q", action: #selector(command(_:)), target: self, command: "quit")
"""

# mpv's About box names mpv. This one names the app and credits mpv, with a way
# to reach the project.
ABOUT_OLD = """\
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "mpv",
            .applicationIcon: appIcon,
            .applicationVersion: String(cString: swift_mpv_version),
            .init(rawValue: "Copyright"): String(cString: swift_mpv_copyright)
        ])
"""

ABOUT_NEW = """\
        let about = NSAlert()
        about.messageText = "UniFi Viewer"
        about.informativeText = \"\"\"
            A borderless window on your UniFi Protect cameras.

            Plays them with \\(String(cString: swift_mpv_version)), which is free software \
under the GPL. The source of everything inside is published with each release.
            \"\"\"
        about.icon = appIcon
        about.addButton(withTitle: "OK")
        about.addButton(withTitle: "Project Page")
        if about.runModal() == .alertSecondButtonReturn {
            if let page = URL(string: "https://prkls.github.io/unifi-viewer") {
                NSWorkspace.shared.open(page)
            }
        }
"""

# mpv adds this to Help in a bundle. It opens a log this app does not write,
# so choosing it only ever put up a dialog saying there was none. With it gone
# the list is never added to, so it becomes a constant.
LOG_OLD = """\
        var helpMenuConfigs = [
"""

LOG_NEW = """\
        let helpMenuConfigs = [
"""

LOG_BLOCK = """\
        if AppHub.shared.isBundle {
            helpMenuConfigs += [
                Config(name: "Show log File…", action: #selector(showFile(_:)), target: self, url: NSHomeDirectory() + "/Library/Logs/mpv.log")
            ]
        }
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
        sys.exit(f"mpv-menus.py: cannot find the end of {name}MenuConfigs")
    return text[:start] + text[end + len("\n        ]\n"):], True


def drop_line(text, needle, what):
    """Remove the one line containing `needle`."""
    lines = text.splitlines(keepends=True)
    matches = [i for i, line in enumerate(lines) if needle in line]
    if not matches:
        return text, False
    if len(matches) > 1:
        sys.exit(f"mpv-menus.py: {what} appears {len(matches)} times, expected one")
    del lines[matches[0]]
    return "".join(lines), True


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: mpv-menus.py <mpv source directory>")
    path = f"{sys.argv[1]}/osdep/mac/menu_bar.swift"
    try:
        original = open(path).read()
    except OSError as error:
        sys.exit(f"mpv-menus.py: {error}")

    text = original
    changed = []

    for name in MENUS_TO_DROP:
        text, gone = drop_block(text, name)
        registration = f'Config(name: "{name.capitalize()}", configs: {name}MenuConfigs),'
        text, unregistered = drop_line(text, registration, registration)
        if gone != unregistered:
            sys.exit(f"mpv-menus.py: {name} menu half removed; mpv's source has changed")
        if gone:
            changed.append(name.capitalize())

    for old, new, what in [(LOG_BLOCK, "", "log file item"),
                           (LOG_OLD, LOG_NEW, "help menu constant"),
                           (FILE_OLD, FILE_NEW, "File menu"),
                           (APP_OLD, APP_NEW, "app menu"),
                           (QUIT_OLD, QUIT_NEW, "Quit item"),
                           (ABOUT_OLD, ABOUT_NEW, "About box")]:
        found = text.count(old)
        if found > 1:
            sys.exit(f"mpv-menus.py: the {what} appears {found} times, expected one")
        if found == 1:
            text = text.replace(old, new)
            changed.append(what)

    helps = text.count(HELP_OLD)
    if helps > 1:
        sys.exit(f"mpv-menus.py: the help menu appears {helps} times, expected one")
    if helps == 1:
        text = text.replace(HELP_OLD, HELP_NEW)
        changed.append("Help menu pointed at UniFi Viewer")

    zooms = text.count(ZOOM_BLOCK)
    if zooms > 1:
        sys.exit(f"mpv-menus.py: the zoom block appears {zooms} times, expected one")
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
            sys.exit(f"mpv-menus.py: {name}MenuConfigs is still referenced")
    if re.search(r"Config\(type: \.separator\),\s*\n\s*Config\(type: \.separator\),", text):
        sys.exit("mpv-menus.py: the edits left two separators together")

    if NOTICE_MARK not in text:
        text = NOTICE.format(mark=NOTICE_MARK, when=date.today().isoformat()) + text

    open(path, "w").write(text)
    print("reworked mpv's menus: " + ", ".join(dict.fromkeys(changed)))


if __name__ == "__main__":
    main()
