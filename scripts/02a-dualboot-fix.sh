#!/bin/bash

# ==============================================================================
# Script: 02a-dualboot-fix.sh
# Purpose: Auto-configure for Windows dual-boot and apply advanced GRUB settings.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/00-utils.sh"

check_root

# --- [NEW] GRUB Installation Check ---
# 检测是否存在 grub-mkconfig 命令以及配置文件
# 如果其中任意一个不存在，则认为没安装 GRUB (可能是 systemd-boot 或其他)，直接跳过。
if ! command -v grub-mkconfig &>/dev/null || [ ! -f "/etc/default/grub" ]; then
    warn "GRUB is not detected (command or config missing). Skipping GRUB configuration module."
    exit 0
fi

# --- Helper Functions for /etc/default/grub ---

# Sets a GRUB key-value pair. Handles commented, existing, and new keys.
# Usage: set_grub_value "KEY" "value"
set_grub_value() {
    local key="$1"
    local value="$2"
    local conf_file="/etc/default/grub"
    
    # Use a different delimiter for sed to handle path values
    local escaped_value
    escaped_value=$(printf '%s\n' "$value" | sed 's,[\/&],\\&,g')

    if grep -q -E "^#\s*$key=" "$conf_file"; then
        # Key is commented out, uncomment and set the value
        exe sed -i -E "s,^#\s*$key=.*,$key=\"$escaped_value\"," "$conf_file"
    elif grep -q -E "^$key=" "$conf_file"; then
        # Key exists, just update the value
        exe sed -i -E "s,^$key=.*,$key=\"$escaped_value\"," "$conf_file"
    else
        # Key doesn't exist, append it
        log "Appending new key: $key"
        echo "$key=\"$escaped_value\"" >> "$conf_file"
    fi
}

# Adds or removes a kernel parameter from GRUB_CMDLINE_LINUX_DEFAULT
# Usage: manage_kernel_param "add" "loglevel=5"
# Usage: manage_kernel_param "remove" "quiet"
manage_kernel_param() {
    local action="$1"
    local param="$2"
    local conf_file="/etc/default/grub"
    
    local line
    line=$(grep "^GRUB_CMDLINE_LINUX_DEFAULT=" "$conf_file")
    
    local params
    params=$(echo "$line" | sed -e 's/GRUB_CMDLINE_LINUX_DEFAULT=//' -e 's/"//g')

    # Check if param contains '=', if so, we match the key part for removal/existence check
    local param_key
    if [[ "$param" == *"="* ]]; then
        param_key="${param%%=*}"
    else
        param_key="$param"
    fi

    # Remove any existing instance of the parameter (or its key)
    params=$(echo "$params" | sed -E "s/\b${param_key}(=[^ ]*)?\b//g")

    if [ "$action" == "add" ]; then
        # Add the new parameter
        params="$params $param"
    fi

    # Clean up extra spaces and update the file
    params=$(echo "$params" | tr -s ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    exe sed -i "s,^GRUB_CMDLINE_LINUX_DEFAULT=.*,GRUB_CMDLINE_LINUX_DEFAULT=\"$params\"," "$conf_file"
}

# --- Main Script ---

section "Phase 2A" "Advanced GRUB & Dual-Boot Configuration"

# (Original file check removed here since we checked at the very top)

# ------------------------------------------------------------------------------
# 1. Detect Windows
# ------------------------------------------------------------------------------
section "Step 1/3" "System Analysis"

log "Installing dual-boot detection tools (os-prober, exfat-utils)..."
exe pacman -S --noconfirm --needed os-prober exfat-utils

log "Scanning for Windows installation..."
WINDOWS_DETECTED=$(os-prober | grep -qi "windows" && echo "true" || echo "false")

if [ "$WINDOWS_DETECTED" != "true" ]; then
    log "No Windows installation detected by os-prober."
    log "Skipping dual-boot specific configurations."
    log "Module 02a completed (Skipped)."
    exit 0
fi

success "Windows installation detected."

# --- Check if already configured ---
OS_PROBER_CONFIGURED=$(grep -q -E '^\s*GRUB_DISABLE_OS_PROBER\s*=\s*(false|"false")' /etc/default/grub && echo "true" || echo "false")

if [ "$OS_PROBER_CONFIGURED" == "true" ]; then
    log "Dual-boot settings (os-prober, RTC) seem to be already configured."
    echo ""
    echo -e "   ${H_YELLOW}>>> It looks like your dual-boot is already set up.${NC}"
    echo ""
fi

log "Applying automatic configurations..."

# ------------------------------------------------------------------------------
# 2. Configure GRUB for Dual-Boot & Advanced Features
# ------------------------------------------------------------------------------
section "Step 2/3" "GRUB Customization"

log "Enabling OS prober to detect Windows..."
set_grub_value "GRUB_DISABLE_OS_PROBER" "false"

log "Enabling GRUB to remember the last selected entry..."
set_grub_value "GRUB_DEFAULT" "saved"
set_grub_value "GRUB_SAVEDEFAULT" "true"

log "Configuring kernel boot parameters for detailed logs and performance..."
manage_kernel_param "remove" "quiet"
manage_kernel_param "remove" "splash"
manage_kernel_param "add" "loglevel=5"
manage_kernel_param "add" "nowatchdog"

# Use LC_ALL=C to ensure lscpu output is in English for reliable parsing.
CPU_VENDOR=$(LC_ALL=C lscpu | grep "Vendor ID:" | awk '{print $3}')

if [ "$CPU_VENDOR" == "GenuineIntel" ]; then
    log "Intel CPU detected. Disabling iTCO_wdt watchdog."
    manage_kernel_param "add" "modprobe.blacklist=iTCO_wdt"
elif [ "$CPU_VENDOR" == "AuthenticAMD" ]; then
    log "AMD CPU detected. Disabling sp5100_tco watchdog."
    manage_kernel_param "add" "modprobe.blacklist=sp5100_tco"
else
    if [ -n "$CPU_VENDOR" ]; then
        warn "Unrecognized CPU vendor '$CPU_VENDOR'. Skipping CPU-specific watchdog blacklist."
    else
        warn "Could not determine CPU vendor. Skipping CPU-specific watchdog blacklist."
    fi
fi

success "GRUB settings have been updated in /etc/default/grub."

# ------------------------------------------------------------------------------
# 3. Apply Changes
# ------------------------------------------------------------------------------
section "Step 3/3" "Applying Configuration"

log "Regenerating GRUB configuration to apply all changes..."
if exe grub-mkconfig -o /boot/grub/grub.cfg; then
    success "GRUB configuration regenerated successfully."
else
    error "Failed to regenerate GRUB configuration."
    warn "You may need to run 'sudo grub-mkconfig -o /boot/grub/grub.cfg' manually."
fi

log "Module 02a completed."
