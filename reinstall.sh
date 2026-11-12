#!/bin/bash
# Rebuild and reinstall the patched mtk_t7xx module — Armbian/Debian/Ubuntu.
# Idempotent. Safe to run multiple times.
#
# Usage:  bash reinstall.sh [--skip-build] [-y|--yes] [--keepalive|--no-keepalive]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODULE_NAME="mtk_t7xx"
MODULE_VERSION="1.2.0"
DKMS_DIR="/usr/src/${MODULE_NAME}-${MODULE_VERSION}"
KVER="$(uname -r)"
SKIP_BUILD=0
ASSUME_YES=0
KEEPALIVE_CONF="/etc/modprobe.d/mtk-t7xx-keepalive.conf"
KEEPALIVE_S2IDLE=""

for arg in "$@"; do
    case "$arg" in
        --skip-build) SKIP_BUILD=1 ;;
        -y|--yes) ASSUME_YES=1 ;;
        --keepalive) KEEPALIVE_S2IDLE=1 ;;
        --no-keepalive) KEEPALIVE_S2IDLE=0 ;;
    esac
done

# --- Preflight checks ---
if [ ! -d "/lib/modules/$KVER/build" ]; then
    echo "ERROR: kernel headers not found for $KVER"
    echo "  Expected: /lib/modules/$KVER/build"
    echo "  Install:  sudo apt update && sudo apt install -y linux-headers-$KVER"
    echo "  If the package is not available, install the meta package:"
    echo "            sudo apt install -y linux-headers-$(uname -r | sed 's/-[^-]*$//')"
    exit 1
fi

if ! command -v dkms >/dev/null 2>&1; then
    echo "ERROR: dkms not installed. Run: sudo apt install -y dkms"
    exit 1
fi

# iommu=pt check — Armbian uses /boot/armbianEnv.txt, not grubby.
if ! grep -q 'iommu=pt' /proc/cmdline; then
    echo "WARNING: 'iommu=pt' is not in your kernel boot parameters."
    echo "The modem may not work without it."
    echo ""
    echo "  On Armbian, edit /boot/armbianEnv.txt:"
    echo "      sudo sed -i 's/^\\(extraargs=.*\\)$/\\1 iommu=pt/' /boot/armbianEnv.txt"
    echo "  Then reboot."
    echo ""
    if [ "$ASSUME_YES" -eq 1 ]; then
        echo "[-y] continuing without iommu=pt."
    else
        read -rp "Continue anyway? [y/N] " ans
        [[ "$ans" =~ ^[Yy]$ ]] || exit 1
    fi
fi

# --- DTB sanity check (RK3588 alignment fix) ---
DTB=""
for cand in "/boot/dtb-$KVER/rockchip/rk3588-orangepi-5-max.dtb" \
            "/boot/dtb/rockchip/rk3588-orangepi-5-max.dtb"; do
    [ -f "$cand" ] && { DTB="$cand"; break; }
done
if [ -n "$DTB" ] && command -v dtc >/dev/null 2>&1; then
    if dtc -I dtb -O dts "$DTB" 2>/dev/null | grep -q '0x3fff0000'; then
        echo "OK: DTB pcie@fe150000 ranges already patched (0x3fff0000)."
    else
        echo "WARNING: DTB pcie@fe150000 ranges still 0x40000000."
        echo "  RK3588 alignment fault will recur. See docs/ or earlier"
        echo "  instructions to change 0x40000000 -> 0x3fff0000 in the DTS."
    fi
fi

# --- Modem suspend strategy prompt ---
if [ -z "$KEEPALIVE_S2IDLE" ]; then
    if [ -f "$KEEPALIVE_CONF" ] && grep -q '^[[:space:]]*options.*keepalive_s2idle=1' "$KEEPALIVE_CONF"; then
        DEFAULT_CHOICE=2; DEFAULT_LABEL="2 (keepalive)"
    else
        DEFAULT_CHOICE=1; DEFAULT_LABEL="1 (full suspend)"
    fi
    echo ""
    echo "=== Modem suspend behavior ==="
    echo "  1) Full suspend  — driver default. Resume needs PLDR + reprobe (~30-45 s)."
    echo "  2) Keepalive     — firmware stays online during s2idle. Resume < 5 s."
    echo "                     Requires a driver with keepalive_s2idle support."
    echo ""
    if [ "$ASSUME_YES" -eq 1 ]; then
        case "$DEFAULT_CHOICE" in
            2) KEEPALIVE_S2IDLE=1 ;;
            *) KEEPALIVE_S2IDLE=0 ;;
        esac
        echo "[-y] using default: $DEFAULT_LABEL."
    else
        read -rp "Choose [1/2] (default $DEFAULT_LABEL): " choice
        case "$choice" in
            1) KEEPALIVE_S2IDLE=0 ;;
            2) KEEPALIVE_S2IDLE=1 ;;
            "") case "$DEFAULT_CHOICE" in 2) KEEPALIVE_S2IDLE=1 ;; *) KEEPALIVE_S2IDLE=0 ;; esac ;;
            *)  case "$DEFAULT_CHOICE" in 2) KEEPALIVE_S2IDLE=1 ;; *) KEEPALIVE_S2IDLE=0 ;; esac ;;
        esac
    fi
fi

# --- Build (no root needed) ---
if [ "$SKIP_BUILD" -eq 0 ]; then
    echo "=== Building patched mtk_t7xx module ==="
    cd "$SCRIPT_DIR/src"
    make -C "/lib/modules/$KVER/build" M="$PWD" clean 2>/dev/null || true
    rm -f .*.cmd modules.order Module.symvers 2>/dev/null || true
    make -C "/lib/modules/$KVER/build" M="$PWD" modules
    echo ""
fi

# --- Install (needs root) ---
if [ "$EUID" -ne 0 ]; then
    echo "Build succeeded. Elevating for install..."
    REEXEC_ARGS=(--skip-build)
    [ "$ASSUME_YES" -eq 1 ] && REEXEC_ARGS+=(-y)
    case "$KEEPALIVE_S2IDLE" in
        1) REEXEC_ARGS+=(--keepalive) ;;
        0) REEXEC_ARGS+=(--no-keepalive) ;;
    esac
    exec sudo bash "$SCRIPT_DIR/reinstall.sh" "${REEXEC_ARGS[@]}"
fi

echo "=== Installing via DKMS ==="
dkms remove "${MODULE_NAME}/${MODULE_VERSION}" --all 2>/dev/null || true
rm -rf "${DKMS_DIR}"
mkdir -p "${DKMS_DIR}/src"
cp "$SCRIPT_DIR"/src/*.c "$SCRIPT_DIR"/src/*.h "$SCRIPT_DIR"/src/Makefile "${DKMS_DIR}/src/"
cp "$SCRIPT_DIR/dkms.conf" "${DKMS_DIR}/"
dkms add    "${MODULE_NAME}/${MODULE_VERSION}"
dkms build  "${MODULE_NAME}/${MODULE_VERSION}" -k "$KVER"
dkms install "${MODULE_NAME}/${MODULE_VERSION}" -k "$KVER"

# --- ModemManager FCC unlock for FM350 (14c3:4d75) ---
FCC_UNLOCK_DIR="/usr/lib/ModemManager/fcc-unlock.d"
FCC_UNLOCK_SRC="/usr/share/ModemManager/fcc-unlock.available.d/14c3"
if [ -f "$FCC_UNLOCK_SRC" ]; then
    mkdir -p "$FCC_UNLOCK_DIR"
    cp "$FCC_UNLOCK_SRC" "$FCC_UNLOCK_DIR/14c3:4d75"
    chmod 755 "$FCC_UNLOCK_DIR/14c3:4d75"
fi

# xxd — Debian/Ubuntu has a standalone package
if ! command -v xxd &>/dev/null; then
    apt-get install -y xxd || apt-get install -y vim-common || true
fi

# Disable Lenovo/Fibocom services (harmless if absent)
for svc in fibo_helper.service fibo_flash.service fwswitch.service lenovo-cfgservice.service; do
    systemctl disable --now "$svc" 2>/dev/null || true
done

# Cap ModemManager stop timeout
MM_DROPIN_DIR="/etc/systemd/system/ModemManager.service.d"
MM_DROPIN="${MM_DROPIN_DIR}/quick-stop.conf"
mkdir -p "$MM_DROPIN_DIR"
cat > "$MM_DROPIN" <<'EOF'
[Service]
TimeoutStopSec=10
EOF
systemctl daemon-reload

# --- Systemd sleep hook for ModemManager ---
SLEEP_HOOK="/usr/lib/systemd/system-sleep/99-modem-fix.sh"
cat > "$SLEEP_HOOK" <<'HOOKEOF'
#!/bin/bash
# Restart ModemManager around suspend/hibernate (Armbian/Debian variant).
#   - s2idle resume: MBIM session may be stale → restart MM after short delay.
#   - hibernate/STH resume: modem re-probes in the driver; wait longer.
#   - keepalive_s2idle=Y: driver skipped firmware suspend → fast restart.
LOG_TAG="modem-fix"
UNIT_FILE=/run/modem-fix-resume.unit
KEEPALIVE_PARAM="/sys/module/mtk_t7xx/parameters/keepalive_s2idle"

logger -t "$LOG_TAG" "hook called: action=$1 target=${2:-unknown}"

recent_keepalive_skip() {
    [ -r "$KEEPALIVE_PARAM" ] || return 1
    [ "$(cat "$KEEPALIVE_PARAM" 2>/dev/null)" = "Y" ] || return 1
    journalctl -k -b --since "30s ago" 2>/dev/null \
        | grep -q "keepalive_s2idle: skipping firmware suspend"
}

cancel_pending() {
    [ -f "$UNIT_FILE" ] || return 0
    local unit
    unit=$(cat "$UNIT_FILE" 2>/dev/null)
    rm -f "$UNIT_FILE"
    [ -n "$unit" ] || return 0
    logger -t "$LOG_TAG" "cancelling pending ${unit}"
    systemctl stop "${unit}.timer" "${unit}.service" 2>/dev/null || true
    systemctl reset-failed "${unit}.timer" "${unit}.service" 2>/dev/null || true
}

schedule_mm() {
    local delay=$1
    [[ "$delay" =~ ^[0-9]+$ ]] || { logger -t "$LOG_TAG" "invalid delay: $delay"; return 1; }
    local unit="modem-fix-resume-$(date +%s%N)"
    echo "$unit" > "$UNIT_FILE"
    logger -t "$LOG_TAG" "scheduling ModemManager restart in ${delay}s as ${unit}"
    systemd-run --no-block --on-active="${delay}s" --unit="$unit" \
        bash -c 'systemctl restart ModemManager; logger -t modem-fix "ModemManager restart exit: $?"'
}

case "$1/$2" in
    pre/suspend)
        cancel_pending
        ;;
    pre/hibernate|pre/suspend-then-hibernate)
        cancel_pending
        if systemctl is-active ModemManager >/dev/null 2>&1; then
            logger -t "$LOG_TAG" "stopping ModemManager before ${2}"
            systemctl stop ModemManager 2>/dev/null || true
        fi
        ;;
    post/suspend)
        schedule_mm 3
        ;;
    post/hibernate|post/suspend-then-hibernate)
        if recent_keepalive_skip; then
            logger -t "$LOG_TAG" "keepalive_s2idle skip detected — fast restart"
            schedule_mm 3
        else
            schedule_mm 35
        fi
        ;;
esac
HOOKEOF
chmod 755 "$SLEEP_HOOK"

# --- SDDM hook (only if the helper script exists; irrelevant for headless) ---
SDDM_HOOK="/usr/lib/systemd/system-sleep/50-sddm-displays.sh"
if [ -x /usr/local/bin/generate-sddm-display-config ]; then
cat > "$SDDM_HOOK" <<'SDDMEOF'
#!/bin/bash
GENERATOR=/usr/local/bin/generate-sddm-display-config
LOG_TAG="sddm-displays"
has_healthy_user_wayland_session() {
    local id user type state
    while read -r id user; do
        [ -z "$id" ] && continue
        [ "$user" = "sddm" ] && continue
        type=$(loginctl show-session "$id" -p Type --value 2>/dev/null)
        state=$(loginctl show-session "$id" -p State --value 2>/dev/null)
        [ "$type" = "wayland" ] || continue
        [ "$state" != "closing" ] || continue
        pgrep -u "$user" -x kwin_wayland >/dev/null 2>&1 && return 0
    done < <(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1" "$3}')
    return 1
}
lock_user_wayland_sessions() {
    local id user type
    while read -r id user; do
        [ -z "$id" ] && continue
        [ "$user" = "sddm" ] && continue
        type=$(loginctl show-session "$id" -p Type --value 2>/dev/null)
        [ "$type" = "wayland" ] || continue
        loginctl lock-session "$id" 2>/dev/null || true
    done < <(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1" "$3}')
}
case "$1/$2" in
    pre/hibernate)
        lock_user_wayland_sessions
        systemctl stop sddm 2>/dev/null || true
        ;;
    post/hibernate)
        $GENERATOR 2>/dev/null
        if has_healthy_user_wayland_session; then
            logger -t "$LOG_TAG" "user wayland session alive; leaving SDDM stopped"
        else
            logger -t "$LOG_TAG" "restarting SDDM"
            systemctl restart sddm 2>/dev/null || true
        fi
        ;;
    post/suspend)
        $GENERATOR &>/dev/null &
        ;;
esac
SDDMEOF
chmod 755 "$SDDM_HOOK"
else
    echo "NOTE: /usr/local/bin/generate-sddm-display-config not found; skipping SDDM hook."
fi

# --- Keepalive module parameter ---
if [ "${KEEPALIVE_S2IDLE:-0}" = "1" ]; then
    cat > "$KEEPALIVE_CONF" <<'EOF'
# Keep FM350-GL firmware running during suspend-to-idle.
options mtk_t7xx keepalive_s2idle=1
EOF
    echo "Wrote $KEEPALIVE_CONF"
else
    rm -f "$KEEPALIVE_CONF"
    echo "Removed $KEEPALIVE_CONF (default full-suspend behavior)"
fi

# Warn if the built module does not expose keepalive_s2idle
if ! modinfo "${MODULE_NAME}" 2>/dev/null | grep -q '^parm:.*keepalive_s2idle'; then
    echo "NOTE: current ${MODULE_NAME} has no keepalive_s2idle module parameter."
    echo "      The keepalive option will be silently ignored by the kernel."
fi

# --- Initramfs (Debian/Ubuntu) ---
echo "Rebuilding initramfs..."
update-initramfs -u -k "$KVER" 2>/dev/null || update-initramfs -u

echo ""
if [ "$ASSUME_YES" -eq 1 ]; then
    echo "[-y] Rebooting now..."
    reboot
else
    read -rp "=== Done! Reboot now? [y/N] " REPLY
    if [[ "$REPLY" =~ ^[Yy]$ ]]; then
        reboot
    else
        echo "Skipping reboot. Please reboot manually to load the new module."
    fi
fi
