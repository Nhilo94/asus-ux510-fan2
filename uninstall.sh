#!/bin/bash
set -e
echo "=== Uninstalling ASUS UX510 Fan 2 Controller ==="

sudo systemctl stop asus-fan2 2>/dev/null || true
sudo systemctl disable asus-fan2 2>/dev/null || true
sudo rm -f /usr/local/bin/asus-fan2-ctrl
sudo rm -f /etc/systemd/system/asus-fan2.service
sudo rm -rf /etc/asus-fan2
sudo rm -f /etc/modules-load.d/acpi_call.conf
sudo systemctl daemon-reload

echo "=== Uninstall complete ==="
