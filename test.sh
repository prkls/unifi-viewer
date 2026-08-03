#!/bin/bash
# Unit tests for lib.sh. Plain shell assertions, no framework, no dependencies.
set -u

cd "$(dirname "$0")" || exit 1
# shellcheck source=lib.sh
. ./lib.sh

pass=0
fail=0

assert_eq() {
    # assert_eq <description> <expected> <actual>
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
    fi
}

assert_fails() {
    # assert_fails <description> <command...> — command must exit non-zero
    desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        fail=$((fail + 1))
        printf 'FAIL: %s\n  expected non-zero exit, got success\n' "$desc"
    else
        pass=$((pass + 1))
    fi
}

fixture() {
    # fixture <content> — write to a temp file, echo its path
    _f=$(mktemp)
    printf '%s' "$1" >"$_f"
    TMPFILES="$TMPFILES $_f"
    printf '%s' "$_f"
}

TMPFILES=""
# shellcheck disable=SC2064
trap 'rm -f $TMPFILES' EXIT

# --- normalize_rtsp: the default path, URL used as Protect gave it ----------

assert_eq "keeps rtsps, port and query" \
    "rtsps://192.168.0.1:7441/aBcDeFgHiJ?enableSrtp" \
    "$(normalize_rtsp 'rtsps://192.168.0.1:7441/aBcDeFgHiJ?enableSrtp')"

assert_eq "keeps a URL with no query" \
    "rtsps://192.168.0.1:7441/aBcDeFgHiJ" \
    "$(normalize_rtsp 'rtsps://192.168.0.1:7441/aBcDeFgHiJ')"

assert_eq "strips trailing slash, keeps query" \
    "rtsps://192.168.0.1:7441/aBcDeFgHiJ?enableSrtp" \
    "$(normalize_rtsp 'rtsps://192.168.0.1:7441/aBcDeFgHiJ/?enableSrtp')"

assert_eq "keeps a portless URL portless" \
    "rtsps://192.168.0.1/aBcDeFgHiJ" \
    "$(normalize_rtsp 'rtsps://192.168.0.1/aBcDeFgHiJ')"

assert_eq "leaves plain rtsp alone" \
    "rtsp://192.168.0.1:7447/aBcDeFgHiJ" \
    "$(normalize_rtsp 'rtsp://192.168.0.1:7447/aBcDeFgHiJ')"

assert_eq "hostname rather than IP" \
    "rtsps://udm.local:7441/xYz123?enableSrtp" \
    "$(normalize_rtsp 'rtsps://udm.local:7441/xYz123?enableSrtp')"

# --- to_plain_rtsp: the RTSP_MODE=plain fallback ---------------------------

assert_eq "rewrites to plain 7447" \
    "rtsp://192.168.0.1:7447/aBcDeFgHiJ" \
    "$(to_plain_rtsp 'rtsps://192.168.0.1:7441/aBcDeFgHiJ?enableSrtp')"

assert_eq "rewrites without a query present" \
    "rtsp://192.168.0.1:7447/aBcDeFgHiJ" \
    "$(to_plain_rtsp 'rtsps://192.168.0.1:7441/aBcDeFgHiJ')"

assert_eq "already plain stays put" \
    "rtsp://192.168.0.1:7447/aBcDeFgHiJ" \
    "$(to_plain_rtsp 'rtsp://192.168.0.1:7447/aBcDeFgHiJ')"

assert_eq "rewrites a non-default host" \
    "rtsp://10.0.5.20:7447/xYz123" \
    "$(to_plain_rtsp 'rtsps://10.0.5.20:7441/xYz123?enableSrtp')"

# --- rejections, both functions --------------------------------------------

for fn in normalize_rtsp to_plain_rtsp; do
    assert_fails "$fn: empty URL"       "$fn" ''
    assert_fails "$fn: https scheme"    "$fn" 'https://192.168.0.1:7441/aBcDeFgHiJ'
    assert_fails "$fn: bare hostname"   "$fn" '192.168.0.1:7441/aBcDeFgHiJ'
    assert_fails "$fn: no stream id"    "$fn" 'rtsps://192.168.0.1:7441'
    assert_fails "$fn: empty stream id" "$fn" 'rtsps://192.168.0.1:7441/'
done

# --- feed_key --------------------------------------------------------------

assert_eq "first feed is key 1"  "1" "$(feed_key 1)"
assert_eq "ninth feed is key 9"  "9" "$(feed_key 9)"
assert_eq "tenth feed is key 0"  "0" "$(feed_key 10)"
assert_fails "feed_key rejects 0"  feed_key 0
assert_fails "feed_key rejects 11" feed_key 11

# --- feeds_load ------------------------------------------------------------

conf=$(fixture '# comment line

Front Door = rtsps://192.168.0.1:7441/aaa?enableSrtp
Driveway   = rtsps://192.168.0.1:7441/bbb?enableSrtp
')

assert_eq "two feeds, indexed and named in file order" \
"1	Front Door	rtsps://192.168.0.1:7441/aaa?enableSrtp
2	Driveway	rtsps://192.168.0.1:7441/bbb?enableSrtp" \
    "$(feeds_load "$conf" 2>/dev/null)"

RTSP_MODE=plain
assert_eq "plain mode rewrites every feed" \
"1	Front Door	rtsp://192.168.0.1:7447/aaa
2	Driveway	rtsp://192.168.0.1:7447/bbb" \
    "$(feeds_load "$conf" 2>/dev/null)"
RTSP_MODE=auto

# Names may contain spaces and punctuation; only the first = separates.
spaced=$(fixture 'Back Garden (west) = rtsps://192.168.0.1:7441/ccc?enableSrtp
')
assert_eq "name keeps spaces and brackets" \
    "1	Back Garden (west)	rtsps://192.168.0.1:7441/ccc?enableSrtp" \
    "$(feeds_load "$spaced" 2>/dev/null)"

# A bad entry is skipped rather than failing the whole file.
mixed=$(fixture 'Good = rtsps://192.168.0.1:7441/aaa?enableSrtp
Broken = http://example.com/nope
Also Good = rtsps://192.168.0.1:7441/bbb?enableSrtp
')
assert_eq "bad feed skipped, others renumbered" \
"1	Good	rtsps://192.168.0.1:7441/aaa?enableSrtp
2	Also Good	rtsps://192.168.0.1:7441/bbb?enableSrtp" \
    "$(feeds_load "$mixed" 2>/dev/null)"

# Old three-tier configs keep working: the keys simply become the names.
legacy=$(fixture 'high = rtsps://192.168.0.1:7441/aaa?enableSrtp
med  = rtsps://192.168.0.1:7441/bbb?enableSrtp
low  = rtsps://192.168.0.1:7441/ccc?enableSrtp
')
assert_eq "legacy tier config still loads" \
"1	high	rtsps://192.168.0.1:7441/aaa?enableSrtp
2	med	rtsps://192.168.0.1:7441/bbb?enableSrtp
3	low	rtsps://192.168.0.1:7441/ccc?enableSrtp" \
    "$(feeds_load "$legacy" 2>/dev/null)"

# Eleven feeds: the eleventh is dropped, not silently mixed in.
many=""
for i in 1 2 3 4 5 6 7 8 9 10 11; do
    many="${many}Cam $i = rtsps://192.168.0.1:7441/id$i?enableSrtp
"
done
manyconf=$(fixture "$many")
assert_eq "caps at ten feeds" "10" "$(feeds_load "$manyconf" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "tenth feed is the tenth line" \
    "10	Cam 10	rtsps://192.168.0.1:7441/id10?enableSrtp" \
    "$(feeds_load "$manyconf" 2>/dev/null | tail -1)"

# A file with no trailing newline still yields its last feed.
nonl=$(fixture 'Only = rtsps://192.168.0.1:7441/aaa?enableSrtp')
assert_eq "last line without trailing newline is read" \
    "1	Only	rtsps://192.168.0.1:7441/aaa?enableSrtp" \
    "$(feeds_load "$nonl" 2>/dev/null)"

assert_fails "missing config rejected"  feeds_load /nonexistent/streams.conf
assert_fails "empty config rejected"    feeds_load "$(fixture '')"
assert_fails "comments only rejected"   feeds_load "$(fixture '# nothing here
')"
assert_fails "all feeds invalid rejected" feeds_load "$(fixture 'Bad = not-a-url
')"

RTSP_MODE=sideways
assert_fails "unknown RTSP_MODE rejected" feeds_load "$conf"
RTSP_MODE=auto

# --- summary ---------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
