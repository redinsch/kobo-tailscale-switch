#!/bin/sh
# tailscale-switch: turn Tailscale on or off, by hand or from the Wi-Fi network.
#
#   tailscale-switch.sh up            connect (tailscale up with the configured flags)
#   tailscale-switch.sh down          disconnect (tailscale down)
#   tailscale-switch.sh auto [ssid [bssid]]
#                                     up on a foreign network, down at home or with no network
#   tailscale-switch.sh check         what auto would do now, without doing it
#   tailscale-switch.sh state         one word: running | stopped | needs-login | no-daemon | no-binary
#   tailscale-switch.sh status        the output of tailscale status
#
# Settings live in config.sh next to this script; the KOReader plugin edits the same file.
# HOME_NETWORKS is comma separated; an entry is a network name, an access point
# (aa:bb:cc:dd:ee:ff) or name@aa:bb:cc:dd:ee:ff for that access point under that name.

DIR=$(dirname "$0")
CONF="$DIR/config.sh"
LOG="$DIR/last.log"

HOME_NETWORKS=""
HOME_SSIDS=""   # older name, still honoured
LOGIN_SERVER=""
UP_ARGS="--accept-routes"
TAILSCALE_BIN=""
TAILSCALED_START=""
AUTO=1
[ -f "$CONF" ] && . "$CONF"
[ -z "$HOME_NETWORKS" ] && HOME_NETWORKS="$HOME_SSIDS"

# Keep the log small: 64 KB at most, then only the newest 200 lines survive.
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 65536 ]; then
    tail -n 200 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
fi

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null
    echo "$*"
}

find_binary() {
    if [ -n "$TAILSCALE_BIN" ] && [ -x "$TAILSCALE_BIN" ]; then
        echo "$TAILSCALE_BIN"
        return 0
    fi
    for candidate in tailscale /usr/bin/tailscale /usr/local/bin/tailscale /opt/tailscale/tailscale \
        /mnt/onboard/.adds/tailscale/tailscale /mnt/onboard/.adds/bin/tailscale; do
        if command -v "$candidate" >/dev/null 2>&1; then
            command -v "$candidate"
            return 0
        fi
    done
    return 1
}

daemon_running() {
    pidof tailscaled >/dev/null 2>&1 || pgrep tailscaled >/dev/null 2>&1
}

ensure_daemon() {
    daemon_running && return 0
    if [ -z "$TAILSCALED_START" ]; then
        log "tailscaled is not running and TAILSCALED_START is empty"
        return 1
    fi
    log "starting tailscaled: $TAILSCALED_START"
    sh -c "$TAILSCALED_START" >/dev/null 2>&1 &
    i=0
    while [ $i -lt 15 ]; do
        daemon_running && return 0
        sleep 1
        i=$((i + 1))
    done
    log "tailscaled did not start"
    return 1
}

backend_state() {
    "$TS" status --json 2>/dev/null | sed -n 's/.*"BackendState": *"\([^"]*\)".*/\1/p' | head -n 1
}

state() {
    if [ -z "$TS" ]; then echo no-binary; return; fi
    if ! daemon_running; then echo no-daemon; return; fi
    case "$(backend_state)" in
        Running|Starting) echo running ;;
        NeedsLogin|NeedsMachineAuth) echo needs-login ;;
        "") echo no-daemon ;;
        *) echo stopped ;;
    esac
}

# wpa_cli status, from the interface KOReader uses or the usual names.
wpa_status() {
    command -v wpa_cli >/dev/null 2>&1 || return 1
    for iface in "${INTERFACE:-eth0}" wlan0 eth0; do
        out=$(wpa_cli -i "$iface" status 2>/dev/null) && [ -n "$out" ] && { echo "$out"; return 0; }
    done
    return 1
}

# Sets CUR_SSID and CUR_BSSID (lower case) from the arguments or the system.
current_network() {
    CUR_SSID="$1"
    CUR_BSSID=$(echo "$2" | tr 'A-F' 'a-f')
    if [ -z "$CUR_SSID" ]; then
        status=$(wpa_status)
        # wpa_cli escapes bytes outside ASCII as \xNN; printf %b turns them back into UTF-8.
        CUR_SSID=$(printf '%b' "$(echo "$status" | sed -n 's/^ssid=//p' | head -n 1)")
        [ -z "$CUR_BSSID" ] && CUR_BSSID=$(echo "$status" | sed -n 's/^bssid=//p' | head -n 1 | tr 'A-F' 'a-f')
        if [ -z "$CUR_SSID" ] && command -v iwgetid >/dev/null 2>&1; then
            CUR_SSID=$(iwgetid -r 2>/dev/null)
            CUR_BSSID=$(iwgetid -ar 2>/dev/null | tr 'A-F' 'a-f')
        fi
    fi
}

is_mac() {
    echo "$1" | grep -Eq '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$'
}

# True when the current network matches one HOME_NETWORKS entry.
is_home() {
    rest="$HOME_NETWORKS"
    while [ -n "$rest" ]; do
        case "$rest" in
            *,*) item="${rest%%,*}"; rest="${rest#*,}" ;;
            *) item="$rest"; rest="" ;;
        esac
        item=$(echo "$item" | sed 's/^ *//; s/ *$//')
        [ -z "$item" ] && continue
        lower=$(echo "$item" | tr 'A-F' 'a-f')
        if is_mac "$lower"; then
            [ -n "$CUR_BSSID" ] && [ "$lower" = "$CUR_BSSID" ] && return 0
        else
            name="${item%@*}"
            mac=""
            case "$item" in *@*) mac=$(echo "${item##*@}" | tr 'A-F' 'a-f') ;; esac
            if [ -n "$mac" ] && is_mac "$mac"; then
                [ "$name" = "$CUR_SSID" ] && [ "$mac" = "$CUR_BSSID" ] && return 0
            else
                [ "$item" = "$CUR_SSID" ] && return 0
            fi
        fi
    done
    return 1
}

do_up() {
    [ -n "$TS" ] || { log "tailscale binary not found"; return 2; }
    ensure_daemon || return 1
    set -- up --timeout=30s
    [ -n "$LOGIN_SERVER" ] && set -- "$@" "--login-server=$LOGIN_SERVER"
    # UP_ARGS is split on whitespace on purpose.
    # shellcheck disable=SC2086
    set -- "$@" $UP_ARGS
    log "tailscale $*"
    output=$("$TS" "$@" 2>&1)
    rc=$?
    [ -n "$output" ] && log "$output"
    return $rc
}

do_down() {
    [ -n "$TS" ] || { log "tailscale binary not found"; return 2; }
    daemon_running || { log "tailscaled is not running, nothing to stop"; return 0; }
    log "tailscale down"
    output=$("$TS" down 2>&1)
    rc=$?
    [ -n "$output" ] && log "$output"
    return $rc
}

# Sets DECISION (up or down) and WHY from the current network.
decide() {
    current_network "$1" "$2"
    if [ -z "$CUR_SSID" ]; then
        DECISION=down; WHY="no Wi-Fi network"
    elif is_home; then
        DECISION=down; WHY="home network '$CUR_SSID' ($CUR_BSSID)"
    else
        DECISION=up; WHY="foreign network '$CUR_SSID' ($CUR_BSSID)"
    fi
}

do_auto() {
    if [ "$AUTO" != "1" ]; then
        log "automatic switching is off"
        return 0
    fi
    decide "$1" "$2"
    log "$WHY: $DECISION"
    if [ "$DECISION" = up ]; then do_up; else do_down; fi
}

do_check() {
    decide "$1" "$2"
    echo "network: ${CUR_SSID:-(none)} ${CUR_BSSID:+($CUR_BSSID)}"
    echo "home networks: ${HOME_NETWORKS:-(none)}"
    echo "tailscale now: $(state)"
    if [ "$AUTO" != "1" ]; then
        echo "automatic switching is off, auto would do nothing"
    else
        echo "auto would: $DECISION ($WHY)"
    fi
}

TS=$(find_binary)

case "$1" in
    up) do_up ;;
    down) do_down ;;
    auto) do_auto "$2" "$3" ;;
    check) do_check "$2" "$3" ;;
    state) state ;;
    status)
        if [ -z "$TS" ]; then
            echo "tailscale binary not found"
            exit 2
        fi
        daemon_running || echo "tailscaled is not running"
        "$TS" status 2>&1
        ;;
    *)
        echo "usage: $0 up|down|auto [ssid [bssid]]|check [ssid [bssid]]|state|status"
        exit 64
        ;;
esac
