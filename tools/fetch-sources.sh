#!/bin/bash
# Collect the source of everything the app ships, to publish beside the
# download.
#
#   ./tools/fetch-sources.sh        # into build/sources/
#
# mpv is GPL-2.0-or-later and Homebrew's FFmpeg is built with GPL components.
# Shipping them in the app means the matching source has to be available to
# whoever gets the app. Putting it on the same GitHub release as the DMG is the
# simplest way to do that.
#
# Homebrew keeps the source of everything it builds, so this asks it for the
# exact versions installed rather than guessing.
set -eu

cd "$(dirname "$0")/.."
REPO=$(pwd -P)
OUT="$REPO/build/sources"
APP_FRAMEWORKS=${1:-$REPO/build/release/UniFi Viewer.app/Contents/Frameworks}

mkdir -p "$OUT"

# mpv itself, as tools/build-mpv.sh fetched it.
MPV_VERSION=$(grep '^MPV_VERSION=' "$REPO/tools/build-mpv.sh" | cut -d= -f2)
if [ ! -f "$OUT/mpv-$MPV_VERSION.tar.gz" ]; then
    echo "fetching mpv $MPV_VERSION..."
    curl -fsSL "https://github.com/mpv-player/mpv/archive/refs/tags/v$MPV_VERSION.tar.gz" \
        -o "$OUT/mpv-$MPV_VERSION.tar.gz"
fi

# Every library in the app, traced back to the formula that built it.
# make-release.sh leaves this beside the disk image, since the app it came from
# is deleted once packaged. Without it this fetched mpv's whole dependency
# tree: 74 packages and 400 MB, most of which the app does not ship.
MANIFEST="$REPO/build/release/bundled-libraries.txt"
[ -f "$MANIFEST" ] || MANIFEST=$(dirname "$APP_FRAMEWORKS")/Resources/bundled-libraries.txt
formulas=""
if [ -f "$MANIFEST" ]; then
    formulas=$(sed -n 's|.*/Cellar/\([^/]*\)/.*|\1|p' "$MANIFEST" | sort -u | tr '\n' ' ')
else
    echo "fetch-sources.sh: no list of what was bundled; run tools/make-release.sh first" >&2
    exit 1
fi
formulas=$(printf '%s\n' $formulas | sort -u | tr '\n' ' ')

echo "fetching source for:$formulas"
for formula in $formulas; do
    brew fetch --build-from-source --force "$formula" >/dev/null 2>&1 || {
        echo "  could not fetch $formula" >&2
        continue
    }
    for file in $(brew --cache --build-from-source "$formula" 2>/dev/null); do
        # Homebrew's cache names carry a checksum prefix; drop it so the files
        # read as what they are.
        [ -f "$file" ] && cp "$file" "$OUT/$(basename "$file" | sed 's/^[0-9a-f]*--//')" 2>/dev/null || true
    done
done

# What is here, so anyone reading knows what they have.
{
    echo "Source for the programs UniFi Viewer ships, as of $(date +%Y-%m-%d)."
    echo
    echo "mpv $MPV_VERSION, built with the options in tools/build-mpv.sh."
    echo "One mpv file is modified: osdep/mac/menu_bar.swift, by the script"
    echo "tools/mpv-menus.py in https://github.com/prkls/unifi-viewer. Running"
    echo "it on the mpv source here reproduces the copy this app ships."
    echo "The libraries were built by Homebrew from the source here; their"
    echo "formulas, with the patches and flags used, are in Homebrew's"
    echo "homebrew-core repository at the versions named below."
    echo
    ls -1 "$OUT" | grep -v '^README' | sed 's/^/  /'
} > "$OUT/README.txt"

echo
echo "collected $(ls -1 "$OUT" | wc -l | tr -d ' ') files in $OUT"
du -sh "$OUT"
