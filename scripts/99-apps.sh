#!/bin/bash

# ==============================================================================
# 99-apps.sh - Common Applications (TUI Selection + Batch Yay + Individual Flatpak)
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/00-utils.sh"

check_root

# Ensure whiptail is installed for TUI
if ! command -v whiptail &> /dev/null; then
    echo "Installing dependency: whiptail (libnewt)..."
    pacman -S --noconfirm libnewt >/dev/null 2>&1
fi

trap 'echo -e "\n   ${H_YELLOW}>>> Operation cancelled by user (Ctrl+C). Skipping...${NC}"' INT

# ------------------------------------------------------------------------------
# 0. Identify Target User
# ------------------------------------------------------------------------------
section "Phase 5" "Common Applications (TUI Selection)"

log "Identifying target user..."
DETECTED_USER=$(awk -F: '$3 == 1000 {print $1}' /etc/passwd)

if [ -n "$DETECTED_USER" ]; then
    TARGET_USER="$DETECTED_USER"
else
    read -p "   Please enter the target username: " TARGET_USER
fi
HOME_DIR="/home/$TARGET_USER"
info_kv "Target" "$TARGET_USER"

# ------------------------------------------------------------------------------
# 1. Parse App List & Build TUI Menu
# ------------------------------------------------------------------------------
if [ "$DESKTOP_ENV" == "kde" ]; then
    LIST_FILENAME="kde-common-applist.txt"
else
    LIST_FILENAME="common-applist.txt"
fi
LIST_FILE="$PARENT_DIR/$LIST_FILENAME"

if [ ! -f "$LIST_FILE" ]; then
    warn "File $LIST_FILENAME not found. Skipping."
    trap - INT
    exit 0
fi

# Prepare arrays for Whiptail
# Format: "Tag" "Item Description" "Status(ON/OFF)"
CHOICE_ARGS=()

log "Reading $LIST_FILENAME..."

while IFS= read -r line || [[ -n "$line" ]]; do
    line=$(echo "$line" | tr -d '\r' | xargs)
    # Skip comments and empty lines
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    
    # Determine type for description
    if [[ "$line" == flatpak:* ]]; then
        pkg_name="${line#flatpak:}"
        desc="[Flatpak] $pkg_name"
    else
        pkg_name="$line"
        desc="[Yay/Repo] $pkg_name"
    fi
    
    # Add to checklist options (Default: ON)
    CHOICE_ARGS+=("$line" "$desc" "ON")

done < "$LIST_FILE"

if [ ${#CHOICE_ARGS[@]} -eq 0 ]; then
    warn "No valid applications found in list."
    trap - INT
    exit 0
fi

# ------------------------------------------------------------------------------
# 2. Show TUI & Get User Selection
# ------------------------------------------------------------------------------
echo "Launching selection menu..."

# whiptail returns the selected tags as a string: "pkg1" "flatpak:pkg2" ...
# We direct stderr to stdout (2>&1) and stdout to var to capture the result
SELECTION_STR=$(whiptail --title "App Selection ($DESKTOP_ENV)" \
                         --checklist "Select applications to install:\n(Space: Toggle, Tab: Switch, Enter: Confirm)" \
                         20 80 10 \
                         "${CHOICE_ARGS[@]}" \
                         3>&1 1>&2 2>&3)

exit_status=$?

if [ $exit_status -ne 0 ]; then
    log "User cancelled the selection. Exiting."
    trap - INT
    exit 0
fi

if [ -z "$SELECTION_STR" ]; then
    log "No applications selected."
    trap - INT
    exit 0
fi

# ------------------------------------------------------------------------------
# 3. Categorize Selection (Yay vs Flatpak)
# ------------------------------------------------------------------------------
log "Processing selection..."

YAY_APPS=()
FLATPAK_APPS=()
FAILED_PACKAGES=()

# Remove quotes from the result string (whiptail output format is "item1" "item2")
eval "SELECTED_ARRAY=($SELECTION_STR)"

for item in "${SELECTED_ARRAY[@]}"; do
    if [[ "$item" == flatpak:* ]]; then
        app_id="${item#flatpak:}"
        FLATPAK_APPS+=("$app_id")
    else
        YAY_APPS+=("$item")
    fi
done

info_kv "Scheduled" "Yay: ${#YAY_APPS[@]}" "Flatpak: ${#FLATPAK_APPS[@]}"

# ------------------------------------------------------------------------------
# 4. Install Applications
# ------------------------------------------------------------------------------

# --- A. Install Yay Apps (BATCH MODE) ---
if [ ${#YAY_APPS[@]} -gt 0 ]; then
    section "Step 1/2" "System Packages (Yay - Batch)"
    
    # 1. Filter out already installed packages
    YAY_INSTALL_QUEUE=()
    for pkg in "${YAY_APPS[@]}"; do
        if pacman -Qi "$pkg" &>/dev/null; then
            log "Skipping '$pkg' (Already installed)."
        else
            YAY_INSTALL_QUEUE+=("$pkg")
        fi
    done

    # 2. Execute Batch Install if queue is not empty
    if [ ${#YAY_INSTALL_QUEUE[@]} -gt 0 ]; then
        # Configure NOPASSWD for seamless batch install
        SUDO_TEMP_FILE="/etc/sudoers.d/99_shorin_installer_apps"
        echo "$TARGET_USER ALL=(ALL) NOPASSWD: ALL" > "$SUDO_TEMP_FILE"
        chmod 440 "$SUDO_TEMP_FILE"
        
        BATCH_LIST="${YAY_INSTALL_QUEUE[*]}"
        info_kv "Installing" "${#YAY_INSTALL_QUEUE[@]} packages via Yay"
        
        # Run Yay Batch
        if ! exe runuser -u "$TARGET_USER" -- yay -Syu --noconfirm --needed --answerdiff=None --answerclean=None $BATCH_LIST; then
            error "Yay batch installation failed."
            # Since it's batch, if it fails, we mark the whole queue as potentially failed
            for pkg in "${YAY_INSTALL_QUEUE[@]}"; do
                FAILED_PACKAGES+=("yay-batch-fail:$pkg")
            done
        else
            success "Yay batch installation completed."
        fi
        
        rm -f "$SUDO_TEMP_FILE"
    else
        log "All selected Yay packages are already installed."
    fi
fi

# --- B. Install Flatpak Apps (INDIVIDUAL MODE) ---
if [ ${#FLATPAK_APPS[@]} -gt 0 ]; then
    section "Step 2/2" "Flatpak Packages (Individual)"
    
    for app in "${FLATPAK_APPS[@]}"; do
        # 1. Check if installed
        if flatpak info "$app" &>/dev/null; then
            log "Skipping '$app' (Already installed)."
            continue
        fi

        # 2. Install Individually
        log "Installing Flatpak: $app ..."
        if ! exe flatpak install -y flathub "$app"; then
            error "Failed to install: $app"
            FAILED_PACKAGES+=("flatpak:$app")
        else
            success "Installed $app"
        fi
    done
fi

# ------------------------------------------------------------------------------
# 5. Generate Failure Report
# ------------------------------------------------------------------------------
if [ ${#FAILED_PACKAGES[@]} -gt 0 ]; then
    DOCS_DIR="$HOME_DIR/Documents"
    REPORT_FILE="$DOCS_DIR/安装失败的软件.txt"
    
    if [ ! -d "$DOCS_DIR" ]; then runuser -u "$TARGET_USER" -- mkdir -p "$DOCS_DIR"; fi
    
    # Append to report
    echo -e "\n--- Phase 5 (Common Apps - $DESKTOP_ENV) Failures [$(date)] ---" >> "$REPORT_FILE"
    printf "%s\n" "${FAILED_PACKAGES[@]}" >> "$REPORT_FILE"
    chown "$TARGET_USER:$TARGET_USER" "$REPORT_FILE"
    
    warn "Some applications failed to install. List saved to:"
    echo -e "   ${BOLD}$REPORT_FILE${NC}"
else
    success "All scheduled applications processed."
fi

# ------------------------------------------------------------------------------
# 6. Steam Locale Fix
# ------------------------------------------------------------------------------
section "Post-Install" "Game Environment Tweaks"

STEAM_desktop_modified=false

# Method 1: Native Steam
NATIVE_DESKTOP="/usr/share/applications/steam.desktop"
if [ -f "$NATIVE_DESKTOP" ]; then
    log "Checking Native Steam..."
    if ! grep -q "env LANG=zh_CN.UTF-8" "$NATIVE_DESKTOP"; then
        exe sed -i 's|^Exec=/usr/bin/steam|Exec=env LANG=zh_CN.UTF-8 /usr/bin/steam|' "$NATIVE_DESKTOP"
        exe sed -i 's|^Exec=steam|Exec=env LANG=zh_CN.UTF-8 steam|' "$NATIVE_DESKTOP"
        success "Patched Native Steam .desktop."
        STEAM_desktop_modified=true
    else
        log "Native Steam already patched."
    fi
fi

# Method 2: Flatpak Steam
# Re-check installed flatpaks to see if Steam is present
if flatpak list | grep -q "com.valvesoftware.Steam"; then
    log "Checking Flatpak Steam..."
    exe flatpak override --env=LANG=zh_CN.UTF-8 com.valvesoftware.Steam
    success "Applied Flatpak Steam override."
    STEAM_desktop_modified=true
fi

if [ "$STEAM_desktop_modified" = false ]; then
    log "Steam not found or already configured. Skipping fix."
fi

# Reset Trap
trap - INT

log "Module 99-apps completed."