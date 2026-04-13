# ASUS UX510UWK — Second Fan Controller for Linux

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

> Enable and control the hidden GPU fan on ASUS UX510UWK/UW/UX under Linux (Debian, Ubuntu, Arch, etc.)

## The Problem

The ASUS UX510UWK has **two physical fans** (CPU + GPU), but Linux only activates the CPU fan.
The GPU fan is controlled via an ACPI extended EC register (`0xF922`, bit `0x40`) that **no existing Linux tool** can reach:

- `asus-nb-wmi` kernel driver: only exposes `fan1` via hwmon
- `nbfc-linux`: limited to standard EC registers (0x00–0xFF)
- `asus-fan-control`: uses WRAM/RRAM but doesn't support UX510
- `asusctl`: targets modern ROG/TUF only

## How It Works

This tool uses the `acpi_call` kernel module to invoke ASUS ACPI methods directly:

| Action | ACPI Method |
|--------|-------------|
| Fan 2 ON | `WRAM(0xF922, current \| 0x40)` |
| Fan 2 OFF | `WRAM(0xF922, current & ~0x40)` |
| Read fan 2 status | `ST83(1)` |
| Check fan 2 present | `RRAM(0xF920) & 0x02` |

These methods were **reverse-engineered from the DSDT ACPI tables** by decompiling `dsdt.dat` and tracing the `RFAN(0)` / `RFAN(1)` thermal zone methods.

## Results

| Metric | Before | After |
|--------|--------|-------|
| CPU Fan (fan1) | 5700 RPM | 4500 RPM (less stressed) |
| GPU Fan (fan2) | **OFF** | **ON** |
| CPU Temperature | **88°C** | **70°C** |

## Compatibility

| Model | CPU | GPU | Kernel | Distro | Status |
|-------|-----|-----|--------|--------|--------|
| UX510UWK | i7-7500U | GTX 960M | 6.1 | Debian 12 | ✅ Tested |

**May also work on:** UX510UW, UX510UX, and other ASUS models with dual fans using WRAM/RRAM extended EC registers. Use `afc-scout` or DSDT decompilation to verify your registers.

## Installation

### One-line install:

```bash
curl -fsSL https://raw.githubusercontent.com/nhilo94/asus-ux510-fan2/main/install.sh | sudo bash
```

### Manual install:

```bash
git clone https://github.com/nhilo94/asus-ux510-fan2.git
cd asus-ux510-fan2
chmod +x install.sh
sudo ./install.sh
```

## Usage

```bash
# Check status
sudo asus-fan2-ctrl status

# Manual control
sudo asus-fan2-ctrl on       # Turn on fan 2
sudo asus-fan2-ctrl off      # Turn off fan 2

# Service management
sudo systemctl status asus-fan2
journalctl -u asus-fan2 -f
```

## Configuration

Edit `/etc/asus-fan2/config`:

```bash
# Enable fan 2 when on AC power
ENABLE_ON_AC=true

# Enable fan 2 when on battery (false = save power)
ENABLE_ON_BATTERY=false

# Temperature threshold to activate fan 2 (Celsius)
TEMP_THRESHOLD=55

# Poll interval in seconds
POLL_INTERVAL=10
```

Apply changes: `sudo systemctl restart asus-fan2`

## Verifying Your Hardware

Before installing, check if your laptop has a hidden second fan:

```bash
# Install acpi_call
sudo apt install acpi-call-dkms
sudo modprobe acpi_call

# Check if fan 2 is present (bit 0x02 should be set)
echo '\_SB.PCI0.LPCB.EC0.RRAM 0xF920' | sudo tee /proc/acpi/call
sudo cat /proc/acpi/call
# Result & 0x02 != 0 means fan 2 exists

# Check fan 2 status (0x0 = OFF, 0xff = active)
echo '\_SB.PCI0.LPCB.EC0.ST83 1' | sudo tee /proc/acpi/call
sudo cat /proc/acpi/call
```

## How I Found the Registers

1. Decompiled the DSDT: `sudo cat /sys/firmware/acpi/tables/DSDT > dsdt.dat && iasl -d dsdt.dat`
2. Found `RFAN(0)` (fan 1) and `RFAN(1)` (fan 2) in the `\_TZ` thermal zone
3. Fan 2 is gated by `RRAM(0xF920) & 0x02` (presence bit)
4. `RFAN` calls `ST83(Arg0)` for status and `TACH(Arg0)` for RPM
5. Fan 2 speed control uses bit `0x40` on register `WRAM(0xF922)`:
   - `IIA1 == One` → `WRAM(0xF922, current | 0x40)` → fan ON
   - `IIA1 == Zero` → `WRAM(0xF922, current & ~0x40)` → fan OFF
6. Verified with `acpi_call` module — fan 2 starts spinning

## Uninstall

```bash
sudo systemctl stop asus-fan2
sudo systemctl disable asus-fan2
sudo rm /usr/local/bin/asus-fan2-ctrl
sudo rm /etc/systemd/system/asus-fan2.service
sudo rm -rf /etc/asus-fan2
sudo rm /etc/modules-load.d/acpi_call.conf
```

## Related Projects

- [nbfc-linux](https://github.com/nbfc-linux/nbfc-linux) — NoteBook FanControl (fan 1 only on UX510)
- [asus-fan-control](https://github.com/dominiksalvet/asus-fan-control) — Uses WRAM/RRAM for other ASUS models
- [asus-fan](https://github.com/daringer/asus-fan) — Deprecated kernel module for dual-fan Zenbooks

## Contributing

If you have a similar ASUS laptop with a hidden second fan:

1. Run the verification steps above
2. Decompile your DSDT and check for `RFAN`, `WRAM`, `RRAM` methods
3. Open an issue with your model, registers, and test results
4. Submit a PR to add your model to the compatibility table

## License

MIT — See [LICENSE](LICENSE)
