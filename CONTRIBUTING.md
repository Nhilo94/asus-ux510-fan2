# Contributing

## Adding support for your ASUS model

If your ASUS laptop has a second fan that doesn't work under Linux, follow these steps:

### 1. Verify the hardware

Open the laptop or look at teardown photos to confirm two physical fans exist and are connected.

### 2. Check if the ACPI methods exist

```bash
sudo apt install acpi-call-dkms acpica-tools
sudo modprobe acpi_call

# Decompile DSDT
sudo cat /sys/firmware/acpi/tables/DSDT > /tmp/dsdt.dat
iasl -d /tmp/dsdt.dat

# Look for dual-fan references
grep -n "RFAN\|SFNV\|TACH.*One\|ST83\|ST84" /tmp/dsdt.dsl
grep -n "WRAM\|RRAM" /tmp/dsdt.dsl
```

### 3. Find the fan 2 register

```bash
# Check presence flag (your address may differ from 0xF920)
echo '\_SB.PCI0.LPCB.EC0.RRAM 0xF920' | sudo tee /proc/acpi/call
sudo cat /proc/acpi/call

# Check fan 2 status
echo '\_SB.PCI0.LPCB.EC0.ST83 1' | sudo tee /proc/acpi/call
sudo cat /proc/acpi/call
```

### 4. Find the control register

Search the DSDT for `WRAM` calls near fan-related code. Common patterns:
- `WRAM(0xF921, ...)` — Fan 1 control
- `WRAM(0xF922, ...)` — Fan 2 control
- Bit `0x40` toggle for on/off

### 5. Test and submit

Once you confirm the fan starts, open an issue or PR with:
- Your model name (from `sudo dmidecode -t 1`)
- The ACPI path (e.g., `\_SB.PCI0.LPCB.EC0`)
- The register addresses (presence, status, control)
- The control bit value
- Your kernel version and distro
