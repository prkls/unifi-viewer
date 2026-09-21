# URL and config logic for unifi-viewer.
#
# Sourced by view.sh and the test scripts. Defines functions only; running this
# file directly does nothing.

# Which endpoint to talk to.
#
#   auto  — use the URL exactly as Protect gave it: rtsps:// on 7441. Default.
#           Verified working with mpv 0.41 / FFmpeg 8.1.2, with or without the
#           ?enableSrtp suffix. This is the documented, encrypted endpoint.
#   plain — rewrite to plain RTSP on 7447. Fallback only, for older players
#           that cannot do RTSP-over-TLS. Undocumented and unencrypted.
#
# Override per-run: RTSP_MODE=plain ./view.sh
RTSP_MODE="${RTSP_MODE:-auto}"
RTSP_PLAIN_PORT=7447

# Hotkeys are 1..9 then 0, so ten feeds is the ceiling.
MAX_FEEDS=10

# _parse_rtsp <url>
#
# Validate an RTSP(S) URL and split it into _scheme, _host, _port, _id, _query.
# Internal; sets globals rather than returning, since this is POSIX shell.
_parse_rtsp() {
    _url="$1"

    if [ -z "$_url" ]; then
        echo "invalid RTSP URL: empty" >&2
        return 1
    fi

    _query=""
    case "$_url" in
        *\?*) _query="?${_url#*\?}"; _url="${_url%%\?*}" ;;
    esac
    _url="${_url%/}"

    case "$_url" in
        rtsps://*) _scheme="rtsps"; _rest="${_url#rtsps://}" ;;
        rtsp://*)  _scheme="rtsp";  _rest="${_url#rtsp://}" ;;
        *)
            echo "invalid RTSP URL: not rtsp:// or rtsps://: $1" >&2
            return 1
            ;;
    esac

    _hostport="${_rest%%/*}"
    _id="${_rest#*/}"

    # No slash at all means there is no stream id to play.
    if [ "$_hostport" = "$_rest" ] || [ -z "$_id" ]; then
        echo "invalid RTSP URL: no stream id: $1" >&2
        return 1
    fi

    _host="${_hostport%%:*}"
    if [ -z "$_host" ]; then
        echo "invalid RTSP URL: no host: $1" >&2
        return 1
    fi

    case "$_hostport" in
        *:*) _port="${_hostport#*:}" ;;
        *)   _port="" ;;
    esac
}

# normalize_rtsp <url>
#
# Return the URL as Protect gave it, tidied: trailing slash removed, scheme,
# port and query preserved. This is the default path.
normalize_rtsp() {
    _parse_rtsp "$1" || return 1

    if [ -n "$_port" ]; then
        printf '%s://%s:%s/%s%s\n' "$_scheme" "$_host" "$_port" "$_id" "$_query"
    else
        printf '%s://%s/%s%s\n' "$_scheme" "$_host" "$_id" "$_query"
    fi
}

# to_plain_rtsp <url>
#
# Rewrite to the undocumented plain-RTSP endpoint:
#   rtsps://host:7441/<id>?enableSrtp  ->  rtsp://host:7447/<id>
# Only used when RTSP_MODE=plain.
to_plain_rtsp() {
    _parse_rtsp "$1" || return 1
    printf 'rtsp://%s:%s/%s\n' "$_host" "$RTSP_PLAIN_PORT" "$_id"
}

# resolve_url <url>
#
# Apply RTSP_MODE to a single URL.
resolve_url() {
    case "$RTSP_MODE" in
        auto)  normalize_rtsp "$1" ;;
        plain) to_plain_rtsp "$1" ;;
        *)
            echo "resolve_url: unknown RTSP_MODE '$RTSP_MODE' (expected auto or plain)" >&2
            return 1
            ;;
    esac
}

# feed_key <index>
#
# Hotkey for a feed: 1..9 for the first nine, 0 for the tenth.
feed_key() {
    case "$1" in
        [1-9]) printf '%s' "$1" ;;
        10)    printf '0' ;;
        *)
            echo "feed_key: index out of range: $1" >&2
            return 1
            ;;
    esac
}

# resume_index <saved> <count>
#
# Which feed to open when none was asked for: the one last watched, if it is
# still configured, otherwise the first. <saved> is whatever the state file
# held, so it may be empty or junk; <count> is how many feeds are configured.
# Feeds are always numbered 1..count, since feeds_load renumbers past any it
# skips.
resume_index() {
    case "$1" in
        ''|*[!0-9]*) printf '1' ;;
        *)
            if [ "$1" -ge 1 ] && [ "$1" -le "$2" ]; then
                printf '%s' "$1"
            else
                printf '1'
            fi
            ;;
    esac
}

# placement_field <file> <key>
#
# One value from the placement file the menu bar button writes before opening
# the viewer, and rewrites whenever the window is moved or resized:
#
#   screen=Studio Display
#   scale=0.75
#   geometry=+200+150
#
# Prints nothing if the file or the key is missing, which view.sh reads as
# "mpv's default". Values are checked here rather than trusted, since they end
# up on mpv's command line: a scale must be a positive number, a geometry must
# be +X+Y in whole pixels, where either may be negative as "+-380".
placement_field() {
    [ -f "$1" ] || return 0
    _value=$(sed -n "s/^$2=//p" "$1" | tail -1)
    case "$2" in
        scale)
            case "$_value" in
                ''|*[!0-9.]*|*.*.*|.) ;;
                *) awk -v v="$_value" 'BEGIN { exit !(v + 0 > 0) }' && printf '%s' "$_value" ;;
            esac
            ;;
        geometry)
            case "$_value" in
                +*+*)
                    _rest="${_value#+}"
                    _x="${_rest%%+*}"
                    _y="${_rest#*+}"
                    case "${_x#-}" in ''|*[!0-9]*) return 0 ;; esac
                    case "${_y#-}" in ''|*[!0-9]*) return 0 ;; esac
                    printf '%s' "$_value"
                    ;;
            esac
            ;;
        *) printf '%s' "$_value" ;;
    esac
}

# placement_reset <file>
#
# Drop the scale and position from a placement file, keeping the screen, so
# the next start is mpv's default size and position on the same display.
placement_reset() {
    [ -f "$1" ] || return 0
    _screen=$(sed -n 's/^screen=//p' "$1" | tail -1)
    if [ -n "$_screen" ]; then
        printf 'screen=%s\n' "$_screen" >"$1"
    else
        : >"$1"
    fi
}

# feeds_load <config-file>
#
# Read streams.conf and emit one "<index>\t<name>\t<url>" line per usable feed.
#
# Each config line is "Name = URL". The name is everything before the first
# equals sign, so it may contain spaces. Order in the file decides the hotkey,
# which is why this preserves it rather than sorting. Feeds past MAX_FEEDS are
# dropped, and lines whose URL does not parse are skipped with a warning rather
# than failing the whole file — one typo should not stop the other cameras
# working.
#
# Returns 1 if the file is missing or yields no usable feeds.
feeds_load() {
    conf="$1"

    if [ ! -f "$conf" ]; then
        echo "feeds_load: no config at $conf" >&2
        return 1
    fi

    count=0
    dropped=0

    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|'#'*) continue ;;
        esac

        # No equals sign means it is not a feed line.
        case "$line" in
            *=*) ;;
            *) continue ;;
        esac

        name=$(printf '%s' "${line%%=*}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        raw=$(printf '%s' "${line#*=}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

        [ -n "$name" ] && [ -n "$raw" ] || continue

        if [ "$count" -ge "$MAX_FEEDS" ]; then
            dropped=$((dropped + 1))
            continue
        fi

        url=$(resolve_url "$raw" 2>/dev/null) || {
            echo "feeds_load: skipping '$name': not a usable RTSP URL" >&2
            continue
        }

        count=$((count + 1))
        printf '%s\t%s\t%s\n' "$count" "$name" "$url"
    done <"$conf"

    if [ "$dropped" -gt 0 ]; then
        echo "feeds_load: only the first $MAX_FEEDS feeds are used, ignored $dropped more" >&2
    fi

    if [ "$count" -eq 0 ]; then
        echo "feeds_load: no usable feeds in $conf" >&2
        return 1
    fi
}
