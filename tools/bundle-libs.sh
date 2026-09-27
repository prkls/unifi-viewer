#!/bin/bash
# Copy the libraries mpv needs into the app, so it runs on a Mac with no
# Homebrew.
#
#   ./tools/bundle-libs.sh "/Applications/UniFi Viewer.app"
#
# make-app.sh --standalone calls this. Without it the app uses the libraries
# Homebrew installed, which is fine on your own machine and keeps a rebuild
# quick.
#
# Every library lands in Contents/Frameworks, and every reference to a Homebrew
# path is rewritten to @rpath, which mpv resolves through the run-path set on
# the binary. Nothing outside the bundle is referenced afterwards; the check at
# the end fails the build if anything still is.
set -eu

APP=${1:?usage: bundle-libs.sh <path to .app>}
MPV="$APP/Contents/MacOS/mpv"
FRAMEWORKS="$APP/Contents/Frameworks"
[ -x "$MPV" ] || { echo "bundle-libs.sh: no mpv in $APP" >&2; exit 1; }

mkdir -p "$FRAMEWORKS"

# --- collect --------------------------------------------------------------
# otool lists what one file needs; a library needs libraries of its own, so
# this walks until nothing new turns up. System libraries are already on every
# Mac and are left alone.
collect() {
    python3 - "$1" <<'PY'
import os, subprocess, sys

def deps(path):
    out = subprocess.run(["otool", "-L", path], capture_output=True, text=True).stdout
    return [line.strip().split(" ")[0] for line in out.splitlines()[1:]]

def rpaths(path):
    out = subprocess.run(["otool", "-l", path], capture_output=True, text=True).stdout
    found, lines = [], out.splitlines()
    for i, line in enumerate(lines):
        if "LC_RPATH" in line:
            for follow in lines[i:i + 4]:
                if "path " in follow:
                    found.append(follow.strip().split(" ")[1])
                    break
    return found

# A library may name another by a search path (@rpath/libfoo.dylib) rather than
# in full. Resolve those through the search paths of whatever referred to it,
# or they are missed and the app falls back to Homebrew's copy at runtime.
def resolve(lib, referrer):
    if lib.startswith("@rpath/"):
        name = lib[len("@rpath/"):]
        for base in rpaths(referrer) + ["/opt/homebrew/lib", "/usr/local/lib"]:
            if base.startswith("@"):
                continue
            candidate = os.path.join(base, name)
            if os.path.exists(candidate):
                return candidate
        return None
    if lib.startswith("@"):
        return None
    return lib

seen, queue = set(), [sys.argv[1]]
while queue:
    target = queue.pop()
    if not os.path.exists(target):
        continue
    for lib in deps(target):
        full = resolve(lib, target)
        if not full or full.startswith(("/System", "/usr/lib")) or full in seen:
            continue
        seen.add(full)
        queue.append(full)
for lib in sorted(seen):
    print(lib)
PY
}

LIBS=$(collect "$MPV")
[ -n "$LIBS" ] || { echo "bundle-libs.sh: mpv needs no libraries, nothing to do"; exit 0; }

# Where each library came from is written down as they are copied: the path
# carries the package and version, which the release needs for its notice and
# for fetching matching source.
MANIFEST="$APP/Contents/Resources/bundled-libraries.txt"
mkdir -p "$(dirname "$MANIFEST")"
: > "$MANIFEST"
count=0
for lib in $LIBS; do
    name=$(basename "$lib")
    real=$(readlink -f "$lib" 2>/dev/null || echo "$lib")
    # The same library turns up under more than one path (Homebrew keeps opt/
    # symlinks beside the Cellar); record and count it once.
    if [ ! -f "$FRAMEWORKS/$name" ]; then
        cp "$real" "$FRAMEWORKS/$name"
        printf '%s\t%s\n' "$name" "$real" >> "$MANIFEST"
        count=$((count + 1))
    fi
    chmod u+w "$FRAMEWORKS/$name"
done
echo "bundled $count libraries"

# --- rewrite --------------------------------------------------------------
for lib in $LIBS; do
    name=$(basename "$lib")
    install_name_tool -id "@rpath/$name" "$FRAMEWORKS/$name" 2>/dev/null || true
    for dep in $(collect "$FRAMEWORKS/$name"); do
        install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$FRAMEWORKS/$name" 2>/dev/null || true
    done
done

for dep in $LIBS; do
    install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$MPV" 2>/dev/null || true
done

# The build leaves search paths pointing into Homebrew, and they come first, so
# @rpath/libavcodec.dylib found Homebrew's copy and the bundled one was never
# used (seen with lsof). Strip them, leaving only the bundle.
for target in "$MPV" "$FRAMEWORKS"/*.dylib; do
    for path in $(otool -l "$target" | awk '/LC_RPATH/ {found=1} found && /path /{print $2; found=0}'); do
        case "$path" in
            # Homebrew's, and Xcode's Swift path: neither exists on the Mac
            # this app is going to. The Swift runtime it needs ships in macOS.
            /opt/*|/usr/local/*|/Applications/Xcode*) \
                install_name_tool -delete_rpath "$path" "$target" 2>/dev/null || true ;;
        esac
    done
done
install_name_tool -add_rpath "@executable_path/../Frameworks" "$MPV" 2>/dev/null || true
install_name_tool -add_rpath "@loader_path" "$MPV" 2>/dev/null || true

# --- Vulkan's driver ------------------------------------------------------
# mpv renders through the Vulkan loader, which finds a driver by reading a
# manifest that names it. On this Mac that driver is MoltenVK, which maps
# Vulkan onto Metal. Both the manifest and the driver have to travel with the
# app, and the launcher points the loader at the copy (VK_ICD_FILENAMES).
MOLTEN_PREFIX=$(brew --prefix molten-vk 2>/dev/null || true)
ICD_SRC=$(ls "${MOLTEN_PREFIX:-/nonexistent}"/etc/vulkan/icd.d/MoltenVK_icd.json \
             /opt/homebrew/etc/vulkan/icd.d/MoltenVK_icd.json \
             /usr/local/etc/vulkan/icd.d/MoltenVK_icd.json 2>/dev/null | head -1 || true)
if [ -n "$ICD_SRC" ]; then
    mkdir -p "$APP/Contents/Resources/vulkan/icd.d"
    MOLTEN=$(python3 -c 'import json,sys,os; print(os.path.basename(json.load(open(sys.argv[1]))["ICD"]["library_path"]))' "$ICD_SRC")
    MOLTEN_SRC=$(python3 -c 'import json,sys,os; p=json.load(open(sys.argv[1]))["ICD"]["library_path"]; print(p if p.startswith("/") else os.path.normpath(os.path.join(os.path.dirname(sys.argv[1]), p)))' "$ICD_SRC")
    cp "$(readlink -f "$MOLTEN_SRC" 2>/dev/null || echo "$MOLTEN_SRC")" "$FRAMEWORKS/$MOLTEN"
    chmod u+w "$FRAMEWORKS/$MOLTEN"
    install_name_tool -id "@rpath/$MOLTEN" "$FRAMEWORKS/$MOLTEN" 2>/dev/null || true
    printf '{\n  "file_format_version": "1.0.0",\n  "ICD": {\n    "library_path": "../../../Frameworks/%s",\n    "api_version": "1.2.0"\n  }\n}\n' \
        "$MOLTEN" > "$APP/Contents/Resources/vulkan/icd.d/MoltenVK_icd.json"
    echo "bundled the Vulkan driver ($MOLTEN)"
else
    echo "bundle-libs.sh: no MoltenVK manifest found; the app will need it installed" >&2
fi

# --- check ----------------------------------------------------------------
# Anything still pointing outside the bundle would work here and fail on
# someone else's Mac, which is exactly the bug this script exists to prevent.
outside=$(for f in "$MPV" "$FRAMEWORKS"/*.dylib; do
    otool -L "$f" | awk 'NR > 1 {print $1}' | grep -E '^/(opt|usr/local)/' || true
done | sort -u)
if [ -n "$outside" ]; then
    echo "bundle-libs.sh: these still point outside the app:" >&2
    printf '%s\n' "$outside" | sed 's/^/  /' >&2
    exit 1
fi
echo "nothing points outside the app"
