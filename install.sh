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

# Enable fan 2 when on battery (false = save power)
ENABLE_ON_BATTERY=false

# CPU temperature threshold to activate fan 2 (Celsius)
TEMP_THRESHOLD=70

# Hysteresis: fan 2 turns OFF only when temp drops this many degrees below threshold
# Prevents oscillation when temperature bounces around the threshold
TEMP_HYSTERESIS=10

# Poll interval in seconds (base — adaptive polling reduces this when temp is near threshold)
POLL_INTERVAL=20

# Trend activation: if temperature is rising faster than this many °C per sample,
# activate fan 2 proactively before hitting the threshold (0 = disabled)
TREND_RATE=3

# Hwmon paths (leave empty for auto-detection)
FAN1_HWMON=""
CPU_TEMP_HWMON=""
CONFIG

# 3. Install control script
echo "[3/5] Installing control script..."
sudo tee /usr/local/bin/asus-fan2-ctrl > /dev/null << 'SCRIPT'
#!/bin/bash
# ASUS UX510 Fan 2 Controller
# Controls the second (GPU) fan via ACPI WRAM 0xF922 (bit 0x40)
# Reacts to both CPU and GPU temperatures with hysteresis and adaptive polling.
#
# SAFETY: Only writes to register 0xF922 (bit 0x40).
#         Never touches fan 1 registers (0xF921, 0x97, 0xA0, 0xA6).

CONFIG_FILE="/etc/asus-fan2/config"
ACPI_CALL="/proc/acpi/call"
LOG_TAG="asus-fan2"

# Defaults (overridden by config)
ENABLE_ON_AC=true
ENABLE_ON_BATTERY=false
POLL_INTERVAL=20
TEMP_THRESHOLD=75
TEMP_HYSTERESIS=10
TREND_RATE=3
FAN1_HWMON=""
CPU_TEMP_HWMON=""

[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

# ── Logging ──────────────────────────────────────────────────────────────

log() {
    logger -t "$LOG_TAG" "$1"
    echo "$(date '+%H:%M:%S'): $1"
}

log_err() {
    logger -t "$LOG_TAG" -p user.err "$1"
    echo "$(date '+%H:%M:%S'): ERROR: $1" >&2
}

# ── ACPI interface ───────────────────────────────────────────────────────

acpi_call() {
    echo "$1" > "$ACPI_CALL"
    tr -d '\0' < "$ACPI_CALL" 2>/dev/null
}

# ── Hardware detection ───────────────────────────────────────────────────

find_hwmon() {
    local target_name="$1"
    for h in /sys/class/hwmon/hwmon*; do
        [ "$(cat "$h/name" 2>/dev/null)" = "$target_name" ] && echo "$h" && return 0
    done
    return 1
}

detect_hwmon_paths() {
    if [ -z "$FAN1_HWMON" ] || [ ! -f "$FAN1_HWMON" ]; then
        local asus_hwmon
        asus_hwmon=$(find_hwmon "asus") || true
        if [ -n "$asus_hwmon" ] && [ -f "$asus_hwmon/fan1_input" ]; then
            FAN1_HWMON="$asus_hwmon/fan1_input"
            log "Detected fan1 hwmon: $FAN1_HWMON"
        else
            FAN1_HWMON=""
        fi
    fi

    if [ -z "$CPU_TEMP_HWMON" ] || [ ! -f "$CPU_TEMP_HWMON" ]; then
        local coretemp_hwmon
        coretemp_hwmon=$(find_hwmon "coretemp") || true
        if [ -n "$coretemp_hwmon" ] && [ -f "$coretemp_hwmon/temp1_input" ]; then
            CPU_TEMP_HWMON="$coretemp_hwmon/temp1_input"
            log "Detected CPU temp hwmon: $CPU_TEMP_HWMON"
        else
            log_err "CPU temp hwmon not found — cannot operate safely"
            exit 1
        fi
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

# Returns GPU temp in °C, or -1 if unavailable
get_gpu_temp() {
    if command -v nvidia-smi &>/dev/null; then
        local t
        t=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader 2>/dev/null | tr -d ' ')
        if [[ "$t" =~ ^[0-9]+$ ]]; then
            echo "$t"
            return 0
        fi
    fi
    echo "-1"
}

get_fan1_rpm() {
    if [ -n "$FAN1_HWMON" ] && [ -f "$FAN1_HWMON" ]; then
        cat "$FAN1_HWMON" 2>/dev/null || echo "0"
    else
        echo "-1"
    fi
}

# ── Fan 2 control (ONLY register 0xF922, bit 0x40) ──────────────────────

fan2_present() {
    local val
    val=$(acpi_call '\_SB.PCI0.LPCB.EC0.ST83 1')
    [ -n "$val" ] && [ "$val" != "Error" ]
}

fan2_read_reg() {
    acpi_call '\_SB.PCI0.LPCB.EC0.RRAM 0xF922'
}

fan2_on() {
    local cur
    cur=$(fan2_read_reg | sed 's/^0x//')
    cur=$((16#${cur:-0}))
    local nv=$(( cur | 0x40 ))
    acpi_call "\_SB.PCI0.LPCB.EC0.WRAM 0xF922 $nv" > /dev/null
    log "Fan 2 ON (reg=0x$(printf '%02x' $nv))"
}

fan2_off() {
    local cur
    cur=$(fan2_read_reg | sed 's/^0x//')
    cur=$((16#${cur:-0}))
    local nv=$(( cur & ~0x40 ))
    acpi_call "\_SB.PCI0.LPCB.EC0.WRAM 0xF922 $nv" > /dev/null
    log "Fan 2 OFF (reg=0x$(printf '%02x' $nv))"
}

fan2_is_on() {
    local cur
    cur=$(fan2_read_reg | sed 's/^0x//')
    cur=$((16#${cur:-0}))
    [ $(( cur & 0x40 )) -ne 0 ]
}

# Turns fan 2 on and verifies it actually started via ST83
fan2_on_verified() {
    fan2_on
    sleep 2
    local st
    st=$(acpi_call '\_SB.PCI0.LPCB.EC0.ST83 1')
    if [ "$st" = "0x0" ] || [ "$st" = "0" ]; then
        log "Fan 2 did not respond after on command, retrying..."
        fan2_on
    fi
}

# ── Startup checks ──────────────────────────────────────────────────────

preflight_checks() {
    if [ ! -f "$ACPI_CALL" ]; then
        log_err "$ACPI_CALL not found — is acpi_call module loaded?"
        exit 1
    fi

    if ! fan2_present; then
        log_err "Fan 2 not detected (ST83 1 returned no valid response)"
        exit 1
    fi
    log "Fan 2 presence confirmed (ST83=$(acpi_call '\_SB.PCI0.LPCB.EC0.ST83 1'))"

    local init_val
    init_val=$(fan2_read_reg)
    log "Initial 0xF922 value: $init_val"

    detect_hwmon_paths

    local fan1_rpm
    fan1_rpm=$(get_fan1_rpm)
    [ "$fan1_rpm" != "-1" ] && log "Fan 1 RPM at startup: $fan1_rpm"

    local gpu_t
    gpu_t=$(get_gpu_temp)
    [ "$gpu_t" != "-1" ] && log "GPU temp at startup: ${gpu_t}°C"
}

# ── Status display ───────────────────────────────────────────────────────

fan2_status() {
    detect_hwmon_paths 2>/dev/null

    local cpu_t gpu_t fan1_rpm ac
    cpu_t=$(get_cpu_temp)
    gpu_t=$(get_gpu_temp)
    fan1_rpm=$(get_fan1_rpm)
    ac=$(is_on_ac && echo "yes" || echo "no")

    echo "=== ASUS UX510 Fan 2 (CPU fan) Status ==="
    echo "AC Power          : $ac"
    echo "CPU Temp          : ${cpu_t}°C  (ON>=${TEMP_THRESHOLD}°C, OFF<$(( TEMP_THRESHOLD - TEMP_HYSTERESIS ))°C)"
    [ "$gpu_t" != "-1" ] && echo "GPU Temp          : ${gpu_t}°C  [info only]"
    [ "$fan1_rpm" != "-1" ] && echo "GPU fan (fan1) RPM: $fan1_rpm  [BIOS-managed]"
    echo "CPU fan (fan2)    : $(fan2_is_on && echo "ON" || echo "OFF")"
    echo "Fan 2 ST83        : $(acpi_call '\_SB.PCI0.LPCB.EC0.ST83 1')"
    echo "Fan 2 Reg F922    : $(fan2_read_reg)"
    echo "Config            : AC=$ENABLE_ON_AC  Battery=$ENABLE_ON_BATTERY  threshold=${TEMP_THRESHOLD}°C  hyst=${TEMP_HYSTERESIS}°C"
}

# ── Adaptive poll interval ────────────────────────────────────────────────

# Returns poll delay in seconds based on CPU proximity to threshold
adaptive_poll() {
    local cpu_t="$1" fan_state="$3"
    local dist
    dist=$(( TEMP_THRESHOLD - cpu_t ))
    [ $dist -lt 0 ] && dist=0

    if [ $dist -le 5 ] || [ "$fan_state" = "on" ]; then
        echo 5      # near threshold or running: check fast
    elif [ $dist -le 15 ]; then
        echo 10     # warming up
    else
        echo "$POLL_INTERVAL"  # cold: use configured interval
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────

case "${1:-daemon}" in
    on)      fan2_on ;;
    off)     fan2_off ;;
    status)  fan2_status ;;

    daemon)
        log "Starting daemon (AC=$ENABLE_ON_AC Battery=$ENABLE_ON_BATTERY cpu_thresh=${TEMP_THRESHOLD}°C hyst=${TEMP_HYSTERESIS}°C interval=${POLL_INTERVAL}s trend_rate=${TREND_RATE}°C/sample)"
        modprobe acpi_call 2>/dev/null

        preflight_checks

        trap 'fan2_off; log "Stopped (clean shutdown)"; exit 0' SIGTERM SIGINT

        STATE="off"
        PREV_CPU=0
        OFF_THRESH=$(( TEMP_THRESHOLD - TEMP_HYSTERESIS ))

        while true; do
            RUN=false
            if is_on_ac && [ "$ENABLE_ON_AC" = true ]; then RUN=true
            elif ! is_on_ac && [ "$ENABLE_ON_BATTERY" = true ]; then RUN=true; fi

            CPU_TEMP=$(get_cpu_temp)

            # Trend detection: rate of rise since last sample
            CPU_TREND=$(( CPU_TEMP - PREV_CPU ))
            TREND_ACTIVE=false
            if [ "$TREND_RATE" -gt 0 ] && [ $CPU_TREND -ge "$TREND_RATE" ]; then
                TREND_ACTIVE=true
            fi

            # Decision: activate if above threshold or rising fast; turn off below hysteresis floor
            SHOULD_ON=false
            if [ "$RUN" = true ]; then
                if [ "$CPU_TEMP" -ge "$TEMP_THRESHOLD" ]; then SHOULD_ON=true; fi
                if [ "$TREND_ACTIVE" = true ]; then SHOULD_ON=true; fi
                # Keep fan on until temp drops below hysteresis floor
                if [ "$STATE" = "on" ] && [ "$CPU_TEMP" -ge "$OFF_THRESH" ]; then SHOULD_ON=true; fi
            fi

            if [ "$SHOULD_ON" = true ] && [ "$STATE" = "off" ]; then
                fan2_on_verified
                STATE="on"
            elif [ "$SHOULD_ON" = false ] && [ "$STATE" = "on" ]; then
                fan2_off
                STATE="off"
            fi

            PREV_CPU=$CPU_TEMP

            DELAY=$(adaptive_poll "$CPU_TEMP" "" "$STATE")
            sleep "$DELAY"
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
RestartSec=10s
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
SERVICE

# 5. Enable and start
echo "[5/5] Enabling and starting service..."
sudo systemctl daemon-reload
sudo systemctl enable asus-fan2
sudo systemctl restart asus-fan2

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
