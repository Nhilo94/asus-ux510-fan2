#!/bin/bash
# ============================================================================
# publish.sh — Publish asus-ux510-fan2 to GitHub, create PR and issues
#
# Prerequisites:
#   - gh CLI installed: sudo apt install gh
#   - gh authenticated: gh auth login
#
# Usage: cd ~/dev/asus-ux510-fan2-repo && bash publish.sh
# ============================================================================

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
GH_USER="nhilo94"
REPO_NAME="asus-ux510-fan2"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
fail() { echo -e "${RED}[✗]${NC} $1"; }
info() { echo -e "${YELLOW}[→]${NC} $1"; }

# --------------------------------------------------------------------------
# Pre-flight checks
# --------------------------------------------------------------------------
info "Checking prerequisites..."

if ! command -v gh &>/dev/null; then
    fail "gh CLI not found. Install with: sudo apt install gh"
    exit 1
fi

if ! gh auth status &>/dev/null; then
    fail "gh not authenticated. Run: gh auth login"
    exit 1
fi

ok "gh CLI ready"

cd "$REPO_DIR"

if [ ! -d .git ]; then
    fail "Not a git repository. Run git init first."
    exit 1
fi

ok "Git repo found at $REPO_DIR"

# --------------------------------------------------------------------------
# ÉTAPE 4: Create GitHub repo and push
# --------------------------------------------------------------------------
echo ""
echo "=========================================="
echo " ÉTAPE 4: Create GitHub repo and push"
echo "=========================================="

if gh repo view "$GH_USER/$REPO_NAME" &>/dev/null; then
    info "Repo $GH_USER/$REPO_NAME already exists, skipping creation"
else
    info "Creating public repo $GH_USER/$REPO_NAME..."
    gh repo create "$REPO_NAME" --public --source=. --remote=origin \
        --description "Enable the hidden second (GPU) fan on ASUS UX510UWK under Linux via ACPI acpi_call"
    ok "Repo created"
fi

# Ensure origin is set
if ! git remote get-url origin &>/dev/null; then
    git remote add origin "https://github.com/$GH_USER/$REPO_NAME.git"
fi

info "Pushing to origin/main..."
git push -u origin main
ok "Code pushed"

info "Adding topics..."
gh repo edit --add-topic linux,asus,fan-control,acpi,debian,thermal,laptop,kernel
ok "Topics added"

REPO_URL="https://github.com/$GH_USER/$REPO_NAME"
ok "Repo live at $REPO_URL"

# --------------------------------------------------------------------------
# ÉTAPE 5: Fork nbfc-linux and create PR
# --------------------------------------------------------------------------
echo ""
echo "=========================================="
echo " ÉTAPE 5: Fork nbfc-linux and create PR"
echo "=========================================="

NBFC_DIR="$REPO_DIR/../nbfc-linux"

if [ -d "$NBFC_DIR" ]; then
    info "nbfc-linux directory already exists at $NBFC_DIR"
    cd "$NBFC_DIR"
    git fetch origin 2>/dev/null || true
else
    info "Forking and cloning nbfc-linux/nbfc-linux..."
    cd "$REPO_DIR/.."
    gh repo fork nbfc-linux/nbfc-linux --clone -- nbfc-linux
    cd "$NBFC_DIR"
    ok "Fork cloned"
fi

# Create branch (or switch to it if it exists)
if git show-ref --verify --quiet refs/heads/add-ux510uwk-config; then
    info "Branch add-ux510uwk-config already exists, switching to it"
    git checkout add-ux510uwk-config
else
    git checkout -b add-ux510uwk-config
    ok "Branch add-ux510uwk-config created"
fi

# Copy config file
CONFIG_SRC="$REPO_DIR/contrib/nbfc-linux/Asus Zenbook UX510UWK.json"
CONFIG_DST="share/nbfc/configs/Asus Zenbook UX510UWK.json"

if [ -f "$CONFIG_DST" ]; then
    info "Config file already exists in nbfc-linux, overwriting"
fi

cp "$CONFIG_SRC" "$CONFIG_DST"
ok "Config file copied"

# Commit (skip if nothing to commit)
git add "$CONFIG_DST"
if git diff --cached --quiet; then
    info "Nothing new to commit (config already committed)"
else
    git commit -m "Add Asus Zenbook UX510UWK fan config"
    ok "Committed"
fi

info "Pushing branch to fork..."
git push -u origin add-ux510uwk-config
ok "Branch pushed"

# Create PR (check if one already exists)
EXISTING_PR=$(gh pr list --repo nbfc-linux/nbfc-linux --head "$GH_USER:add-ux510uwk-config" --json number --jq '.[0].number' 2>/dev/null || true)

if [ -n "$EXISTING_PR" ]; then
    info "PR #$EXISTING_PR already exists"
    PR_URL="https://github.com/nbfc-linux/nbfc-linux/pull/$EXISTING_PR"
else
    info "Creating PR on nbfc-linux/nbfc-linux..."
    PR_URL=$(gh pr create --repo nbfc-linux/nbfc-linux \
        --title "Add Asus Zenbook UX510UWK fan config" \
        --body "$(cat <<'PREOF'
## New device config: ASUS Zenbook UX510UWK

**Hardware:** ASUS UX510UWK (i7-7500U, GTX 960M, dual fan)
**Kernel:** 6.1.0-44-amd64 (Debian 12 Bookworm)
**EC access:** dev_port

### Fan 1 (CPU) — this config
- Register: 0x97 (decimal 151)
- Speed range: 0–8 (0=off, 8=max, 9=auto reset)
- Based on UX530U profile, tested and working
- RegisterWriteConfiguration at 0xA0 for manual mode

### Fan 2 (GPU) — NOT included (requires acpi_call)
The GPU fan uses extended EC register WRAM(0xF922) with bit 0x40 toggle.
This is beyond nbfc's standard EC range (0x00-0xFF).
Standalone tool: https://github.com/nhilo94/asus-ux510-fan2

### Testing
- Tested on Debian 12 Bookworm, kernel 6.1.0-44-amd64
- Fan 1 responds correctly to all speed values 0-8
- Temperature thresholds tuned for daily use
PREOF
)")
    ok "PR created"
fi
ok "PR: $PR_URL"

# --------------------------------------------------------------------------
# ÉTAPE 6: Open issues
# --------------------------------------------------------------------------
echo ""
echo "=========================================="
echo " ÉTAPE 6: Open issues"
echo "=========================================="

# Issue on nbfc-linux
info "Creating issue on nbfc-linux/nbfc-linux..."
EXISTING_NBFC_ISSUE=$(gh issue list --repo nbfc-linux/nbfc-linux --author "$GH_USER" --search "ACPI extended EC registers" --json number --jq '.[0].number' 2>/dev/null || true)

if [ -n "$EXISTING_NBFC_ISSUE" ]; then
    info "Issue #$EXISTING_NBFC_ISSUE already exists on nbfc-linux"
    NBFC_ISSUE_URL="https://github.com/nbfc-linux/nbfc-linux/issues/$EXISTING_NBFC_ISSUE"
else
    NBFC_ISSUE_URL=$(gh issue create --repo nbfc-linux/nbfc-linux \
        --title "Feature request: Support for ACPI extended EC registers (WRAM/RRAM) for dual-fan ASUS laptops" \
        --body-file "$REPO_DIR/contrib/nbfc-linux/ISSUE_TEMPLATE.md")
    ok "nbfc-linux issue created"
fi
ok "nbfc-linux issue: $NBFC_ISSUE_URL"

# Issue on asus-fan-control
info "Creating issue on dominiksalvet/asus-fan-control..."
EXISTING_AFC_ISSUE=$(gh issue list --repo dominiksalvet/asus-fan-control --author "$GH_USER" --search "UX510UWK" --json number --jq '.[0].number' 2>/dev/null || true)

if [ -n "$EXISTING_AFC_ISSUE" ]; then
    info "Issue #$EXISTING_AFC_ISSUE already exists on asus-fan-control"
    AFC_ISSUE_URL="https://github.com/dominiksalvet/asus-fan-control/issues/$EXISTING_AFC_ISSUE"
else
    AFC_ISSUE_URL=$(gh issue create --repo dominiksalvet/asus-fan-control \
        --title "Add support for ASUS UX510UWK (dual fan via WRAM 0xF922)" \
        --body-file "$REPO_DIR/contrib/asus-fan-control/ISSUE_TEMPLATE.md")
    ok "asus-fan-control issue created"
fi
ok "asus-fan-control issue: $AFC_ISSUE_URL"

# --------------------------------------------------------------------------
# ÉTAPE 7: Summary
# --------------------------------------------------------------------------
echo ""
echo "=========================================="
echo -e " ${GREEN}ALL DONE — Summary${NC}"
echo "=========================================="
echo ""
echo "  Repo:               $REPO_URL"
echo "  PR nbfc-linux:      $PR_URL"
echo "  Issue nbfc-linux:   $NBFC_ISSUE_URL"
echo "  Issue asus-fan-ctrl: $AFC_ISSUE_URL"
echo ""
