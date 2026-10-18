#!/bin/sh
# amnezia_router_update - safe AWG package updater for OpenWrt.
# Uses the signed, platform-specific feed maintained by 2Grey/awg-openwrt.

set -u

SCRIPT_VERSION="1.0.2"
UPSTREAM_URL="https://raw.githubusercontent.com/2Grey/awg-openwrt/refs/heads/master/amneziawg-feed-install.sh"
UPSTREAM_MARKER='FEED_ROOT="https://2grey.github.io/awg-openwrt"'
TMP_INSTALLER=""
BACKUP_DIR=""

info() { printf '\n[INFO] %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
die() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
cleanup() { [ -z "$TMP_INSTALLER" ] || rm -f "$TMP_INSTALLER"; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

usage() {
    cat <<USAGE
Amnezia Router Update v$SCRIPT_VERSION
Usage: $0 [-h]
  -h  show this help

Runs without an interactive confirmation prompt.

Updates AmneziaWG packages only. It does not create or modify VPN interfaces.
USAGE
}

while getopts ':h' opt; do
    case "$opt" in
        h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

[ "$(id -u)" = 0 ] || die "Run as root (SSH root@router)."
command -v wget >/dev/null 2>&1 || die "wget is required but was not found."
command -v tar >/dev/null 2>&1 || die "tar is required for backup."

BOARD_JSON=""
if command -v ubus >/dev/null 2>&1; then
    BOARD_JSON=$(ubus call system board 2>/dev/null || true)
fi
get_json_value() {
    _key="$1"
    if [ -n "$BOARD_JSON" ] && command -v jsonfilter >/dev/null 2>&1; then
        jsonfilter -s "$BOARD_JSON" -e "@.$_key" 2>/dev/null | head -n 1
    fi
}

OWRT_VERSION=$(get_json_value release.version)
TARGET=$(get_json_value release.target)
MODEL=$(get_json_value model)
KERNEL=$(uname -r 2>/dev/null || echo unknown)

if [ -f /etc/openwrt_release ]; then
    [ -n "$OWRT_VERSION" ] || OWRT_VERSION=$(sed -n "s/^DISTRIB_RELEASE=['\"]\{0,1\}\([^'\"]*\)['\"]\{0,1\}$/\1/p" /etc/openwrt_release | head -n 1)
    [ -n "$TARGET" ] || TARGET=$(sed -n "s/^DISTRIB_TARGET=['\"]\{0,1\}\([^'\"]*\)['\"]\{0,1\}$/\1/p" /etc/openwrt_release | head -n 1)
fi
[ -n "$OWRT_VERSION" ] || die "Could not detect OpenWrt version."
[ -n "$TARGET" ] || die "Could not detect target/subtarget."

case "$OWRT_VERSION" in
    24.10.0|24.10.1|24.10.2|24.10.3|24.10.4|24.10.5|24.10.6|24.10.7|24.10.8|\
    25.12.0|25.12.1|25.12.2|25.12.3|25.12.4|25.12.5) ;;
    *) die "OpenWrt $OWRT_VERSION is not in the verified feed matrix (24.10.0-24.10.8 / 25.12.0-25.12.5). No changes were made." ;;
esac

case "$TARGET" in
    */*) ;;
    *) die "Unexpected target format: $TARGET. No changes were made." ;;
esac

if command -v apk >/dev/null 2>&1; then
    PKG_MGR=apk
elif command -v opkg >/dev/null 2>&1; then
    PKG_MGR=opkg
else
    die "Neither apk nor opkg was found. No changes were made."
fi

info "Amnezia Router Update v$SCRIPT_VERSION"
printf 'Model:       %s\nOpenWrt:     %s\nKernel:      %s\nTarget:      %s\nPackage mgr: %s\n' \
    "${MODEL:-unknown}" "$OWRT_VERSION" "$KERNEL" "$TARGET" "$PKG_MGR"

info "Currently installed AmneziaWG packages"
if [ "$PKG_MGR" = opkg ]; then
    opkg list-installed 2>/dev/null | grep -E '^(amneziawg|kmod-amneziawg|luci-(proto|app)-amneziawg|luci-i18n-amneziawg)' || true
else
    apk list -I 2>/dev/null | grep -E '^(amneziawg|kmod-amneziawg|luci-(proto|app)-amneziawg|luci-i18n-amneziawg)' || true
fi

STAMP=$(date '+%Y%m%d-%H%M%S' 2>/dev/null || echo unknown)
BACKUP_DIR="/root/amnezia_router_update-backup-$STAMP"
mkdir -p "$BACKUP_DIR" || die "Cannot create backup directory $BACKUP_DIR."

# Save router configuration and package inventory before touching package feeds.
if [ -d /etc/config ]; then
    tar -czf "$BACKUP_DIR/etc-config.tar.gz" -C /etc config || die "Backup of /etc/config failed. No package changes were made."
fi
for f in /etc/openwrt_release /etc/openwrt_version /etc/opkg/customfeeds.conf /etc/apk/repositories /etc/apk/repositories.d/customfeeds.list; do
    if [ -f "$f" ]; then
        mkdir -p "$BACKUP_DIR/$(dirname "$f")"
        cp -p "$f" "$BACKUP_DIR/$f" 2>/dev/null || warn "Could not copy $f"
    fi
done
if [ "$PKG_MGR" = opkg ]; then
    opkg list-installed > "$BACKUP_DIR/packages-before.txt" 2>&1 || true
else
    apk list -I > "$BACKUP_DIR/packages-before.txt" 2>&1 || true
fi
[ -z "$BOARD_JSON" ] || printf '%s\n' "$BOARD_JSON" > "$BACKUP_DIR/board.json"
info "Backup created: $BACKUP_DIR"

info "No confirmation prompt: proceeding with the AWG package update. The router will NOT reboot automatically."

TMP_INSTALLER="/tmp/amneziawg-feed-install-$$.sh"
info "Downloading upstream installer..."
wget -q -O "$TMP_INSTALLER" "$UPSTREAM_URL" || die "Download failed. No package installation was attempted. Backup: $BACKUP_DIR"
[ -s "$TMP_INSTALLER" ] || die "Downloaded installer is empty."
grep -F -q "$UPSTREAM_MARKER" "$TMP_INSTALLER" || die "Upstream installer content did not match expected project marker. Aborting."

info "Running signed-feed installer (Russian LuCI translation included)..."
if sh "$TMP_INSTALLER" -r; then
    info "Package installer finished successfully."
else
    status=$?
    warn "Upstream installer exited with status $status. Review its output; backup retained at $BACKUP_DIR."
    exit "$status"
fi

info "Installed AmneziaWG packages after update"
if [ "$PKG_MGR" = opkg ]; then
    opkg list-installed 2>/dev/null | grep -E '^(amneziawg|kmod-amneziawg|luci-(proto|app)-amneziawg|luci-i18n-amneziawg)' || true
else
    apk list -I 2>/dev/null | grep -E '^(amneziawg|kmod-amneziawg|luci-(proto|app)-amneziawg|luci-i18n-amneziawg)' || true
fi

AWG_VERSION_OUTPUT=$(awg --version 2>&1 || true)
printf '\nAWG command: %s\n' "${AWG_VERSION_OUTPUT:-not found}"
case "$AWG_VERSION_OUTPUT" in
    *v3.1*) ;;
    *) warn "The installed awg command does not report v3.1. Do not assume the upgrade is complete; inspect package state and reboot if an older binary/module is still loaded." ;;
esac

cat <<EOF

[IMPORTANT] Next steps:
  1. Reboot the router when you have a maintenance window so the new kernel module is loaded.
  2. After reboot, check the VPN interface and test traffic/DNS.
  3. If LuCI looks outdated, hard-refresh the browser (Ctrl+F5).

Backup: $BACKUP_DIR
The script did not create or alter VPN interface configuration.
EOF
