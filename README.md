# unifi-viewer

A borderless window on your UniFi Protect cameras for macOS, with a menu bar button to open
and close it. Up to ten named feeds, switched with a number key or a right-click menu. It
talks to your Protect console directly over the LAN and never leaves the network.

## Requirements

- macOS on Apple Silicon or Intel
- [Homebrew](https://brew.sh), for mpv
- The Xcode command line tools, for the settings window and the menu bar button
- A UniFi Protect console reachable on your network

## Install

1. **Get the code.** Clone it somewhere you will keep it. The app runs the scripts from
   this folder, so moving the folder later means rebuilding.

   ```sh
   git clone https://github.com/prkls/unifi-viewer.git
   cd unifi-viewer
   ```

2. **Install mpv and the command line tools.**

   ```sh
   brew install mpv
   xcode-select --install     # skip if already installed
   ```

3. **Build the app into Applications.**

   ```sh
   ./make-app.sh /Applications
   ```

4. **Open UniFi Viewer** from Applications. The first time, the settings window opens so
   you can add your cameras (next section).

Build to one place and keep it there. Two copies of the app share a bundle ID, and macOS
then shows the wrong icon in places. `make-app.sh` warns if it finds another copy.

## Add your cameras

Each camera stream has a URL in Protect. To get it: **click the camera → Settings → Share
Livestream → turn on Secure RTSPS Output.** A link appears under each resolution. Each
resolution is a separate stream, so copy the ones you want.

Paste them into the settings window, one per row, with a name for each. Open the window
again at any time with `,` in the viewer or from the menu bar button's right-click menu.

The settings are saved to `streams.conf` in the repo folder, which you can also edit by
hand:

```
Front Door = rtsps://192.168.0.1:7441/aBcDeFgHiJ?enableSrtp
Driveway   = rtsps://192.168.0.1:7441/kLmNoPqRsT?enableSrtp
```

- **Order sets the key:** the first line is `1`, the ninth `9`, the tenth `0`. Lines after
  the tenth are ignored with a warning.
- A name can contain spaces but not `=`.
- A line whose URL does not parse is skipped with a warning; the others still work.
- A feed is any RTSP stream, so you can mix cameras and quality levels of the same camera.
- `streams.conf` is gitignored. The stream ID in the URL is the only credential these
  streams have, so keep it private.

## Use it

### In the viewer

```
1-9, 0        switch feed, in the order of streams.conf
r             reload the feed (back to live)
,             camera settings
⌃⌥⌘R          reset the window to its default size and position on this screen
q             close the viewer
right-click   menu of feeds, reload, settings and quit
```

No other keys do anything. Drag the window by clicking anywhere on the video.

### The menu bar button

The app stays in the menu bar as a small lens icon, also when the viewer is closed.

```
click         open the viewer on this screen, or close it if it is open here;
              if it is open on another screen, it moves here
right-click   Open or Close Viewer, Camera Settings..., Quit UniFi Viewer
⌃⌥⌘U          open the viewer on the screen it was last on, or close it
```

- **Closing stops the stream.** mpv exits, so a closed viewer uses no network and no CPU.
  Only the menu bar button keeps running, at about 12 MB of memory. The Dock icon is shown
  only while the viewer is open.
- **Opening shows the window at once** with a "Loading" panel. The picture follows when
  Protect has set up the stream, which usually takes a few seconds. The viewer reopens on
  the feed you were last watching.
- **The viewer opens on the screen whose menu bar you clicked.** This needs each display to
  have its own menu bar: System Settings → Desktop & Dock → "Displays have separate
  Spaces", which is on by default. With it off, the viewer opens on the main display.
- **Closing is not quitting.** `q`, Cmd+Q and the viewer's Quit items close the viewer and
  leave the button. Quit the app from the button's right-click menu.

### Window position and size

Each screen remembers where you last put the window on it and how large you made it. A
screen where you have changed nothing gets the default: the feed at its own size,
centred. The viewer opens at the screen's saved placement however it is opened.

Size is saved as a scale, not a fixed width and height, because the feeds differ in shape.
Shrink the window to 60% and every feed opens at 60% of its own size on that screen.
Switching feeds keeps the scale and keeps the window centred where you put it.

`⌃⌥⌘R` puts the window back to the default on its screen and forgets that screen's saved
placement. The picture reconnects, because the reset restarts the viewer.

### The keyboard shortcut

`⌃⌥⌘U` (Control-Option-Command-U) works in any app. It opens the viewer on the screen it
was last on, or on the screen with the pointer if that display is not connected. It needs
no Accessibility permission. The default was chosen because every other combination of U
with modifiers is already taken: ⌘U underlines, ⇧⌘U opens Finder's Utilities folder, ⌥⌘U
is Safari's page source, ⌃⌘U is Music's lyrics, ⌃⌥U is VoiceOver's rotor, and ⌃U deletes
to the start of a line.

To change it, open **Camera Settings**, click the shortcut next to **Menu Bar Shortcut**
and press the new one (Esc cancels). **Reset to Default** restores ⌃⌥⌘U. It takes effect
when you save.

- A shortcut must include ⌘ or ⌃, so it cannot take over ordinary typing.
- A shortcut macOS already uses (System Settings → Keyboard → Keyboard Shortcuts) is
  refused.
- Other apps' shortcuts cannot be checked, because macOS lets two apps register the same
  one. If your shortcut stops another app's from working, pick a different one.

## Update or rebuild

Run `./make-app.sh /Applications` again:

- after pulling new code, for changes to the settings window or the menu bar button;
- after moving the repo folder, since the app stores the path to it;
- after `brew upgrade mpv`, since the app contains a copy of the mpv program.

Changes to the scripts (`view.sh`, `lib.sh`) take effect the next time the viewer opens,
without a rebuild.

Without the Xcode command line tools, `make-app.sh` still builds a working app, but with
no settings window and no menu bar button. Feeds are then set in `streams.conf` by hand,
and the app quits when the viewer closes.

## Troubleshooting

- **No picture, or it keeps reconnecting:** see `~/.cache/unifi-viewer/app.log`, which is
  cleared each time the viewer opens.
- **The window came back in the wrong place or size:** see
  `~/.cache/unifi-viewer/placement.log`. It records each open, each look at the window and
  each save, with the reason, and keeps the last 500 lines.
- **The icon looks stuck or wrong:** that is macOS's icon cache. `make-app.sh` refreshes it
  on every build. For a full reset:
  `rm -rf ~/Library/Caches/com.apple.iconservices.store && killall Finder Dock`.
- **The stream will not play at all:** see [Which stream endpoint](#which-stream-endpoint)
  below for a fallback.

## Run from a terminal

The viewer also runs without the app. There is no settings window then, so edit
`streams.conf` by hand.

```sh
cp streams.conf.example streams.conf   # then add your feeds
./view.sh          # the feed last watched, or the first
./view.sh 3        # the third feed
```

## How it works

### Which stream endpoint

Use the `rtsps://192.168.0.1:7441/<id>?enableSrtp` URL exactly as Protect shows it. It is
the documented, encrypted endpoint, and the default here.

Many guides say to rewrite it to plain RTSP on port 7447, because older players cannot
handle the `rtsps` stream. That advice is out of date: with mpv 0.41 and FFmpeg 8.1.2 the
`rtsps` URL plays fine, with or without `?enableSrtp`. Port 7447 is undocumented and
unencrypted, and Ubiquiti could remove it. The rewrite is kept as a fallback:

```sh
RTSP_MODE=plain ./view.sh          # uses rtsp://192.168.0.1:7447/<id>
```

If the `rtsps` endpoint ever breaks, the other option is
[go2rtc](https://github.com/AlexxIT/go2rtc), whose `rtspx://` scheme exists for these
cameras.

### Playback

- Protect streams are **HEVC**, decoded in hardware by VideoToolbox. Measured on an M1 Max,
  a 7680x2160 feed costs about **18% CPU** against **17%** for a 2560x720 feed, with no
  dropped frames. Decoding runs on dedicated hardware, so resolution barely matters; the
  real cost of a large feed is network bandwidth.
- **Audio is off** (`--no-audio`). Protect 2.0 changed the camera audio sample rate in a way
  that breaks ffmpeg.
- **Switching feeds dims the picture** and names the incoming feed until frames arrive. The
  stream setup takes a few seconds, and without the panel the window looks frozen. It also
  shows during a reconnect.
- Joining a stream part-way through means the decoder waits up to about 5 seconds for the
  next keyframe, and libavcodec logs `Could not find ref with POC n` meanwhile. Those
  frames are skipped, so the picture is unaffected. `--msg-level=ffmpeg=fatal` hides the
  noise and keeps mpv's own connection errors.
- `r` reloads the feed because a live stream cannot be seeked; reloading is the only way
  back to live.
- `--loop-file=inf` makes mpv reconnect in place when a stream drops. Without it, a drop
  exited mpv with code 0, the same as Cmd+Q, and the retry loop in `view.sh` could not tell
  a drop from a quit. With it, any exit is a real quit.

### Keys and menus

- **mpv's own key bindings are off** (`--input-builtin-bindings=no`,
  `--input-default-bindings=no`, `--input-media-keys=no`). Left on, a number key with no
  feed behind it changed picture settings (5/6 gamma, 7/8 saturation, 9/0 volume), which
  persisted and quietly degraded the image.
- **mpv's macOS menu bar sends commands straight to mpv**, where no key binding can catch
  them. The menu bar button watches three properties over the socket and puts them back
  instead: `pause` (a live camera has nothing to resume to), `loop-file` (turning it off
  would make the app exit silently on the next drop) and `speed`.
- **The macOS menu bar is mpv's own**, built into it in `menu_bar.swift` and not changeable
  at runtime: its items send commands straight to mpv, where no binding or script can reach
  them. Since the app builds its own mpv, `tools/mpv-menus.py` rewrites them at the source
  instead. Audio, Subtitle, Playback and Video go, none of them doing anything for a live
  video-only feed. File keeps Close and Save Screenshot. The app menu becomes this app's:
  its own About box, Camera Settings in place of mpv's config-file items, which offered to
  create an `mpv.conf` this app never reads, and no "Quit and Remember Position". Help points
  at this project, with a credit to mpv at the end. What is left is File, Edit, View, Window
  and Help. The script checks each edit matches exactly once, so a future mpv that moves
  those lines stops the build rather than quietly shipping the old menus, and it writes a
  notice into each file it changes, which is what the GPL asks of a modified file.
- **Screenshots go to the Desktop.** The app runs from inside its own bundle, which is not
  writable, so `--screenshot-dir` points somewhere that is.
- **Settings is `,`, not Cmd+`,`**, because mpv's menu bar already uses Cmd+`,` for its own
  Settings item, which opens `mpv.conf` and cannot be pointed elsewhere.
- **The viewer is driven over mpv's IPC socket**, by the menu bar button. The right-click
  menu, the "Loading" panel, feed switches and the properties above all go through it, and
  the viewer runs with `--load-scripts=no`. That is what lets the app ship an mpv built
  without a scripting engine, which in turn keeps LuaJIT — and the just-in-time compilation
  that Apple's hardened runtime blocks — out of the app.
- **The right-click menu is a macOS menu**, shown by the menu bar button when it sees a
  right-click over the viewer's window. mpv has a `context-menu` command and a `menu-data`
  property, but on macOS that command does nothing: mpv's own menu is drawn inside the
  video by a Lua script it ships, which is why it used to have font-size and scaling
  settings.
- **Keys go straight to mpv** where they can: each feed key runs `loadfile` on that feed's
  URL, so switching works even with nothing connected to the socket. `r` and the reset
  shortcut run `script-message`, which mpv broadcasts to everything connected, which is how
  a key in the viewer reaches the menu bar button.

### Window placement

- **The viewer can only choose a screen when it opens.** mpv accepts a new screen while
  running but leaves the window where it is (tested on mpv 0.41). The menu bar button
  moves the viewer by restarting it on the other screen. For the same reason, `⌃⌥⌘R`
  restarts the viewer: mpv 0.41 puts a window moved while running in the wrong place on
  any display but the main one.
- **Feeds larger than the screen are shrunk to fit it**, with their shape kept
  (`--autofit-larger=100%x100%`). Plain `--autofit` would force every feed to one size.
- **Nothing polls the window.** The menu bar button looks at it when the mouse button comes
  up after a drag or resize, when the viewer reports a feed's size over the socket, and
  when it closes.
  Watching the mouse this way needs no Accessibility permission; Apple restricts only
  keyboard events. A move made with the keyboard alone, such as a macOS tiling shortcut, is
  saved at your next click anywhere, or when you close with the menu bar button or the
  shortcut.
- **Only a window that has stopped changing is judged.** macOS animates a window in when it
  opens, growing it from almost nothing, and a look during that saw a 43x44 window and
  called it a resize to 1%, which the viewer then came back at. Two looks have to agree
  before anything is read from the window.
- **Moves and resizes are judged against what mpv would have done**, so it does not matter
  when the button looks. The window has moved if it is no longer at its saved corner, or
  no longer centred if it has none. It has been resized if its size is not the feed's size
  at its scale, fitted to the screen. A feed's size counts only once its first frame is
  showing: mpv knows a feed's size before it has resized the window for it, and judging the
  old window against the new size called that a resize by hand.
- **mpv reapplies its start position on every feed switch**, which put a moved window back
  where it opened. The menu bar button clears the start position once the first frame is
  up, after which a feed switch keeps the window centred where you put it.
- **A saved position that no longer fits the screen**, after a resolution change for
  instance, is ignored and the window opens centred.
- **Positions are measured from the screen's usable area as an app sees it.** On a MacBook
  display with a notch, apps get a menu bar 2 points taller than a command-line process
  does, and mpv places windows by the app's figure.

### The parts

- `view.sh` runs mpv and restarts it: on a dropped camera, for the settings window, and for
  the reset shortcut. It writes the key bindings and the feed list mpv and the button read.
- `lib.sh` holds the feed and URL rules, and is what `./test.sh` covers along with the
  Swift logic in `tools/`.
- `tools/MenuBar.swift` is the menu bar button: it starts and stops the viewer, keeps each
  screen's placement, holds the keyboard shortcut, and drives mpv over the socket.
- `tools/MPV.swift` and `tools/MPVClient.swift` are that socket: the message and command
  formats, and the connection.
- `tools/Settings.swift` is the settings window, `tools/make-icon.py` draws the app icon.

### The app bundle

- The bundle contains a copy of the mpv program. Running mpv from inside the bundle is what
  makes the Dock show this app's name and icon; run from Homebrew's path it shows a plain
  "mpv".
- The launcher sets **`MPVBUNDLE=true`**. Without it mpv replaces the Dock and App Switcher
  icon with its own logo (`video/out/mac/common.swift` does this for any mpv it thinks is
  not in a bundle). Finder reads the icon from the bundle instead, which is why the two can
  disagree.
- `make-app.sh` stamps a new `CFBundleVersion` on every build and restarts the Dock, so a
  rebuilt icon shows at once.
- The settings window does not check URLs. `lib.sh` already does, and `view.sh` reopens the
  settings window when what was saved gives no usable feeds.

## Releasing

The download is built, signed and packaged by one script:

```sh
./tools/make-release.sh              # build, sign, notarize, package
./tools/make-release.sh --no-sign    # just the packaging, for a dry run
./tools/fetch-sources.sh             # the sources to publish beside it
```

It builds mpv (`tools/build-mpv.sh`), builds the app with its libraries inside
(`make-app.sh --standalone`, which calls `tools/bundle-libs.sh`), signs everything with
your Developer ID under the hardened runtime, notarizes it, and produces
`build/release/UniFi Viewer.dmg` holding the app and a shortcut to Applications.

It needs, once:

- a **Developer ID Application** certificate in your keychain. An Apple Development
  certificate is a different thing and macOS refuses it on a download. Xcode → Settings →
  Accounts → Manage Certificates → + → Developer ID Application.
- notarization credentials saved under a profile name:
  `xcrun notarytool store-credentials unifi-viewer --apple-id <id> --team-id <team>
  --password <app-specific password>`

**Publish the DMG and the sources on the same GitHub release.** mpv is GPL-2.0-or-later
and Homebrew's FFmpeg is built with GPL components, so shipping them means the matching
source has to be available to whoever gets the app. `fetch-sources.sh` collects it from
Homebrew's cache, for the exact versions in the build. The app itself carries the licence
texts and a list of what is inside, in `Contents/Resources/Licenses`.

## Tests

```sh
./test.sh            # 203 unit tests for the feed, URL, menu bar, shortcut and placement logic; no network needed
./test-contract.sh   # pulls a frame from every configured feed
```

`test-contract.sh` needs the cameras reachable. It skips cleanly when the console does not
answer, so being off the network never fails the build. Run it before opening a pull
request.

Protect is sometimes slow to set up a stream: most connect in about 10 seconds, but
occasionally one takes over 35, and which feed varies. The test retries each feed once,
with a pause between. Without the retry it failed about one run in three.

The app was developed against mpv 0.41. The menu and key behaviour it relies on differs in
earlier versions.

## Licence

MIT. See [LICENSE](LICENSE).
