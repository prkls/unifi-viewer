#!/bin/bash
# Open a borderless mpv window on your UniFi Protect cameras.
#
#   ./view.sh [n]        # start on feed n (1-10), default the one last watched
#
# Keys 1-9 and 0 select feeds in config order. Right-click for the menu, q to
# quit. Reconnects on its own if a stream drops.
set -u

cd "$(dirname "$0")" || exit 1
# shellcheck source=lib.sh
. ./lib.sh

CONF="${STREAMS_CONF:-./streams.conf}"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/unifi-viewer"
STATE="$CACHE/feed"
GEN_CONF="$CACHE/input.conf"
FEEDS="$CACHE/feeds"
MENU_LUA="./tools/menu.lua"

# make-app.sh points these at copies inside the app bundle. Running mpv from in
# there makes macOS resolve the bundle's Info.plist, so the Dock tile gets this
# app's name and icon rather than a bare mpv one. SETTINGS_BIN only exists in the
# bundle; from a terminal there is no window to show, so we print instead.
MPV_BIN="${MPV_BIN:-mpv}"
SETTINGS_BIN="${SETTINGS_BIN:-}"

# Where the window opens: which display, at what scale, and where on it. The
# menu bar button writes this file before opening the viewer and again whenever
# the window is moved or resized; it is read each time mpv starts, so a restart
# after the settings window comes back where the window last was. No file, as
# from a terminal, means mpv's defaults: the display the pointer is on, each
# feed at its own size, centred.
PLACEMENT="$CACHE/placement"
# menu.lua reports each feed's size, feed switches and resets here, for the
# menu bar button.
WINDOW_EVENTS="$CACHE/window"

# Right-click menu text size, in points. Override per-run if it does not suit
# your display: MENU_FONT_SIZE=22 ./view.sh
MENU_FONT_SIZE="${MENU_FONT_SIZE:-18}"

if ! command -v "$MPV_BIN" >/dev/null 2>&1; then
    echo "view.sh: mpv not found — run: brew install mpv" >&2
    exit 1
fi

if [ ! -f "$MENU_LUA" ]; then
    echo "view.sh: $MENU_LUA is missing — the repo is incomplete" >&2
    exit 1
fi

mkdir -p "$CACHE" || exit 1

FEED_LINES=""

# Load feeds into memory as "<index>\t<key>\t<name>\t<url>" lines.
load_feeds() {
    FEED_LINES=$(feeds_load "$CONF" | while IFS="$(printf '\t')" read -r idx name url; do
        printf '%s\t%s\t%s\t%s\n' "$idx" "$(feed_key "$idx")" "$name" "$url"
    done)
    [ -n "$FEED_LINES" ]
}

feed_field() {
    # feed_field <index> <field-number>
    printf '%s\n' "$FEED_LINES" | awk -F'\t' -v i="$1" -v f="$2" '$1 == i { print $f }'
}

first_index() {
    printf '%s\n' "$FEED_LINES" | awk -F'\t' 'NR == 1 { print $1 }'
}

feed_count() {
    printf '%s\n' "$FEED_LINES" | awk 'END { print NR }'
}

has_feed() {
    [ -n "$(feed_field "$1" 1)" ]
}

# Opens the settings window when running as the app. Exit codes: 0 saved,
# 1 cancelled, 127 no window available.
run_settings() {
    if [ -n "$SETTINGS_BIN" ] && [ -x "$SETTINGS_BIN" ]; then
        "$SETTINGS_BIN" "$CONF"
        return $?
    fi
    return 127
}

no_feeds_message() {
    echo "view.sh: no usable feeds in $CONF" >&2
    echo "  cp streams.conf.example streams.conf, then add lines of the form" >&2
    echo "    Front Door = rtsps://192.168.0.1:7441/<id>?enableSrtp" >&2
    echo "  In Protect: click the camera -> Settings -> Share Livestream ->" >&2
    echo "  enable Secure RTSPS Output, then copy the link under each resolution." >&2
}

# Write what mpv reads: keybindings, and the feed list for menu.lua. Both are
# regenerated whenever the config changes, so the keys and the menu always agree
# with what is configured.
write_generated() {
    printf '%s\n' "$FEED_LINES" >"$FEEDS"

    : >"$GEN_CONF"
    printf '%s\n' "$FEED_LINES" | while IFS="$(printf '\t')" read -r idx key _ _; do
        [ -n "$idx" ] && printf '%s script-message unifi-select %s\n' "$key" "$idx" >>"$GEN_CONF"
    done
    # mpv 0.41 binds MBTN_RIGHT to `cycle pause` and has nothing bound to the
    # context menu — right-click paused the video instead of opening anything.
    # Binding it to the builtin context_menu script, whose `open` handler reads
    # the menu-data property menu.lua fills in. Pausing a live camera is not
    # useful, so taking the button over costs nothing.
    echo 'MBTN_RIGHT script-message-to context_menu open' >>"$GEN_CONF"
    # Plain comma, not Cmd+comma: the macOS menu bar is mpv's own and its
    # "Settings…" item already owns Cmd+, as a menu key equivalent, which AppKit
    # consumes before mpv's core ever sees it. That item opens mpv.conf and
    # cannot be repointed — it is hardcoded in the mpv binary.
    echo ', quit 20' >>"$GEN_CONF"
    echo 'r script-message unifi-reload' >>"$GEN_CONF"
    # Control-Option-Command-R: mpv calls Command "Meta".
    echo 'Ctrl+Alt+Meta+r script-message unifi-reset-window' >>"$GEN_CONF"
    echo 'q quit 5' >>"$GEN_CONF"
    # Nothing else is bound. mpv's builtin bindings are switched off entirely
    # (see --input-builtin-bindings below), so a key with no entry here does
    # nothing at all rather than falling through to a default.
}

# --- first run ------------------------------------------------------------

if ! load_feeds; then
    run_settings
    case $? in
        0) load_feeds || { no_feeds_message; exit 1; } ;;
        *) no_feeds_message; exit 1 ;;
    esac
fi

start_index="${1:-}"
if [ -n "$start_index" ]; then
    case "$start_index" in
        [1-9]|10) ;;
        *) echo "view.sh: usage: $0 [1-10]" >&2; exit 1 ;;
    esac
    has_feed "$start_index" || { echo "view.sh: no feed $start_index in $CONF" >&2; exit 1; }
else
    # Reopening from the menu bar should come back to what was on screen, not
    # to the first feed every time.
    start_index=$(resume_index "$(cat "$STATE" 2>/dev/null)" "$(feed_count)")
fi

echo "$start_index" >"$STATE"
write_generated

# Launched from the Dock there is no terminal, so mpv's per-frame status line
# just fills a log file. Silence it there, keep it when run interactively.
if [ -t 1 ]; then
    term_status=""
else
    term_status="--term-status-msg="
fi

backoff=2

while true; do
    index=$(cat "$STATE" 2>/dev/null) || index="$start_index"
    has_feed "$index" || index="$start_index"
    url=$(feed_field "$index" 4)

    screen=$(placement_field "$PLACEMENT" screen)
    scale=$(placement_field "$PLACEMENT" scale)
    geometry=$(placement_field "$PLACEMENT" geometry)

    started=$(date +%s)

    # Window sizing: --window-scale opens each stream at that fraction of its
    # own pixel size — 1 unless you have resized the window on this screen,
    # and mpv resizes on every switch (--auto-window-resize, on by default).
    # --autofit-larger only caps, unlike --autofit, which forces one size on
    # every feed — that is what previously pinned everything to 1600x450 and
    # upscaled smaller streams. The cap is a percentage of whichever screen the
    # window is on, so an oversized stream fits the display.
    #
    # Only the bindings generated above are live. mpv's defaults would otherwise
    # leave number keys with no feed adjusting picture settings — 5/6 gamma,
    # 7/8 saturation, 9/0 volume — which persist and quietly degrade the image
    # with no obvious cause. --input-builtin-bindings=no drops the builtin set,
    # --input-default-bindings=no drops the weak bindings builtin scripts add,
    # and --input-media-keys=no stops the keyboard's play/pause key reaching the
    # core. The context menu is unaffected: it uses forced bindings, which
    # override input.conf and are exempt from both.
    #
    # context_menu scales with the window by default, so the menu would be a
    # different size on a 7680px feed than on a 1280px one and would resize on
    # every switch. scale_with_window=no scales by display DPI instead, so it
    # stays one physical size whatever the stream resolution.
    #
    # --screen-name only chooses where the window first opens. mpv accepts a
    # change to it at runtime but does not move the window (tested on 0.41), so
    # the menu bar button moves the viewer by restarting it on the other screen.
    #
    # --geometry is a position only, never a size: a size would force every
    # feed into one shape. Size comes from --window-scale instead, which keeps
    # each feed's own shape. With a position given, mpv keeps the window's
    # top-left corner in place on a feed switch; without one it re-centres.
    #
    # --msg-level=ffmpeg=fatal hides libavcodec's per-frame decoder chatter.
    # Joining a live HEVC stream part-way through a GOP means the first frames
    # reference a keyframe we never received, so the decoder logs "Could not
    # find ref with POC n" until the next keyframe — up to ~5s on these cameras.
    # Those frames are skipped, not rendered, so the picture is unaffected.
    # mpv's own connection errors come from other prefixes and still show.
    "$MPV_BIN" \
        --input-conf="$GEN_CONF" \
        --input-builtin-bindings=no \
        --input-default-bindings=no \
        --input-media-keys=no \
        --script="$MENU_LUA" \
        --script-opts="unifi-feeds_file=$FEEDS,unifi-state_file=$STATE,unifi-window_file=$WINDOW_EVENTS,unifi-placement_file=$PLACEMENT,context_menu-scale_with_window=no,context_menu-font_size=$MENU_FONT_SIZE" \
        --no-audio \
        --profile=low-latency \
        --rtsp-transport=tcp \
        --hwdec=videotoolbox,auto \
        --msg-level=ffmpeg=fatal \
        --loop-file=inf \
        --no-border \
        --osc=no \
        --window-scale="${scale:-1}" \
        --autofit-larger=100%x100% \
        --screen-name="$screen" \
        --geometry="$geometry" \
        --ontop \
        --keep-open=no \
        --title="UniFi Viewer" \
        $term_status \
        "$url"
    rc=$?

    # 21 is the reset shortcut: back to mpv's own size and position, on the
    # same screen. menu.lua has told the menu bar button, which forgets what
    # it saved for this screen; the file just has to agree before mpv restarts.
    if [ "$rc" -eq 21 ]; then
        placement_reset "$PLACEMENT"
        backoff=2
        continue
    fi

    # 20 is the menu's "Camera Settings..." item.
    if [ "$rc" -eq 20 ]; then
        if run_settings; then
            load_feeds || { no_feeds_message; exit 1; }
            has_feed "$start_index" || start_index=$(first_index)
            has_feed "$(cat "$STATE" 2>/dev/null)" || echo "$start_index" >"$STATE"
            write_generated
        fi
        backoff=2
        continue
    fi

    # Every deliberate quit ends the loop:
    #   5  our `q` binding and the menu's Quit item
    #   4  Ctrl+C, or a signal
    #   0  Cmd+Q, the Quit menu item, or Dock -> Quit. mpv's macOS menu sends a
    #      bare `quit` command straight to the core (menu_bar.swift), so no
    #      input.conf binding can intercept it and give it our exit code.
    #
    # Treating 0 as deliberate is only safe because of --loop-file=inf: a
    # dropped stream no longer ends the process, mpv reconnects in place. So the
    # only way out is a real quit, and a non-zero exit means it could not
    # connect at all. Without that flag a drop also exited 0 and was
    # indistinguishable from Cmd+Q.
    case "$rc" in
        0|4|5) break ;;
    esac

    # A session that ran for a while means the camera was fine until now, so
    # treat this as a fresh incident rather than an escalating outage.
    if [ $(($(date +%s) - started)) -ge 30 ]; then
        backoff=2
    fi

    printf 'cannot reach the camera (mpv exit %d), retrying in %ds...\n' "$rc" "$backoff" >&2
    sleep "$backoff"
    [ "$backoff" -lt 10 ] && backoff=$((backoff * 2))
    [ "$backoff" -gt 10 ] && backoff=10
done
