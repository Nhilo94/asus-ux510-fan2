## New device: ASUS Zenbook UX510UWK

**Hardware:** ASUS UX510UWK (i7-7500U, GTX 960M, dual fan)
**Kernel:** 6.1.0-44-amd64 (Debian 12 Bookworm)
**EC access:** dev_port (ec_sys not available in this kernel)

### Fan 1 (CPU)
- Register: `0x97` (decimal 151)
- Speed range: 0–8 (0=off, 8=max)
- Reset value: 9 (auto mode)
- Works with UX530U profile as base

### Fan 2 (GPU) — NOT controllable via standard EC
- Requires ACPI extended EC via `acpi_call` module
- Presence flag: `RRAM(0xF920) & 0x02`
- Control: `WRAM(0xF922, val | 0x40)` to enable, `WRAM(0xF922, val & ~0x40)` to disable
- Status: `ST83(1)` → `0xFF` = active, `0x0` = off

### Config attached
Fan 1 config JSON attached. Fan 2 cannot be controlled by nbfc without adding acpi_call/WRAM support.

### Related
- Standalone fan 2 tool: https://github.com/nhilo94/asus-ux510-fan2
- DSDT analysis confirms `RFAN(0)` / `RFAN(1)` thermal zone methods
