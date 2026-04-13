#!/bin/bash
set -e

echo "=== ASUS UX510 Fan 2 Controller - Installation ==="

# 1. Ensure acpi_call is installed and loaded
echo "[1/5] Installing dependencies..."
sudo apt install -y acpi-call-dkms linux-headers-$(uname -r) 2>/dev/null
sudo modprobe acpi_call 2>/dev/null
echo "acpi_call" | sudo tee /etc/modules-load.d/acpi_call.conf > /dev/null

# 2. Create config (preserve existing config if present)
echo "[2/5] Creating config..."
sudo mkdir -p /etc/asus-fan2
if [ -f /etc/asus-fan2/config ]; then
    echo "     Config already exists, backing up to /etc/asus-fan2/config.bak"
    sudo cp /etc/asus-fan2/config /etc/asus-fan2/config.bak
fi
sudo tee /etc/asus-fan2/config > /dev/null << 'CONFIG'
# ASUS UX510 Fan 2 Configuration
# Edit then restart: sudo systemctl restart asus-fan2

# Enable fan 2 when on AC power
ENABLE_ON_AC=true

# Enable fan 2 when on battery
ENABLE_ON_BATTERY=false

# Temperature threshold to activate fan 2 (Celsius)
TEMP_THRESHOLD=55

# Temperature critical — emergency stop if fan 1 defective at this temp
TEMP_CRITICAL=90

# Poll interval in seconds
POLL_INTERVAL=10

# Minimum expected fan 1 RPM when temperature is high (safety check)
FAN1_MIN_RPM=1500

# Hwmon paths (leave empty for auto-detection)
# Fan 1 RPM sensor — auto-detects hwmon named "asus" with fan1_input
FAN1_HWMON=""

# CPU temperature sensor — auto-detects hwmon named "coretemp"
CPU_TEMP_HWMON=""
CONFIG

# 3. Install control script
echo "[3/5] Installing control script..."
sudo tee /usr/local/bin/asus-fan2-ctrl > /dev/null << 'SCRIPT'
#!/bin/bash
# ASUS UX510 Fan 2 Controller
# Controls the second (GPU) fan via ACPI WRAM 0xF922 (bit 0x40 toggle)
#
# SAFETY: This script ONLY writes to register 0xF922 (bit 0x40).
#         It NEVER touches fan 1 registers (0xF921, 0x97, 0xA0, 0xA6).
#         It NEVER uses ec_probe or ST84.

CONFIG_FILE="/etc/asus-fan2/config"
ACPI_CALL="/proc/acpi/call"
LOG_TAG="asus-fan2"

# Defaults (overridden by config)
ENABLE_ON_AC=true
ENABLE_ON_BATTERY=false
POLL_INTERVAL=10
TEMP_THRESHOLD=55
TEMP_CRITICAL=90
FAN1_MIN_RPM=1500
FAN1_HWMON=""
CPU_TEMP_HWMON=""

[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

# ── Logging ──────────────────────────────────────────────────────────────

log() {
    logger -t "$LOG_TAG" "$1"
    echo "$(date): $1"
}

log_err() {
    logger -t "$LOG_TAG" -p user.err "$1"
    echo "$(date): ERROR: $1" >&2
}

# ── ACPI interface ───────────────────────────────────────────────────────

acpi_call() {
    echo "$1" > "$ACPI_CALL"
    cat "$ACPI_CALL" 2>/dev/null | tr -d '\0'
}

# ── Hardware detection ───────────────────────────────────────────────────

find_hwmon() {
    local target_name="$1"
    for h in /sys/class/hwmon/hwmon*; do
        if [ "$(cat "$h/name" 2>/dev/null)" = "$target_name" ]; then
            echo "$h"
            return 0
        fi
    done
    return 1
}

detect_hwmon_paths() {
    # Fan 1: look for hwmon named "asus" with fan1_input
    if [ -z "$FAN1_HWMON" ] || [ ! -f "$FAN1_HWMON" ]; then
        local asus_hwmon
        asus_hwmon=$(find_hwmon "asus") || true
        if [ -n "$asus_hwmon" ] && [ -f "$asus_hwmon/fan1_input" ]; then
            FAN1_HWMON="$asus_hwmon/fan1_input"
            log "Detected fan 1 hwmon: $FAN1_HWMON"
        elif [ -n "$FAN1_HWMON" ] && [ -f "$FAN1_HWMON" ]; then
            log "Using config fan 1 hwmon: $FAN1_HWMON"
        else
            log "WARNING: fan 1 hwmon not found — fan 1 safety monitoring disabled"
            FAN1_HWMON=""
        fi
    else
        log "Using config fan 1 hwmon: $FAN1_HWMON"
    fi

    # CPU temp: look for hwmon named "coretemp"
    if [ -z "$CPU_TEMP_HWMON" ] || [ ! -f "$CPU_TEMP_HWMON" ]; then
        local coretemp_hwmon
        coretemp_hwmon=$(find_hwmon "coretemp") || true
        if [ -n "$coretemp_hwmon" ] && [ -f "$coretemp_hwmon/temp1_input" ]; then
            CPU_TEMP_HWMON="$coretemp_hwmon/temp1_input"
            log "Detected CPU temp hwmon: $CPU_TEMP_HWMON"
        elif [ -n "$CPU_TEMP_HWMON" ] && [ -f "$CPU_TEMP_HWMON" ]; then
            log "Using config CPU temp hwmon: $CPU_TEMP_HWMON"
        else
            log_err "CPU temp hwmon not found — cannot operate safely"
            exit 1
        fi
    else
        log "Using config CPU temp hwmon: $CPU_TEMP_HWMON"
    fi
}

# ── Sensor reads ─────────────────────────────────────────────────────────

is_on_ac() {
    local s
    s=$(cat /sys/class/power_supply/AC0/online 2>/dev/null || echo "1")
    [ "$s" = "1" ]
}

get_cpu_temp() {
    local t
    t=$(cat "$CPU_TEMP_HWMON" 2>/dev/null || echo "0")
    echo $((t / 1000))
}

get_fan1_rpm() {
    if [ -n "$FAN1_HWMON" ] && [ -f "$FAN1_HWMON" ]; then
        cat "$FAN1_HWMON" 2>/dev/null || echo "0"
    else
        echo "-1"  # unknown
    fi
}

# ── Fan 2 control (ONLY register 0xF922, bit 0x40) ──────────────────────

fan2_present() {
    local val
    val=$(acpi_call '\_SB.PCI0.LPCB.EC0.RRAM 0xF920' | sed 's/^0x//')
    val=$((16#${val}))
    [ $(( val & 0x02 )) -ne 0 ]
}

fan2_read_reg() {
    acpi_call '\_SB.PCI0.LPCB.EC0.RRAM 0xF922'
}

fan2_on() {
    local cur
    cur=$(fan2_read_reg | sed 's/^0x//')
    cur=$((16#${cur}))
    local nv=$(( cur | 0x40 ))
    acpi_call "\_SB.PCI0.LPCB.EC0.WRAM 0xF922 $nv" > /dev/null
    log "Fan 2 ON (reg=0x$(printf '%02x' $nv))"
}

fan2_off() {
    local cur
    cur=$(fan2_read_reg | sed 's/^0x//')
    cur=$((16#${cur}))
    local nv=$(( cur & ~0x40 ))
    acpi_call "\_SB.PCI0.LPCB.EC0.WRAM 0xF922 $nv" > /dev/null
    log "Fan 2 OFF (reg=0x$(printf '%02x' $nv))"
}

fan2_is_on() {
    local cur
    cur=$(fan2_read_reg | sed 's/^0x//')
    cur=$((16#${cur}))
    [ $(( cur & 0x40 )) -ne 0 ]
}

# ── Startup checks ──────────────────────────────────────────────────────

preflight_checks() {
    # 1. acpi_call loaded?
    if [ ! -f "$ACPI_CALL" ]; then
        log_err "$ACPI_CALL not found — is acpi_call module loaded?"
        exit 1
    fi

    # 2. Fan 2 physically present?
    if ! fan2_present; then
        log_err "Fan 2 not detected (RRAM 0xF920 bit 0x02 not set)"
        exit 1
    fi
    log "Fan 2 presence confirmed"

    # 3. Log initial register value
    local init_val
    init_val=$(fan2_read_reg)
    log "Initial 0xF922 value: $init_val"

    # 4. Detect hwmon paths
    detect_hwmon_paths

    # 5. Check fan 1 health at startup
    local fan1_rpm
    fan1_rpm=$(get_fan1_rpm)
    if [ "$fan1_rpm" != "-1" ]; then
        log "Fan 1 RPM at startup: $fan1_rpm"
        local temp
        temp=$(get_cpu_temp)
        if [ "$fan1_rpm" -lt 1000 ] && [ "$temp" -gt 70 ]; then
            log_err "Fan 1 RPM dangerously low ($fan1_rpm) at ${temp}C — aborting"
            exit 1
        fi
    fi
}

# ── Fan 1 safety monitor ────────────────────────────────────────────────

check_fan1_safety() {
    local fan1_rpm
    fan1_rpm=$(get_fan1_rpm)
    [ "$fan1_rpm" = "-1" ] && return 0  # monitoring unavailable

    local temp
    temp=$(get_cpu_temp)

    if [ "$fan1_rpm" -lt "$FAN1_MIN_RPM" ] && [ "$temp" -gt 80 ]; then
        log_err "EMERGENCY: Fan 1 RPM=$fan1_rpm at ${temp}C — disabling fan 2 and stopping daemon"
        fan2_off
        exit 1
    fi
}

# ── Status display ───────────────────────────────────────────────────────

fan2_status() {
    # Detect paths for status display
    detect_hwmon_paths 2>/dev/null

    echo "=== ASUS UX510 Fan 2 Status ==="
    echo "AC Power       : $(is_on_ac && echo yes || echo no)"
    echo "CPU Temp       : $(get_cpu_temp)C"
    local fan1_rpm
    fan1_rpm=$(get_fan1_rpm)
    if [ "$fan1_rpm" != "-1" ]; then
        echo "Fan 1 RPM      : $fan1_rpm"
    fi
    echo "Fan 2          : $(fan2_is_on && echo ON || echo OFF)"
    echo "Fan 2 ST83     : $(acpi_call '\_SB.PCI0.LPCB.EC0.ST83 1')"
    echo "Fan 2 Reg F922 : $(fan2_read_reg)"
    echo "Config         : AC=$ENABLE_ON_AC  Battery=$ENABLE_ON_BATTERY  Threshold=${TEMP_THRESHOLD}C  Critical=${TEMP_CRITICAL}C"
}

# ── Main ─────────────────────────────────────────────────────────────────

case "${1:-daemon}" in
    on)      fan2_on ;;
    off)     fan2_off ;;
    status)  fan2_status ;;
    daemon)
        log "Starting (AC=$ENABLE_ON_AC Battery=$ENABLE_ON_BATTERY threshold=${TEMP_THRESHOLD}C critical=${TEMP_CRITICAL}C interval=${POLL_INTERVAL}s)"
        modprobe acpi_call 2>/dev/null

        preflight_checks

        # Clean shutdown: clear bit 0x40 only, do not touch anything else
        trap 'fan2_off; log "Stopped (clean shutdown)"; exit 0' SIGTERM SIGINT

        STATE="off"
        while true; do
            # Fan 1 safety check every iteration
            check_fan1_safety

            RUN=false
            if is_on_ac && [ "$ENABLE_ON_AC" = true ]; then RUN=true
            elif ! is_on_ac && [ "$ENABLE_ON_BATTERY" = true ]; then RUN=true; fi

            TEMP=$(get_cpu_temp)

            # Critical temperature check
            if [ "$TEMP" -ge "$TEMP_CRITICAL" ]; then
                fan1_rpm=$(get_fan1_rpm)
                if [ "$fan1_rpm" != "-1" ] && [ "$fan1_rpm" -lt "$FAN1_MIN_RPM" ]; then
                    log_err "CRITICAL: ${TEMP}C with fan 1 at ${fan1_rpm} RPM — emergency stop"
                    fan2_off
                    exit 1
                fi
            fi

            if [ "$RUN" = true ] && [ "$TEMP" -ge "$TEMP_THRESHOLD" ]; then
                [ "$STATE" = "off" ] && { fan2_on; STATE="on"; }
            else
                [ "$STATE" = "on" ] && { fan2_off; STATE="off"; }
            fi
            sleep "$POLL_INTERVAL"
        done ;;
    *)
        echo "Usage: $0 {on|off|status|daemon}"
        exit 1 ;;
esac
SCRIPT
sudo chmod 755 /usr/local/bin/asus-fan2-ctrl

# 4. Install systemd service
echo "[4/5] Installing systemd service..."
sudo tee /etc/systemd/system/asus-fan2.service > /dev/null << 'SERVICE'
[Unit]
Description=ASUS UX510 Fan 2 Controller
After=multi-user.target
ConditionPathExists=/proc/acpi/call

[Service]
Type=simple
ExecStartPre=/sbin/modprobe acpi_call
ExecStart=/usr/local/bin/asus-fan2-ctrl daemon
ExecStop=/usr/local/bin/asus-fan2-ctrl off
Restart=on-failure
RestartSec=10
StartLimitBurst=3
StartLimitIntervalSec=60

[Install]
WantedBy=multi-user.target
SERVICE

# 5. Enable and start
echo "[5/5] Enabling and starting service..."
sudo systemctl daemon-reload
sudo systemctl enable asus-fan2
sudo systemctl start asus-fan2

echo ""
echo "=== Installation complete! ==="
echo ""
echo "Commands:"
echo "  sudo asus-fan2-ctrl status              - Check status"
echo "  sudo asus-fan2-ctrl on                   - Force fan 2 on"
echo "  sudo asus-fan2-ctrl off                  - Force fan 2 off"
echo "  sudo nano /etc/asus-fan2/config          - Edit config"
echo "  sudo systemctl restart asus-fan2         - Apply config"
echo "  journalctl -u asus-fan2 -f               - View logs"
echo ""
echo "Uninstall:"
echo "  sudo systemctl stop asus-fan2 && sudo systemctl disable asus-fan2"
echo "  sudo rm /usr/local/bin/asus-fan2-ctrl /etc/systemd/system/asus-fan2.service"
echo "  sudo rm -rf /etc/asus-fan2"
