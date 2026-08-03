#!/bin/bash
# Contract test: pull a frame from every configured feed and check the streams
# still look like what we expect. This catches upstream changes the unit tests
# cannot see — a camera renamed or removed in Protect, RTSP switched off for a
# quality, a stream going audio-only.
#
# Asserts shape, not picture content: that video arrives and the dimensions are
# sane. Feeds are arbitrary cameras now, so there is no ordering to assert.
#
# Skips cleanly when the cameras are unreachable, so no network never means a
# red build. Run this before opening a PR.
set -u

cd "$(dirname "$0")" || exit 1
# shellcheck source=lib.sh
. ./lib.sh

CONF="${STREAMS_CONF:-./streams.conf}"

if ! command -v mpv >/dev/null 2>&1; then
    echo "SKIP: mpv not installed (brew install mpv)"
    exit 0
fi

if [ ! -f "$CONF" ]; then
    echo "SKIP: no streams.conf (copy streams.conf.example)"
    exit 0
fi

FEEDS=$(feeds_load "$CONF") || exit 1

# Guard: if the first feed's host does not answer, skip rather than fail. The
# host comes from the parser rather than string-stripping, which would differ
# between the rtsp and rtsps schemes and silently skip every run.
first_url=$(printf '%s\n' "$FEEDS" | head -1 | cut -f3)
_parse_rtsp "$first_url" || exit 1
host="$_host"
if ! ping -c 1 -W 1000 "$host" >/dev/null 2>&1; then
    echo "SKIP: $host unreachable — not on the camera network"
    exit 0
fi

# probe <url> — echo "WxH", or a reason and non-zero on failure.
probe() {
    _url="$1"
    _out=$(mktemp)
    _dims=""

    mpv --no-config --no-audio --vo=null --ao=null --frames=1 \
        --rtsp-transport=tcp \
        --term-playing-msg='DIMS=${width}x${height}' \
        "$_url" >"$_out" 2>&1 &
    _pid=$!

    # mpv can hang on a stalled RTSP handshake, so cap it ourselves rather than
    # relying on --network-timeout, which is ignored for protocols that lack it.
    # The cap is generous: the handshake plus initial buffering measures around
    # 9-10s against these cameras, so a tight limit gives false failures.
    _waited=0
    while kill -0 "$_pid" 2>/dev/null && [ "$_waited" -lt 35 ]; do
        sleep 1
        _waited=$((_waited + 1))
    done

    if kill -0 "$_pid" 2>/dev/null; then
        kill -9 "$_pid" 2>/dev/null
        wait "$_pid" 2>/dev/null
        rm -f "$_out"
        echo "timed out after 35s"
        return 1
    fi

    wait "$_pid" 2>/dev/null
    _dims=$(sed -n 's/^DIMS=//p' "$_out" | head -n 1)
    rm -f "$_out"

    case "$_dims" in
        [1-9]*x[1-9]*) echo "$_dims" ;;
        "") echo "no video frame decoded"; return 1 ;;
        *)  echo "unexpected dimensions: $_dims"; return 1 ;;
    esac
}

# probe_feed <name> <url>
#
# Protect is intermittently slow to set up an RTSP session — most connect in
# about 10s, but one in several takes over 35s, and which feed is affected
# varies run to run. A single slow handshake is not a contract failure, so allow
# one retry with a pause for the previous session to be torn down. Without this
# the test failed roughly one run in three, making it noise rather than signal.
probe_feed() {
    _name="$1"
    _url="$2"

    _r=$(probe "$_url") && { echo "$_r"; return 0; }

    echo "  $_name: $_r, retrying once..." >&2
    sleep 5
    _r=$(probe "$_url") && { echo "$_r"; return 0; }

    echo "$_r"
    return 1
}

fail=0
count=0

while IFS="$(printf '\t')" read -r idx name url; do
    [ -n "$idx" ] || continue
    count=$((count + 1))
    [ "$count" -gt 1 ] && sleep 3
    if dims=$(probe_feed "$name" "$url"); then
        printf '%-24s %s\n' "$name" "$dims"
    else
        printf '%-24s FAIL: %s\n' "$name" "$dims"
        fail=1
    fi
done <<EOF
$FEEDS
EOF

if [ "$fail" -ne 0 ]; then
    echo
    echo "Check the feed is still shared in Protect (camera -> Settings -> Share Livestream)."
    echo "If the rtsps endpoint itself has changed, try: RTSP_MODE=plain ./test-contract.sh"
    exit 1
fi

echo "OK: all $count feeds return video"
