#!/bin/bash
set -e

echo "=== Setup GitHub Repository ==="
echo ""

# Check git
if ! command -v git &>/dev/null; then
    echo "Installing git..."
    sudo apt install -y git
fi

# Configure git if needed
if [ -z "$(git config --global user.name)" ]; then
    read -p "GitHub username: " GH_USER
    read -p "GitHub email: " GH_EMAIL
    git config --global user.name "$GH_USER"
    git config --global user.email "$GH_EMAIL"
fi

GH_USER=$(git config --global user.name)

# Update URLs in files
echo "Updating repo URLs..."
find . -type f -name "*.md" -exec sed -i "s|nhilo94|$GH_USER|g" {} +

# Init repo
git init
git add .
git commit -m "Initial release: ASUS UX510UWK dual fan controller for Linux

- Enables hidden GPU fan via ACPI WRAM(0xF922) bit 0x40 toggle
- systemd service with AC/battery awareness
- Temperature-based auto control
- Reverse-engineered from DSDT ACPI tables
- Tested: CPU temp 88°C → 70°C with both fans active"

echo ""
echo "=== Local repo ready! ==="
echo ""
echo "Next steps:"
echo "1. Create a repo on GitHub named 'asus-ux510-fan2'"
echo "   → https://github.com/new"
echo ""
echo "2. Push:"
echo "   git remote add origin https://github.com/$GH_USER/asus-ux510-fan2.git"
echo "   git branch -M main"
echo "   git push -u origin main"
echo ""
echo "3. Open issues on existing projects (templates in contrib/):"
echo "   → https://github.com/nbfc-linux/nbfc-linux/issues/new"
echo "   → https://github.com/dominiksalvet/asus-fan-control/issues/new"
