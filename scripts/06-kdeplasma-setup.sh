#!/bin/bash

# ==============================================================================
# 06-kdeplasma-setup.sh - KDE Plasma Setup (Visual Enhanced)
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/00-utils.sh"

DEBUG=${DEBUG:-0}
CN_MIRROR=${CN_MIRROR:-0}

check_root

# --- Helper: Local Fallback ---
install_local_fallback() {
    local pkg_name="$1"
    local search_dir="$PARENT_DIR/compiled/$pkg_name"
    if [ ! -d "$search_dir" ]; then return 1; fi
    local pkg_file=$(find "$search_dir" -maxdepth 1 -name "*.pkg.tar.zst" | head -n 1)
    if [ -f "$pkg_file" ]; then
        warn "Network install failed. Using local fallback..."
        if exe runuser -u "$TARGET_USER" -- yay -U --noconfirm "$pkg_file"; then
            success "Installed from local."; return 0
        else
            error "Local install failed."; return 1
        fi
    else
        return 1
    fi
}

section "Phase 6" "KDE Plasma Environment"

# ------------------------------------------------------------------------------
# 0. Identify Target User
# ------------------------------------------------------------------------------
log "Identifying user..."
DETECTED_USER=$(awk -F: '$3 == 1000 {print $1}' /etc/passwd)
if [ -n "$DETECTED_USER" ]; then TARGET_USER="$DETECTED_USER"; else read -p "Target user: " TARGET_USER; fi
HOME_DIR="/home/$TARGET_USER"
info_kv "Target" "$TARGET_USER"

# ------------------------------------------------------------------------------
# 1. Install KDE Plasma Base
# ------------------------------------------------------------------------------
section "Step 1/5" "Plasma Core"

log "Installing KDE Plasma Meta & Apps..."
# Removed flatpak/flatpak-kcm from here, moved to Step 2 for clarity
KDE_PKGS="plasma-meta konsole dolphin kate firefox qt6-multimedia-ffmpeg pipewire-jack"
exe pacman -Syu --noconfirm --needed $KDE_PKGS
success "KDE Plasma installed."

# ------------------------------------------------------------------------------
# 2. Software Store (Discover) & Network
# ------------------------------------------------------------------------------
section "Step 2/5" "Software Store & Network"

log "Configuring Discover & Flatpak..."

# 1. Install Flatpak backend for KDE
# flatpak-kcm allows managing Flatpak repos/permissions in KDE System Settings
exe pacman -Syu --noconfirm --needed flatpak flatpak-kcm

# 2. Add Official Flathub (Default)
exe flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

# 3. Network Optimization (Mirror Logic)
IS_CN_ENV=false
if [ "$CN_MIRROR" == "1" ] || [ "$DEBUG" == "1" ]; then
    IS_CN_ENV=true
    if [ "$DEBUG" == "1" ]; then warn "DEBUG MODE ACTIVE"; fi
    
    log "Enabling China Optimizations..."
    
    # Flatpak Mirror
    log "-> Switching Flathub to USTC Mirror..."
    exe flatpak remote-modify flathub --url=https://mirrors.ustc.edu.cn/flathub
    
    # GOPROXY
    export GOPROXY=https://goproxy.cn,direct
    if ! grep -q "GOPROXY" /etc/environment; then echo "GOPROXY=https://goproxy.cn,direct" >> /etc/environment; fi
    
    # Git Mirror
    exe runuser -u "$TARGET_USER" -- git config --global url."https://gitclone.com/github.com/".insteadOf "https://github.com/"
    
    success "Optimizations Enabled."
else
    log "Using Global Sources."
fi

# NOPASSWD for yay
SUDO_TEMP_FILE="/etc/sudoers.d/99_shorin_installer_temp"
echo "$TARGET_USER ALL=(ALL) NOPASSWD: ALL" > "$SUDO_TEMP_FILE"
chmod 440 "$SUDO_TEMP_FILE"

# ------------------------------------------------------------------------------
# 3. Install Dependencies (KDE Specific)
# ------------------------------------------------------------------------------
section "Step 3/5" "KDE Dependencies"

LIST_FILE="$PARENT_DIR/kde-applist.txt"
FAILED_PACKAGES=()

if [ -f "$LIST_FILE" ]; then
    mapfile -t PACKAGE_ARRAY < <(grep -vE "^\s*#|^\s*$" "$LIST_FILE" | tr -d '\r')
    if [ ${#PACKAGE_ARRAY[@]} -gt 0 ]; then
        BATCH_LIST=""
        GIT_LIST=()
        for pkg in "${PACKAGE_ARRAY[@]}"; do
            if [[ "$pkg" == *"-git" ]]; then GIT_LIST+=("$pkg"); else BATCH_LIST+="$pkg "; fi
        done
        
        # Phase 1: Batch
        if [ -n "$BATCH_LIST" ]; then
            log "Batch Install..."
            if ! exe runuser -u "$TARGET_USER" -- env GOPROXY=$GOPROXY yay -Syu --noconfirm --needed --answerdiff=None --answerclean=None $BATCH_LIST; then
                warn "Batch failed. Retrying with Mirror Toggle..."
                if runuser -u "$TARGET_USER" -- git config --global --get url."https://gitclone.com/github.com/".insteadOf > /dev/null; then
                    runuser -u "$TARGET_USER" -- git config --global --unset url."https://gitclone.com/github.com/".insteadOf
                else
                    runuser -u "$TARGET_USER" -- git config --global url."https://gitclone.com/github.com/".insteadOf "https://github.com/"
                fi
                if ! exe runuser -u "$TARGET_USER" -- env GOPROXY=$GOPROXY yay -Syu --noconfirm --needed --answerdiff=None --answerclean=None $BATCH_LIST; then
                    error "Batch failed."
                else
                    success "Batch installed (Retry)."
                fi
            fi
        fi

        # Phase 2: Git
        if [ ${#GIT_LIST[@]} -gt 0 ]; then
            log "Git Install..."
            for git_pkg in "${GIT_LIST[@]}"; do
                if ! exe runuser -u "$TARGET_USER" -- env GOPROXY=$GOPROXY yay -Syu --noconfirm --needed --answerdiff=None --answerclean=None "$git_pkg"; then
                    warn "Retrying $git_pkg..."
                    # Toggle Mirror
                    if runuser -u "$TARGET_USER" -- git config --global --get url."https://gitclone.com/github.com/".insteadOf > /dev/null; then
                        runuser -u "$TARGET_USER" -- git config --global --unset url."https://gitclone.com/github.com/".insteadOf
                    else
                        runuser -u "$TARGET_USER" -- git config --global url."https://gitclone.com/github.com/".insteadOf "https://github.com/"
                    fi
                    
                    if ! exe runuser -u "$TARGET_USER" -- env GOPROXY=$GOPROXY yay -Syu --noconfirm --needed --answerdiff=None --answerclean=None "$git_pkg"; then
                        warn "Checking local cache..."
                        if install_local_fallback "$git_pkg"; then :; else
                            error "Failed: $git_pkg"
                            FAILED_PACKAGES+=("$git_pkg")
                        fi
                    else
                        success "Installed $git_pkg"
                    fi
                else
                    success "Installed $git_pkg"
                fi
            done
        fi
        
        if [ ${#FAILED_PACKAGES[@]} -gt 0 ]; then
            DOCS_DIR="$HOME_DIR/Documents"
            REPORT_FILE="$DOCS_DIR/安装失败的软件.txt"
            if [ ! -d "$DOCS_DIR" ]; then runuser -u "$TARGET_USER" -- mkdir -p "$DOCS_DIR"; fi
            printf "%s\n" "${FAILED_PACKAGES[@]}" > "$REPORT_FILE"
            chown "$TARGET_USER:$TARGET_USER" "$REPORT_FILE"
            warn "Some packages failed. See: $REPORT_FILE"
        fi
    fi
else
    warn "kde-applist.txt not found."
fi

# ------------------------------------------------------------------------------
# 4. Dotfiles Deployment
# ------------------------------------------------------------------------------
section "Step 4/5" "KDE Config Deployment"

DOTFILES_SOURCE="$PARENT_DIR/kde-dotfiles"

if [ -d "$DOTFILES_SOURCE" ]; then
    log "Deploying KDE configurations..."
    
    # Backup .config
    BACKUP_NAME="config_backup_kde_$(date +%s).tar.gz"
    log "Backing up ~/.config to $BACKUP_NAME..."
    exe runuser -u "$TARGET_USER" -- tar -czf "$HOME_DIR/$BACKUP_NAME" -C "$HOME_DIR" .config
    
    # Copy all files (cp -rT to merge directories)
    log "Copying files..."
    exe runuser -u "$TARGET_USER" -- cp -rfT "$DOTFILES_SOURCE" "$HOME_DIR"
    
    success "KDE Dotfiles applied."
else
    warn "Folder 'kde-dotfiles' not found in repo. Skipping config."
fi

# ------------------------------------------------------------------------------
# 5. Enable SDDM
# ------------------------------------------------------------------------------
section "Step 5/5" "Enable Display Manager"

log "Enabling SDDM..."
exe systemctl enable sddm
success "SDDM enabled. Will start on reboot."

# ------------------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------------------
section "Cleanup" "Restoring State"
rm -f "$SUDO_TEMP_FILE"
runuser -u "$TARGET_USER" -- git config --global --unset url."https://gitclone.com/github.com/".insteadOf
sed -i '/GOPROXY=https:\/\/goproxy.cn,direct/d' /etc/environment
success "Done."

log "Module 06 completed."