#!/bin/bash
set -e

echo "=== ASUS UX510 Fan 2 Controller - Installation ==="

# 1. Ensure acpi_call is installed and loaded
echo "[1/5] Installing dependencies..."
sudo apt install -y acpi-call-dkms linux-headers-$(uname -r) 2>/dev/null
sudo modprobe acpi_call 2>/dev/null
echo "acpi_call" | sudo tee /etc/modules-load.d/acpi_call.conf > /dev/null

# 2. Create config
echo "[2/5] Creating config..."
sudo mkdir -p /etc/asus-fan2
sudo tee /etc/asus-fan2/config > /dev/null << 'CONFIG'
# ASUS UX510 Fan 2 Configuration
# Edit then restart: sudo systemctl restart asus-fan2

# Enable fan 2 when on AC power
ENABLE_ON_AC=true

# Enable fan 2 when on battery
ENABLE_ON_BATTERY=false

# Temperature threshold to activate fan 2 (Celsius)
TEMP_THRESHOLD=55

# Poll interval in seconds
POLL_INTERVAL=10
CONFIG

# 3. Install control script
echo "[3/5] Installing control script..."
sudo tee /usr/local/bin/asus-fan2-ctrl > /dev/null << 'SCRIPT'
#!/bin/bash
# ASUS UX510 Fan 2 Controller
# Controls the second fan via ACPI WRAM 0xF922 (bit 0x40 toggle)

CONFIG_FILE="/etc/asus-fan2/config"
ACPI_CALL="/proc/acpi/call"
LOG_TAG="asus-fan2"

ENABLE_ON_AC=true
ENABLE_ON_BATTERY=false
POLL_INTERVAL=10
TEMP_THRESHOLD=55

[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

log() {
    logger -t "$LOG_TAG" "$1"
    echo "$(date): $1"
}

acpi_call() {
    echo "$1" > "$ACPI_CALL"
    cat "$ACPI_CALL" 2>/dev/null
}

is_on_ac() {
    local s
    s=$(cat /sys/class/power_supply/AC0/online 2>/dev/null || echo "1")
    [ "$s" = "1" ]
}

get_cpu_temp() {
    local t
    t=$(cat /sys/class/hwmon/hwmon6/temp1_input 2>/dev/null || echo "0")
    echo $((t / 1000))
}

fan2_read_reg() {
    acpi_call "\_SB.PCI0.LPCB.EC0.RRAM 0xF922"
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

fan2_status() {
    echo "=== ASUS UX510 Fan 2 Status ==="
    echo "AC Power       : $(is_on_ac && echo yes || echo no)"
    echo "CPU Temp       : $(get_cpu_temp)°C"
    echo "Fan 2          : $(fan2_is_on && echo ON || echo OFF)"
    echo "Fan 2 ST83     : $(acpi_call '\_SB.PCI0.LPCB.EC0.ST83 1')"
    echo "Fan 2 Reg F922 : $(fan2_read_reg)"
    echo "Config         : AC=$ENABLE_ON_AC  Battery=$ENABLE_ON_BATTERY  Threshold=${TEMP_THRESHOLD}°C"
}

case "${1:-daemon}" in
    on)      fan2_on ;;
    off)     fan2_off ;;
    status)  fan2_status ;;
    daemon)
        log "Starting (AC=$ENABLE_ON_AC Battery=$ENABLE_ON_BATTERY threshold=${TEMP_THRESHOLD}°C interval=${POLL_INTERVAL}s)"
        modprobe acpi_call 2>/dev/null
        trap 'fan2_off; log "Stopped"; exit 0' SIGTERM SIGINT
        STATE="off"
        while true; do
            RUN=false
            if is_on_ac && [ "$ENABLE_ON_AC" = true ]; then RUN=true
            elif ! is_on_ac && [ "$ENABLE_ON_BATTERY" = true ]; then RUN=true; fi
            TEMP=$(get_cpu_temp)
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

[Service]
Type=simple
ExecStart=/usr/local/bin/asus-fan2-ctrl daemon
ExecStop=/usr/local/bin/asus-fan2-ctrl off
Restart=on-failure
RestartSec=5

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
