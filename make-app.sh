#!/bin/bash
# Build "UniFi Viewer.app" — a Dock-launchable wrapper around view.sh.
#
#   ./make-app.sh              # build into this directory
#   ./make-app.sh ~/Applications
#   ./make-app.sh /Applications --standalone   # carry mpv's libraries too
#
# The bundle is generated, not committed, and self-contained: it carries the
# viewer's scripts, so it keeps working if this checkout moves or goes away.
set -eu

cd "$(dirname "$0")"
REPO=$(pwd -P)
APP_NAME="UniFi Viewer"
DEST="${1:-$REPO}"
# --standalone copies the libraries mpv needs into the bundle, for a copy that
# runs on a Mac without Homebrew. Slower, and only needed for a release.
STANDALONE=no
for arg in "$@"; do
    [ "$arg" = --standalone ] && STANDALONE=yes
done
case "$DEST" in --*) DEST="$REPO" ;; esac
APP="$DEST/$APP_NAME.app"

if [ ! -x "$REPO/view.sh" ]; then
    echo "make-app.sh: view.sh not found or not executable in $REPO" >&2
    exit 1
fi

mkdir -p "$DEST"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# --- bundled mpv ----------------------------------------------------------
# A copy of the mpv binary lives inside the bundle. When mpv runs from
# Contents/MacOS, macOS walks up to Contents/Info.plist and resolves it as this
# app, so the Dock tile carries this name and icon. Launched from the Homebrew
# path instead, the tile is a bare "mpv" with a generic icon — verified.
#
# tools/build-mpv.sh builds the mpv this app is meant to ship: no scripting
# engine, and only the libraries the viewer uses. Without it, the mpv Homebrew
# installed is used instead, which works but carries LuaJIT and 70-odd other
# packages.
#
# Either way only the executable is copied, and it keeps linking against the
# Homebrew libraries at their absolute paths, so those must stay installed.
# Re-run this script after a `brew upgrade` of them, or after build-mpv.sh.
MPV_SRC=$(ls "$REPO"/build/mpv-*/build/mpv 2>/dev/null | tail -1 || true)
if [ -n "$MPV_SRC" ]; then
    echo "using the mpv built by tools/build-mpv.sh"
else
    MPV_SRC=$(command -v mpv || true)
    if [ -z "$MPV_SRC" ]; then
        echo "make-app.sh: mpv not found — run: brew install mpv" >&2
        echo "             or build the trimmed one: ./tools/build-mpv.sh" >&2
        exit 1
    fi
    echo "using Homebrew's mpv (./tools/build-mpv.sh builds a smaller one)"
fi
cp "$(readlink -f "$MPV_SRC" 2>/dev/null || echo "$MPV_SRC")" "$APP/Contents/MacOS/mpv"

# --- settings window ------------------------------------------------------
# Compiled rather than shipped prebuilt, so there is no binary in the repo.
# Without it the app still runs; view.sh falls back to printing instructions,
# which is what happens from a terminal anyway.
if command -v swiftc >/dev/null 2>&1; then
    echo "compiling settings window..."
    swiftc -O -parse-as-library "$REPO/tools/Shortcut.swift" "$REPO/tools/Settings.swift" \
        -o "$APP/Contents/MacOS/settings" \
        || echo "make-app.sh: settings window failed to build, continuing without it" >&2
else
    echo "make-app.sh: swiftc not found (install Xcode command line tools)," >&2
    echo "             building without the settings window" >&2
fi

# --- the viewer's scripts -------------------------------------------------
# Copied in, so the app does not depend on this checkout staying where it is.
# Edit them here and rebuild, or run ./view.sh straight from the repo.
cp "$REPO/view.sh" "$REPO/lib.sh" "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/view.sh"

# --- settings, where the app keeps them -----------------------------------
# Not in the repo: a downloaded app has no repo, and settings should outlive
# any one copy of it. An existing streams.conf here is copied over once, so
# nothing is lost when upgrading from an older build.
SETTINGS_DIR="$HOME/Library/Application Support/$APP_NAME"
mkdir -p "$SETTINGS_DIR"
if [ ! -f "$SETTINGS_DIR/streams.conf" ] && [ -f "$REPO/streams.conf" ]; then
    cp "$REPO/streams.conf" "$SETTINGS_DIR/streams.conf"
    echo "copied your feeds to $SETTINGS_DIR/streams.conf"
fi

# --- launcher -------------------------------------------------------------
# launch-viewer starts one viewer session: view.sh with the bundle's mpv. The
# menu bar button below runs it each time the viewer opens; without that
# button it is the app's main program, as it always used to be.
#
#   launch-viewer              open the viewer (VIEW_SCREEN picks the display)
#   launch-viewer --settings   just the settings window, for the menu bar menu
#
# Finder gives a launched app no terminal, so view.sh's retry messages would go
# nowhere. Send them to a log instead.
# MPVBUNDLE is what stops mpv replacing our Dock and App Switcher icon with its
# own. From video/out/mac/common.swift:
#
#     func setAppIcon() {
#         if !AppHub.shared.isBundle {
#             NSApp.applicationIconImage = AppHub.shared.getIcon()
#         }
#     }
#
# and isBundle is just getenv("MPVBUNDLE") == "true". mpv's own bundle sets it
# in LSEnvironment; without it mpv assumes it is a bare binary that needs to
# supply its own icon, and overwrites ours at window creation. Only set here,
# not in view.sh: run from a terminal, mpv genuinely is unbundled.
#
# The log is truncated each time the viewer opens rather than appended, so it
# always describes the current session and cannot grow without bound.
cat >"$APP/Contents/MacOS/launch-viewer" <<EOF
#!/bin/bash
LOG="\${XDG_CACHE_HOME:-\$HOME/.cache}/unifi-viewer"
mkdir -p "\$LOG"
export MPVBUNDLE=true
DIR="\$(cd "\$(dirname "\$0")" && pwd)"
RESOURCES="\$(cd "\$DIR/../Resources" && pwd)"
export STREAMS_CONF="\${STREAMS_CONF:-\$HOME/Library/Application Support/$APP_NAME/streams.conf}"
mkdir -p "\$(dirname "\$STREAMS_CONF")"
if [ "\${1:-}" = --settings ]; then
    exec "\$DIR/settings" "\$STREAMS_CONF" >>"\$LOG/app.log" 2>&1
fi
export MPV_BIN="\$DIR/mpv"
[ -x "\$DIR/settings" ] && export SETTINGS_BIN="\$DIR/settings"
exec "\$RESOURCES/view.sh" >"\$LOG/app.log" 2>&1
EOF
chmod +x "$APP/Contents/MacOS/launch-viewer"

# --- menu bar button ------------------------------------------------------
# The app's main program when it compiles: it stays in the menu bar and runs
# launch-viewer whenever the viewer opens. Without swiftc, or if it fails to
# build, launch-viewer takes its place and the app behaves as it did before
# the button existed: open to start, quit to stop.
if command -v swiftc >/dev/null 2>&1 \
    && echo "compiling menu bar button..." \
    && swiftc -O -parse-as-library "$REPO/tools/MenuBarLogic.swift" "$REPO/tools/Shortcut.swift" \
        "$REPO/tools/Placement.swift" "$REPO/tools/MPV.swift" "$REPO/tools/MPVClient.swift" \
        "$REPO/tools/MenuBar.swift" \
        -o "$APP/Contents/MacOS/unifi-viewer"; then
    :
else
    echo "make-app.sh: building without the menu bar button" >&2
    cp "$APP/Contents/MacOS/launch-viewer" "$APP/Contents/MacOS/unifi-viewer"
fi

# --- Info.plist -----------------------------------------------------------
# Launch Services caches an app's icon against its bundle version, so a rebuild
# that keeps the same version can go on showing the previous icon — or a stale
# "no icon yet" state, which is what a generic placeholder in Finder means.
# A build timestamp guarantees every build looks new.
BUILD_VERSION=$(date +%Y%m%d%H%M%S)
# LSUIElement keeps the menu bar button (or the plain launcher) out of the
# Dock. mpv creates its own NSApplication and its own Dock tile, so without it
# you get two icons for one window. The tile you see and Cmd+Tab to is mpv's,
# carrying the icon below, and it is there only while the viewer is open.
cat >"$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>unifi-viewer</string>
    <key>CFBundleIdentifier</key><string>io.github.prkls.unifi-viewer</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>$BUILD_VERSION</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSMinimumSystemVersion</key><string>11.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

# --- icon -----------------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
    echo "rendering icon..."
    python3 "$REPO/tools/make-icon.py" "$APP/Contents/Resources/AppIcon.icns"
else
    echo "make-app.sh: python3 not found, building without an icon" >&2
fi

# --- libraries ------------------------------------------------------------
if [ "$STANDALONE" = yes ]; then
    "$REPO/tools/bundle-libs.sh" "$APP"
    # The Vulkan loader needs telling where the bundled driver manifest is.
    python3 - "$APP/Contents/MacOS/launch-viewer" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
line = 'export VK_ICD_FILENAMES="$RESOURCES/vulkan/icd.d/MoltenVK_icd.json"\n'
if line not in text:
    text = text.replace('export MPV_BIN=', line + 'export MPV_BIN=')
    open(path, "w").write(text)
PY
fi

# --- sign -----------------------------------------------------------------
# Ad-hoc signature. Nothing here is downloaded so Gatekeeper will not quarantine
# it, but an unsigned bundle still trips extra prompts on recent macOS.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 \
    && echo "signed (ad-hoc)" \
    || echo "make-app.sh: codesign failed, the app will still run" >&2

# Bump the bundle mtime after signing; the icon cache keys on it too.
touch "$APP"

# --- register -------------------------------------------------------------
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Unregister before registering. Without the -u, Launch Services keeps the old
# record and can go on serving a cached icon for this bundle id.
"$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
"$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true

echo "built $APP"

# Another copy sharing this bundle id is the usual cause of the Dock and the
# App Switcher disagreeing with Finder: Launch Services may resolve either one,
# and the Dock caches icons per bundle id rather than per path.
BUNDLE_ID=io.github.prkls.unifi-viewer
OTHERS=$(mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null \
         | grep -v "^${APP}\$" || true)
if [ -n "$OTHERS" ]; then
    echo
    echo "warning: another copy of $BUNDLE_ID is installed:"
    printf '%s\n' "$OTHERS" | sed 's/^/  /'
    echo "  Keep one. Build straight to where you want it, e.g."
    echo "    ./make-app.sh /Applications  &&  rm -rf '$REPO/$APP_NAME.app'"
fi

# The Dock owns the App Switcher and caches icons for the whole login session,
# so a rebuilt icon does not appear until it restarts. This is instant and
# loses nothing.
killall Dock >/dev/null 2>&1 || true
echo "restarted Dock so the new icon is picked up"
