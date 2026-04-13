## Feature request: Add ASUS UX510UWK support

### Hardware
- **Model:** ASUS UX510UWK (ASUSTeK COMPUTER INC. UX510UWK 1.0)
- **CPU:** Intel i7-7500U (Kaby Lake)
- **GPU:** NVIDIA GTX 960M
- **Fans:** 2 (CPU + GPU)
- **Kernel:** 6.1.0-44-amd64 (Debian 12)

### ACPI Details

The UX510UWK uses the same WRAM/RRAM infrastructure as other supported models:
- **ACPI path:** `\_SB.PCI0.LPCB.EC0`
- **WRAM method:** Present at DSDT offset 40766
- **RRAM method:** Present at DSDT offset 40744

### Fan 2 Control Registers

| Register | Purpose | Values |
|----------|---------|--------|
| `RRAM(0xF920)` | Fan 2 presence flag | Bit 0x02 set = present |
| `RRAM(0xF922)` | Fan 2 control register | Bit 0x40 = on/off |
| `WRAM(0xF922, val \| 0x40)` | Turn fan 2 ON | |
| `WRAM(0xF922, val & ~0x40)` | Turn fan 2 OFF | |
| `ST83(1)` | Fan 2 status | 0xFF=active, 0x0=off |

### DSDT Evidence

The DSDT thermal zone calls `RFAN(One)` for the second fan, gated by:
```
Local0 = RRAM(0xF920)
If (Local0 & 0x02) {
    Local0 = RRAM(0xF922)
    If (IIA1 == One) { Local1 = (Local0 | 0x40) }
    WRAM(0xF922, Local1)
}
```

### Test Results
- Temperature dropped from 88°C to 70°C after enabling fan 2
- Fan 2 confirmed spinning via audio and ST83 returning 0xFF
- Running stable for 2+ days via systemd daemon

### Standalone tool
Created: https://github.com/nhilo94/asus-ux510-fan2
