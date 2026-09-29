#!/bin/bash
# Build the mpv this app ships: only what the viewer uses.
#
#   ./tools/build-mpv.sh            # build into build/mpv-<version>/
#   ./tools/build-mpv.sh --clean    # start from scratch
#
# make-app.sh picks the result up automatically; without it the app falls back
# to the mpv Homebrew installed.
#
# Why build our own:
#   - No scripting engine. mpv's Lua is LuaJIT, which compiles code as it runs.
#     Apple's hardened runtime, which a notarized app must use, blocks that, and
#     LuaJIT does not use the API Apple's exception expects. The app needs no
#     scripting at all: the menu bar button drives mpv over its IPC socket.
#   - Less to ship and to keep patched. Homebrew's mpv pulls 73 packages; this
#     links 10 libraries. Every one shipped is one to rebuild when it has a
#     security fix.
#   - No Now Playing. mpv reports itself to macOS as a playing media app, even
#     with --no-audio and --input-media-keys=no, and macOS then pulls AirPods
#     over from an iPhone that is playing something. See macos-media-player
#     below.
#
# Vulkan stays. Measured on this app's 7680x2160 feed: with Vulkan, mpv renders
# through gpu-next at about 14% of a core, the same as Homebrew's build; without
# it mpv falls back to its OpenGL path at about 47%.
set -eu

cd "$(dirname "$0")/.."
REPO=$(pwd -P)

MPV_VERSION=0.41.0
MPV_SHA256=ee21092a5ee427353392360929dc64645c54479aefdb5babc5cfbb5fad626209
BUILD="$REPO/build"
SOURCE="$BUILD/mpv-$MPV_VERSION"

if [ "${1:-}" = --clean ]; then
    rm -rf "$BUILD"
fi

# --- what this needs ------------------------------------------------------
# meson and ninja build mpv; the rest are what the trimmed build links.
missing=""
for tool in meson ninja pkg-config; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
for lib in ffmpeg libass libplacebo vulkan-loader molten-vk; do
    brew list --versions "$lib" >/dev/null 2>&1 || missing="$missing $lib"
done
if [ -n "$missing" ]; then
    echo "build-mpv.sh: missing:$missing" >&2
    echo "  run: brew install$missing" >&2
    exit 1
fi

mkdir -p "$BUILD"

# --- source ---------------------------------------------------------------
if [ ! -d "$SOURCE" ]; then
    echo "downloading mpv $MPV_VERSION..."
    curl -fsSL "https://github.com/mpv-player/mpv/archive/refs/tags/v$MPV_VERSION.tar.gz" \
        -o "$BUILD/mpv.tar.gz"
    echo "$MPV_SHA256  $BUILD/mpv.tar.gz" | shasum -a 256 -c --status || {
        echo "build-mpv.sh: the download does not match the expected checksum" >&2
        echo "  expected $MPV_SHA256" >&2
        echo "  got      $(shasum -a 256 "$BUILD/mpv.tar.gz" | cut -d' ' -f1)" >&2
        exit 1
    }
    tar xzf "$BUILD/mpv.tar.gz" -C "$BUILD"
    rm -f "$BUILD/mpv.tar.gz"
fi

# --- trim the menus -------------------------------------------------------
# mpv's macOS menu bar is built into it and cannot be changed at runtime, so it
# is changed here, in the copy this app ships. See tools/mpv-menus.py.
python3 "$REPO/tools/mpv-menus.py" "$SOURCE"

# --- configure ------------------------------------------------------------
# Everything this app does not use is off. mpv's own hard dependencies are
# FFmpeg, libass and libplacebo, so those are not choices.
#
# macos-media-player is mpv's Now Playing support. With it built in, mpv tells
# macOS "mpv is playing" as soon as a feed opens, whatever the options say:
# --input-media-keys=no only stops it taking the media keys, and the Now
# Playing updates carry on. macOS treats a playing app as wanting the shared
# Bluetooth audio route, so AirPods in use on an iPhone switch to the Mac. The
# system log shows the chain: mediaremoted "isPlaying changed to true", then
# audiomxd "request for ownership on shared route ... mpv", then
# audioaccessoryd "Routing request ... Hijack ... app mpv".
#
# An existing build folder is reconfigured, so a changed option here takes
# effect without --clean.
if [ -d "$SOURCE/build" ]; then
    reconfigure=--reconfigure
else
    reconfigure=""
fi
echo "configuring..."
( cd "$SOURCE" && meson setup $reconfigure build \
    -Dlua=disabled \
    -Djavascript=disabled \
    -Dlibarchive=disabled \
    -Dlibbluray=disabled \
    -Duchardet=disabled \
    -Drubberband=disabled \
    -Dvapoursynth=disabled \
    -Dzimg=disabled \
    -Djpeg=disabled \
    -Dlcms2=disabled \
    -Dmacos-media-player=disabled \
    -Dvulkan=enabled \
    -Dlibmpv=false \
    -Dmanpage-build=disabled \
    -Dhtml-build=disabled \
    -Dtests=false >/dev/null )

echo "building mpv..."
ninja -C "$SOURCE/build" >/dev/null

MPV="$SOURCE/build/mpv"
[ -x "$MPV" ] || { echo "build-mpv.sh: no mpv came out of the build" >&2; exit 1; }

# The option above is what keeps AirPods where they are. A later mpv that
# renames it would quietly bring Now Playing back, so check the result.
if "$MPV" -v --version 2>&1 | grep 'List of enabled features' | grep -q ' macos-media-player'; then
    echo "build-mpv.sh: this mpv still has Now Playing (macos-media-player)" >&2
    echo "  it would pull AirPods over from an iPhone; see the configure step" >&2
    exit 1
fi

echo "built $MPV"
echo "  $("$MPV" --version | head -1)"
echo "  links: $(otool -L "$MPV" | grep -v '/System/\|/usr/lib/' | awk 'NR > 1 {print $1}' \
    | sed 's|.*/||' | tr '\n' ' ')"
