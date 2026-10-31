#!/bin/sh
# Installs the Tailscale switch on a Kobo, over SSH or onto the USB drive.
#
#   ./deploy.sh [parts] <kobo-ip> [port]      over SSH; the port defaults to 2222
#   ./deploy.sh [parts] --usb <mount point>   onto the Kobo mounted as a USB drive,
#                                             for example /run/media/you/KOBOeReader
#
# parts (default: both):
#   --koreader     the KOReader plugin
#   --nickelmenu   the NickelMenu entries
# The switch script and config.sh.example are always installed, both parts
# need them. An existing config.sh is kept.
#
# Over SSH, sshpass is used with the password from KOBO_PASSWORD (empty by
# default, like KOReader's SSH server) when it is installed; otherwise ssh asks.
set -e
cd "$(dirname "$0")"

WANT_KOREADER=""
WANT_NICKEL=""
USB=""
HOST=""
PORT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --koreader) WANT_KOREADER=1 ;;
        --nickelmenu|--nickel) WANT_NICKEL=1 ;;
        --usb) shift; USB="$1" ;;
        -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 64 ;;
        *) if [ -z "$HOST" ]; then HOST="$1"; else PORT="$1"; fi ;;
    esac
    shift
done
if [ -z "$WANT_KOREADER" ] && [ -z "$WANT_NICKEL" ]; then
    WANT_KOREADER=1
    WANT_NICKEL=1
fi
PORT="${PORT:-2222}"

if [ -n "$USB" ]; then
    if [ ! -d "$USB" ]; then
        echo "not a folder: $USB" >&2
        exit 66
    fi
    if [ ! -d "$USB/.kobo" ]; then
        echo "no .kobo folder in $USB, is that the Kobo's USB drive?" >&2
        exit 66
    fi
    ADDS="$USB/.adds"
    echo "switch -> $ADDS/tailscale-switch"
    mkdir -p "$ADDS/tailscale-switch"
    cp adds/tailscale-switch/tailscale-switch.sh adds/tailscale-switch/config.sh.example "$ADDS/tailscale-switch/"
    if [ -n "$WANT_KOREADER" ]; then
        if [ ! -d "$ADDS/koreader" ]; then
            echo "note: $ADDS/koreader does not exist, is KOReader installed? Installing the plugin anyway." >&2
        fi
        echo "plugin -> $ADDS/koreader/plugins/tailscale.koplugin"
        mkdir -p "$ADDS/koreader/plugins"
        rm -rf "$ADDS/koreader/plugins/tailscale.koplugin"
        cp -r koreader/tailscale.koplugin "$ADDS/koreader/plugins/"
    fi
    if [ -n "$WANT_NICKEL" ]; then
        if [ ! -d "$ADDS/nm" ]; then
            echo "note: $ADDS/nm does not exist, is NickelMenu installed? Installing the entries anyway." >&2
        fi
        echo "NickelMenu -> $ADDS/nm/tailscale"
        mkdir -p "$ADDS/nm"
        cp adds/nm/tailscale "$ADDS/nm/tailscale"
    fi
    sync
    echo "done. Eject the Kobo safely, then restart KOReader (plugin) or let Nickel rescan (menu)."
    exit 0
fi

if [ -z "$HOST" ]; then
    echo "usage: $0 [--koreader] [--nickelmenu] <kobo-ip> [port]" >&2
    echo "       $0 [--koreader] [--nickelmenu] --usb <mount point>" >&2
    exit 64
fi
ADDS=/mnt/onboard/.adds
if command -v sshpass >/dev/null 2>&1; then
    export SSHPASS="${KOBO_PASSWORD:-}"
    SSH="sshpass -e ssh -o StrictHostKeyChecking=no -p $PORT root@$HOST"
else
    SSH="ssh -p $PORT root@$HOST"
fi

echo "switch -> $ADDS/tailscale-switch"
tar -C adds -cf - tailscale-switch/tailscale-switch.sh tailscale-switch/config.sh.example | $SSH "mkdir -p $ADDS && cd $ADDS && tar -xf -"

if [ -n "$WANT_KOREADER" ]; then
    echo "plugin -> $ADDS/koreader/plugins/tailscale.koplugin"
    tar -C koreader -cf - tailscale.koplugin | $SSH "mkdir -p $ADDS/koreader/plugins && cd $ADDS/koreader/plugins && rm -rf tailscale.koplugin && tar -xf -"
fi

if [ -n "$WANT_NICKEL" ]; then
    echo "NickelMenu -> $ADDS/nm/tailscale"
    tar -C adds -cf - nm/tailscale | $SSH "mkdir -p $ADDS/nm && cd $ADDS && tar -xf -"
fi

$SSH "ls $ADDS/tailscale-switch; command -v tailscale || echo 'NOTE: tailscale is not on the PATH of the SSH shell'"
echo "done. Restart KOReader for the plugin; NickelMenu picks up its entries on the next menu open."
