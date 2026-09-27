#!/bin/bash
# Build the download: a signed, notarized UniFi Viewer.dmg, with the sources
# that shipping mpv obliges us to publish.
#
#   ./tools/make-release.sh              # build, sign, notarize, package
#   ./tools/make-release.sh --no-notary  # sign but do not notarize
#   ./tools/make-release.sh --no-sign    # neither; for testing the packaging
#
# Needs, once:
#   - a "Developer ID Application" certificate in the keychain. An "Apple
#     Development" certificate is not the same thing and macOS will not accept
#     an app signed with it from a download. Xcode → Settings → Accounts →
#     Manage Certificates → + → Developer ID Application.
#   - notarytool credentials saved under a profile name:
#       xcrun notarytool store-credentials unifi-viewer \
#           --apple-id <your Apple ID> --team-id <your team> --password <app-specific password>
#
# Override the defaults with SIGN_IDENTITY and NOTARY_PROFILE.
set -eu

cd "$(dirname "$0")/.."
REPO=$(pwd -P)
APP_NAME="UniFi Viewer"
STAGE="$REPO/build/release"
APP="$STAGE/$APP_NAME.app"
# No space in the file name: it becomes part of the download URL.
DMG="$STAGE/UniFi-Viewer.dmg"
NOTARY_PROFILE=${NOTARY_PROFILE:-unifi-viewer}
NOTARIZE=yes
SIGN=yes
for arg in "$@"; do
    case "$arg" in
        --no-notary) NOTARIZE=no ;;
        --no-sign)   NOTARIZE=no; SIGN=no ;;
    esac
done

# --- the app --------------------------------------------------------------
rm -rf "$STAGE"
mkdir -p "$STAGE"
"$REPO/tools/build-mpv.sh"
"$REPO/make-app.sh" "$STAGE" --standalone

# --- licences -------------------------------------------------------------
# mpv and FFmpeg are GPL, so the app carries their terms and the release
# carries their source (below).
LICENSES="$APP/Contents/Resources/Licenses"
mkdir -p "$LICENSES"
MPV_SOURCE=$(ls -d "$REPO"/build/mpv-*/ 2>/dev/null | tail -1)
for file in LICENSE.GPL LICENSE.LGPL Copyright; do
    [ -f "$MPV_SOURCE$file" ] && cp "$MPV_SOURCE$file" "$LICENSES/mpv-$file"
done
cp "$REPO/LICENSE" "$LICENSES/unifi-viewer-LICENSE"

# What is inside, and where its source came from. Also the list the source
# bundle is built from.
{
    echo "UniFi Viewer bundles the programs below. Its own code is MIT; see"
    echo "unifi-viewer-LICENSE. mpv is GPL-2.0-or-later and FFmpeg as built here"
    echo "is GPL. Their source is published with this release."
    echo
    echo "mpv $(ls -d "$REPO"/build/mpv-*/ | sed 's|.*/mpv-||; s|/||')"
    echo "  https://github.com/mpv-player/mpv"
    echo "  built by tools/build-mpv.sh; see it for the exact options"
    echo
    echo "Libraries, built by Homebrew from these packages:"
    # bundle-libs.sh wrote where each one came from; a Homebrew path carries
    # the package name and version.
    while IFS="$(printf '\t')" read -r name source; do
        package=$(printf '%s' "$source" | sed -n 's|.*/Cellar/\([^/]*\)/\([^/]*\)/.*|\1 \2|p')
        echo "  $name ${package:+($package)}"
    done < "$APP/Contents/Resources/bundled-libraries.txt"
} > "$LICENSES/BUNDLED.txt"
echo "wrote $LICENSES/BUNDLED.txt"

# --- sign -----------------------------------------------------------------
# Everything inside is signed before the app itself, innermost first, with the
# hardened runtime macOS requires for notarization. No entitlements: the app
# needs none, and the one that would have been needed — permission to compile
# code at runtime, for mpv's LuaJIT — went away with the scripting engine.
IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')}
if [ "$SIGN" = no ]; then
    echo "not signing (--no-sign): this build is for testing the packaging only"
    IDENTITY=""
elif [ -z "$IDENTITY" ]; then
    echo "make-release.sh: no Developer ID Application certificate in the keychain." >&2
    echo "  Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application" >&2
    echo "  (an Apple Development certificate will not do: macOS refuses it on a download)" >&2
    exit 1
fi
if [ "$SIGN" = yes ]; then
    echo "signing as: $IDENTITY"
    sign() {
        codesign --force --timestamp --options runtime --sign "$IDENTITY" "$@"
    }
    find "$APP/Contents/Frameworks" -name '*.dylib' -print0 | xargs -0 -n1 sign
    for binary in mpv settings unifi-viewer launch-viewer; do
        [ -e "$APP/Contents/MacOS/$binary" ] && sign "$APP/Contents/MacOS/$binary"
    done
    sign "$APP"
    codesign --verify --deep --strict --verbose=2 "$APP"
    echo "signed"
fi

# --- notarize -------------------------------------------------------------
if [ "$NOTARIZE" = yes ]; then
    ZIP="$STAGE/app.zip"
    /usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
    echo "notarizing, which takes a few minutes..."
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
fi

# --- the disk image -------------------------------------------------------
# A window holding the app and a shortcut to Applications: the drag-to-install
# layout every Mac user knows.
ROOT="$STAGE/dmg"
rm -rf "$ROOT"
mkdir -p "$ROOT"
cp -R "$APP" "$ROOT/"
ln -s /Applications "$ROOT/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$ROOT" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$ROOT"

if [ "$NOTARIZE" = yes ]; then
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"

    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
fi

# The app now lives in the disk image. Leaving the staged copy on disk would
# mean two apps with one bundle id, which is how macOS ends up showing the
# wrong icon or opening the wrong copy.
rm -rf "$APP"

echo
echo "built $DMG ($(du -h "$DMG" | cut -f1))"
echo "Publish it on the GitHub release together with the sources:"
echo "  ./tools/fetch-sources.sh"
