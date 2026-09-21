# unifi-viewer

A borderless mpv window showing your UniFi Protect cameras on macOS. Up to ten named feeds,
switched with a number key or the right-click menu, and a menu bar button that opens and
closes the viewer. LAN only — it talks to the UDM Pro directly and never leaves the network.

```
1-9, 0        select a feed, in config order
r             reload the current feed (back to live)
⌃⌥⌘R          reset the window to its default size and position on this screen
,             camera settings
q             close the viewer (quit, from a terminal)
right-click   menu of feed names
```

Those are the only keys that do anything. A number with no feed behind it does nothing.

A feed is any RTSP stream: different cameras, or different quality tiers of the same camera,
mixed however you like.

## Dock app

```sh
brew install mpv
./make-app.sh /Applications   # build straight to where you want it
```

Double-click it. On first launch, with nothing configured, it opens the settings window.
Reopen it any time with `,` or from the right-click menu.

The settings window and the menu bar button are compiled at build time, so `make-app.sh`
needs `swiftc` from the Xcode command line tools (`xcode-select --install`). Without it the
app still builds and runs, with neither: you configure feeds by editing `streams.conf` by
hand, and the app quits when the viewer closes.

## Menu bar button

The app stays in the menu bar after the viewer closes, as a small lens icon.

```
click         open the viewer on this screen, or close it if it is open here
              — if it is open on another screen, it moves to this one
right-click   Open or Close Viewer, Camera Settings..., Quit UniFi Viewer
⌃⌥⌘U          open the viewer on the screen it was last on, or close it
```

**Closing stops the stream** rather than hiding the window: mpv exits, so a closed viewer
uses no network and no CPU. What stays running is the menu bar button, at about 12 MB of
memory. The Dock icon is there only while the viewer is open.

**Opening shows the window at once**, with the "Loading" panel, and the picture follows
once Protect has set up the stream — the same wait as switching feeds. The viewer comes
back on the feed you were last watching.

**The screen is the one whose menu bar you clicked.** That needs each display to have its
own menu bar — System Settings → Desktop & Dock → "Displays have separate Spaces", on by
default. With it off there is one menu bar, on the main display, and the viewer opens there.
Moving to another screen closes and reopens the viewer, because mpv only chooses a screen
when its window is created; it accepts a change at runtime but leaves the window where it
is (tested on mpv 0.41).

`q`, Cmd+Q, the right-click Quit and the Dock tile's Quit all close the viewer and leave
the button. Quit the app itself from the button's right-click menu.

## Window position and size

Each screen remembers where you last put the window on it and how large you made it. A
screen you have not changed anything on keeps the default: each feed at its own size,
centred. The viewer opens at a screen's saved placement whichever way it opens there —
launching the app (on the screen it was last on), a menu bar click on that screen, or the
keyboard shortcut.

**Size is kept as a scale, not a width and height.** The feeds differ in shape — a 32:9
panorama, a portrait doorbell — and a fixed size would squeeze them all into one shape.
Shrink the window to 60% and every feed opens at 60% of its own size on that screen, and
switching feeds keeps both the scale and the window's top-left corner.

**⌃⌥⌘R** puts the window back to the default on the screen it is on, and forgets what that
screen had saved. It works while the viewer has focus, like the other keys. It restarts
the viewer rather than moving the window, so the picture reconnects: mpv 0.41 puts a
window moved while open in the wrong place on any display but the main one.

The menu bar button follows the window every 2 seconds while the viewer is open, and not
at all while it is closed. A move is only saved when the window's size did not change,
since mpv re-centres the window itself when a feed of another size opens. A saved
position that no longer fits the screen, after a resolution change for instance, is
ignored and the window opens centred.

On a MacBook display with a notch, mpv measures the usable area 2 points lower than macOS
does. Positions are measured against where mpv really put the window rather than
converted from macOS's figures, which otherwise moved the window down 2 points on every
reopen.

## Keyboard shortcut

**Control-Option-Command-U** (⌃⌥⌘U) opens the viewer on the screen it was last on, or
closes it if it is open. The last screen is wherever the window last was, including after
a drag, and is remembered across restarts. If that display is not connected, the viewer
opens on the screen with the pointer.

It works in any app, since it is registered system-wide, and needs no Accessibility
permission. The default was chosen because every other U combination already does
something: ⌘U underlines, ⇧⌘U is Finder's Utilities folder, ⌥⌘U is Safari's page source,
⌃⌘U is Music's lyrics, ⌃⌥U is VoiceOver's rotor, and ⌃U deletes to the start of a line.

To change it, open **Camera Settings** and click the shortcut next to **Menu Bar
Shortcut**, then press the new one (Esc cancels). **Reset to Default** puts ⌃⌥⌘U back.
The change applies on Save, with no restart. A new shortcut must include ⌘ or ⌃, so it
cannot take over ordinary typing, and is refused if macOS already uses it for something
(System Settings → Keyboard → Keyboard Shortcuts). Other apps' shortcuts cannot be
checked — macOS lets two apps register the same one without complaint — so if a shortcut
stops doing what another app expects, pick a different one.

**Build to one place and keep it there.** `make-app.sh` with no argument builds into the
repo, which is fine until you also copy the result somewhere — two bundles then share a
bundle id, Launch Services resolves either one, and because the Dock caches icons per
bundle id rather than per path, Finder and the App Switcher start disagreeing. The script
warns when it finds another copy.

The bundle is generated rather than committed. Rebuild it if you move the repo, since the
launcher holds an absolute path to `view.sh`, and after a `brew upgrade mpv`, since it
holds a copy of the mpv binary.

Logs go to `~/.cache/unifi-viewer/app.log`, truncated each time the viewer opens.

## From a terminal

```sh
cp streams.conf.example streams.conf   # then add your feeds
./view.sh          # the feed last watched, or the first
./view.sh 3        # third feed
```

There is no settings window outside the app bundle, so `view.sh` prints what to do instead.

## Configuring feeds

One feed per line, in `streams.conf`:

```
Front Door = rtsps://192.168.0.1:7441/aBcDeFgHiJ?enableSrtp
Driveway   = rtsps://192.168.0.1:7441/kLmNoPqRsT?enableSrtp
```

The name is whatever you want and appears in the right-click menu. **Order decides the
hotkey**: first line is `1`, ninth is `9`, tenth is `0`. Ten feeds maximum; the rest are
ignored with a warning. A name may contain spaces, but not `=`, since that separates the
two halves. A feed whose URL does not parse is skipped with a warning rather than stopping
the others from working.

To find the URLs in Protect: **click the camera → Settings → Share Livestream → enable
Secure RTSPS Output**. A link then appears under each resolution — copy the ones you want.
Each resolution is a separate stream with its own ID.

`streams.conf` is gitignored — the stream ID is the only credential these endpoints have.

## Which endpoint this uses

Paste the `rtsps://192.168.0.1:7441/<id>?enableSrtp` URL exactly as Protect shows it.
That is the documented, encrypted endpoint and it is what this uses by default.

Plenty of guides online tell you to rewrite that URL to plain RTSP on port 7447, because
the `rtsps` URL is SRTP-wrapped and older players choke on it. **That advice is out of
date.** Verified here against mpv 0.41 / FFmpeg 8.1.2: the `rtsps` URL plays fine, with or
without the `?enableSrtp` suffix. Port 7447 is undocumented, unencrypted, and could be
removed by Ubiquiti, so there is no reason to prefer it.

The rewrite is kept as a fallback for players that genuinely cannot do RTSP-over-TLS:

```sh
RTSP_MODE=plain ./view.sh          # rtsp://192.168.0.1:7447/<id>
```

If the `rtsps` endpoint itself ever breaks, the other escape hatch is
[go2rtc](https://github.com/AlexxIT/go2rtc), whose `rtspx://` scheme exists for these cameras.

## Notes

- Protect streams are **HEVC**, and VideoToolbox hardware decode engages on Apple Silicon.
  Measured on an M1 Max, a 7680x2160 feed costs about **18% CPU** against a 2560x720 feed's
  **17%**, with no dropped frames — decode is on a dedicated block, so resolution barely
  matters. The real cost of a large feed is network bandwidth.
- **Window size is the stream's own size**, on open and on every switch. A 2560x720 feed
  opens at 2560x720, 1:1. Feeds need not match each other — mixing a 7680x2160 panorama
  with a portrait 1920x2560 doorbell works, and the window changes shape to suit. Anything
  larger than the display is capped by `--autofit-larger=100%x100%` to whichever screen the
  window is on. Only the cap uses `--autofit-larger`; plain `--autofit` forces one size on
  every feed.
- **Switching dims the picture** and names the incoming feed until frames arrive. The RTSP
  handshake can take several seconds, and without that the window looks frozen rather than busy. It
  reappears on a reconnect too.
- The **right-click menu** is built by `tools/menu.lua` writing mpv's `menu-data` property.
  mpv 0.41 has that property but not the `menu.conf` file support that landed after it, so
  the menu is assembled in the script. Doing it there is what lets the tick follow the feed
  that is playing.
- The **macOS menu bar is mpv's own** and cannot be customised — it is hardcoded in mpv's
  `menu_bar.swift`. `--macos-menu-shortcuts=no` would suppress its shortcuts, but that also
  kills Cmd+Q, so it is left alone.
- Audio is disabled (`--no-audio`). Protect 2.0 changed the camera audio sample rate in a
  way that breaks ffmpeg, and this sidesteps it.
- Connecting part-way through a GOP means the decoder briefly has no keyframe to reference.
  libavcodec logs `Could not find ref with POC n` until the next one arrives — up to ~5s,
  which is the keyframe interval on these cameras. Those frames are skipped rather than
  rendered, so the picture is unaffected. `--msg-level=ffmpeg=fatal` hides the noise while
  leaving mpv's own connection errors visible.
- **mpv's default bindings are switched off entirely** (`--input-builtin-bindings=no`,
  `--input-default-bindings=no`, `--input-media-keys=no`). Left on, a number key with no
  feed behind it adjusts picture settings — 5/6 gamma, 7/8 saturation, 9/0 volume — which
  persist and quietly degrade the image with no obvious cause. Only the keys listed at the
  top are live. The right-click menu is unaffected, since it uses forced bindings, which
  override `input.conf` and are exempt from both flags.
- **Some things no binding can reach.** mpv's macOS menu bar sends commands straight to the
  core, so `menu.lua` pins three properties instead: `pause` (a live camera has nothing to
  resume to), `loop-file` (Playback → Toggle Loop File would flip it to `no`, and `view.sh`
  relies on `inf` to tell a dropped stream from a deliberate quit — the app would exit
  silently on the next drop), and `speed`.
- `r` reloads the current feed, which is the only real "back to live" for RTSP, since a live
  stream cannot be seeked.
- `,` opens Camera Settings, not Cmd+`,`. The macOS menu bar is mpv's own and its
  "Settings…" item already holds Cmd+`,` as a menu key equivalent, which AppKit consumes
  before mpv's core sees it. That item opens `mpv.conf` and is hardcoded in the mpv binary,
  so it cannot be repointed.
- The window has no titlebar. Drag it by clicking anywhere on the video.
- `--loop-file=inf` is doing more than it looks. A dropped stream used to exit mpv with
  code 0 — the same code Cmd+Q produces, since mpv's macOS menu sends a bare `quit`
  straight to the core that no keybinding can intercept. The retry loop could not tell them
  apart, so Cmd+Q would have silently reconnected instead of quitting. With the flag, mpv
  reconnects in place and never exits on a drop, so any exit really is a quit.
- The app bundle contains a copy of the mpv binary. Running mpv from inside `Contents/MacOS`
  is what makes macOS resolve the bundle's `Info.plist`, so the Dock tile shows this app's
  name and icon. Launched from the Homebrew path it shows a bare "mpv" instead.
- The launcher exports **`MPVBUNDLE=true`**. Without it mpv replaces the Dock and App
  Switcher icon with its own logo — `video/out/mac/common.swift` sets
  `NSApp.applicationIconImage` unless that variable is set, on the assumption that an
  unbundled binary has no icon of its own. Finder is unaffected, since it reads the bundle
  rather than the running process, which is why the two can disagree.
- If an icon ever looks stuck, it is Launch Services caching. `make-app.sh` stamps a fresh
  `CFBundleVersion` on every build and restarts the Dock to avoid it. The heavier reset is
  `rm -rf ~/Library/Caches/com.apple.iconservices.store && killall Finder Dock`.
- The settings window does no URL validation on purpose. `lib.sh` already validates, and a
  second implementation in Swift would be one more thing to keep in step; `view.sh` reopens
  the window when what was saved yields no usable feeds.

## Tests

```sh
./test.sh            # 164 unit tests for the config, URL, menu bar, shortcut and placement logic — no network needed
./test-contract.sh   # pulls a frame from every configured feed
```

`test-contract.sh` needs the cameras reachable. It skips cleanly when the gateway does not
answer, so being off the network never means a red build. Run it before opening a PR.

Protect is intermittently slow to set up an RTSP session — most connect in about 10s, but
occasionally one takes over 35s, and which feed is affected varies. The test allows one
retry per feed and pauses between them. Without that it failed about one run in three,
which would have made it noise rather than a signal.

## Requirements

macOS on Apple Silicon or Intel, [mpv](https://mpv.io) via Homebrew, and a UniFi Protect
setup reachable on the LAN. Building the settings window also needs `swiftc` from the Xcode
command line tools. Developed against mpv 0.41 — the menu and binding behaviour it relies on
differs in earlier versions.

## Licence

MIT. See [LICENSE](LICENSE).
