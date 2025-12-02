#!/bin/bash

# ==============================================================================
# 04-niri-setup.sh - Niri Desktop (Visual Enhanced)
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/00-utils.sh"

# --- Config ---
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
            success "Installed from local backup."
            return 0
        else
            error "Local package install failed."
            return 1
        fi
    else
        return 1
    fi
}

section "Phase 4" "Niri Desktop Environment"

# ------------------------------------------------------------------------------
# 0. Identify Target User
# ------------------------------------------------------------------------------
log "Identifying user..."
DETECTED_USER=$(awk -F: '$3 == 1000 {print $1}' /etc/passwd)

if [ -n "$DETECTED_USER" ]; then
    TARGET_USER="$DETECTED_USER"
else
    read -p "   Please enter target username: " TARGET_USER
fi
HOME_DIR="/home/$TARGET_USER"
info_kv "Target" "$TARGET_USER"

# ------------------------------------------------------------------------------
# [SAFETY CHECK] Detect Existing Display Managers
# ------------------------------------------------------------------------------
log "Checking Display Managers..."

DMS=("gdm" "sddm" "lightdm" "lxdm" "ly")
SKIP_AUTOLOGIN=false

for dm in "${DMS[@]}"; do
    if systemctl is-enabled "$dm.service" &>/dev/null; then
        info_kv "DM Detected" "$dm" "${H_YELLOW}(Active)${NC}"
        warn "TTY auto-login configuration will be SKIPPED."
        SKIP_AUTOLOGIN=true
        break
    fi
done

if [ "$SKIP_AUTOLOGIN" = false ]; then
    log "No active DM. TTY auto-login will be configured."
fi

# ------------------------------------------------------------------------------
# 1. Install Niri & Essentials
# ------------------------------------------------------------------------------
section "Step 1/9" "Core Components"

# Core Packages
log "Installing Niri & Essentials..."
PKGS="niri xwayland-satellite xdg-desktop-portal-gnome fuzzel kitty firefox libnotify mako polkit-gnome pciutils"
exe pacman -Syu --noconfirm --needed $PKGS

# Firefox Policy (Pywalfox)
log "Configuring Firefox Policies..."
FIREFOX_POLICY_DIR="/etc/firefox/policies"
exe mkdir -p "$FIREFOX_POLICY_DIR"

cat <<EOT > "$FIREFOX_POLICY_DIR/policies.json"
{
  "policies": {
    "Extensions": {
      "Install": [
        "https://addons.mozilla.org/firefox/downloads/latest/pywalfox/latest.xpi"
      ]
    }
  }
}
EOT
exe chmod 755 "/etc/firefox"
exe chmod 755 "$FIREFOX_POLICY_DIR"
exe chmod 644 "$FIREFOX_POLICY_DIR/policies.json"
success "Firefox policy applied."

# ------------------------------------------------------------------------------
# 1.1 Configure XDG Portals
# ------------------------------------------------------------------------------
log "Configuring XDG Desktop Portals..."
PORTAL_CONF_DIR="$HOME_DIR/.config/xdg-desktop-portal"
exe runuser -u "$TARGET_USER" -- mkdir -p "$PORTAL_CONF_DIR"
PORTAL_CONF="$PORTAL_CONF_DIR/niri-portals.conf"

cat <<EOT > "/tmp/niri-portals.conf"
[preferred]
default=gnome
org.freedesktop.impl.portal.ScreenCast=gnome
org.freedesktop.impl.portal.Screenshot=gnome
EOT

exe cp "/tmp/niri-portals.conf" "$PORTAL_CONF"
exe chown "$TARGET_USER:$TARGET_USER" "$PORTAL_CONF"
success "Portal priority configured."

# ------------------------------------------------------------------------------
# 2. File Manager Setup
# ------------------------------------------------------------------------------
section "Step 2/9" "File Manager & GPU"

exe pacman -Syu --noconfirm --needed ffmpegthumbnailer gvfs-smb nautilus-open-any-terminal file-roller gnome-keyring gst-plugins-base gst-plugins-good gst-libav nautilus

if [ ! -f /usr/bin/gnome-terminal ] || [ -L /usr/bin/gnome-terminal ]; then
    exe ln -sf /usr/bin/kitty /usr/bin/gnome-terminal
fi

# Smart GPU Env
DESKTOP_FILE="/usr/share/applications/org.gnome.Nautilus.desktop"
if [ -f "$DESKTOP_FILE" ]; then
    log "Checking GPU configuration..."
    
    GPU_COUNT=$(lspci | grep -E -i "vga|3d" | wc -l)
    HAS_NVIDIA=$(lspci | grep -E -i "nvidia" | wc -l)
    
    ENV_VARS="env GTK_IM_MODULE=fcitx"
    if [ "$GPU_COUNT" -gt 1 ] && [ "$HAS_NVIDIA" -gt 0 ]; then
        info_kv "GPU" "Hybrid Nvidia" "-> GSK_RENDERER=gl"
        ENV_VARS="env GSK_RENDERER=gl GTK_IM_MODULE=fcitx"
    fi
    
    exe sed -i "s/^Exec=/Exec=$ENV_VARS /" "$DESKTOP_FILE"
fi

# ------------------------------------------------------------------------------
# 3. Network Optimization
# ------------------------------------------------------------------------------
section "Step 3/9" "Network Optimization"

exe pacman -Syu --noconfirm --needed flatpak gnome-software
exe flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

IS_CN_ENV=false
if [ "$CN_MIRROR" == "1" ] || [ "$DEBUG" == "1" ]; then
    IS_CN_ENV=true
    if [ "$DEBUG" == "1" ]; then warn "DEBUG MODE ACTIVE"; fi
    
    log "Enabling China Optimizations..."
    
    # [MODIFIED] Switch to SJTU Mirror & Disable P2P
    log "-> Switching Flathub to SJTU Mirror..."
    exe flatpak remote-modify flathub --url=https://mirror.sjtu.edu.cn/flathub
    exe flatpak remote-modify --no-p2p flathub
    
    export GOPROXY=https://goproxy.cn,direct
    if ! grep -q "GOPROXY" /etc/environment; then
        echo "GOPROXY=https://goproxy.cn,direct" >> /etc/environment
    fi
    
    log "Enabling Git Mirror..."
    exe runuser -u "$TARGET_USER" -- git config --global url."https://gitclone.com/github.com/".insteadOf "https://github.com/"
    
    success "Optimizations Enabled."
else
    log "Using Global Sources."
fi

# NOPASSWD
SUDO_TEMP_FILE="/etc/sudoers.d/99_shorin_installer_temp"
echo "$TARGET_USER ALL=(ALL) NOPASSWD: ALL" > "$SUDO_TEMP_FILE"
chmod 440 "$SUDO_TEMP_FILE"

# ------------------------------------------------------------------------------
# 4. Install Dependencies
# ------------------------------------------------------------------------------
section "Step 4/9" "Installing Dependencies"

LIST_FILE="$PARENT_DIR/niri-applist.txt"
FAILED_PACKAGES=()

if [ -f "$LIST_FILE" ]; then
    mapfile -t PACKAGE_ARRAY < <(grep -vE "^\s*#|^\s*$" "$LIST_FILE" | tr -d '\r')
    
    if [ ${#PACKAGE_ARRAY[@]} -gt 0 ]; then
        BATCH_LIST=""
        GIT_LIST=()

        for pkg in "${PACKAGE_ARRAY[@]}"; do
            [ "$pkg" == "imagemagic" ] && pkg="imagemagick"
            
            if [[ "$pkg" == *"-git" ]]; then
                GIT_LIST+=("$pkg")
            else
                BATCH_LIST+="$pkg "
            fi
        done
        
        # --- Phase 1: Batch Install ---
        if [ -n "$BATCH_LIST" ]; then
            log "Phase 1: Batch Install..."
            
            if ! exe runuser -u "$TARGET_USER" -- env GOPROXY=$GOPROXY yay -Syu --noconfirm --needed --answerdiff=None --answerclean=None $BATCH_LIST; then
                warn "Batch failed. Retrying with Mirror Toggle..."
                
                if runuser -u "$TARGET_USER" -- git config --global --get url."https://gitclone.com/github.com/".insteadOf > /dev/null; then
                    runuser -u "$TARGET_USER" -- git config --global --unset url."https://gitclone.com/github.com/".insteadOf
                else
                    runuser -u "$TARGET_USER" -- git config --global url."https://gitclone.com/github.com/".insteadOf "https://github.com/"
                fi
                
                if ! exe runuser -u "$TARGET_USER" -- env GOPROXY=$GOPROXY yay -Syu --noconfirm --needed --answerdiff=None --answerclean=None $BATCH_LIST; then
                    error "Batch install failed."
                else
                    success "Batch installed (Retry)."
                fi
            fi
        fi

        # --- Phase 2: Git Install ---
        if [ ${#GIT_LIST[@]} -gt 0 ]; then
            log "Phase 2: Git Install..."
            for git_pkg in "${GIT_LIST[@]}"; do
                if ! exe runuser -u "$TARGET_USER" -- env GOPROXY=$GOPROXY yay -Syu --noconfirm --needed --answerdiff=None --answerclean=None "$git_pkg"; then
                    warn "Retrying $git_pkg..."
                    
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
                        success "Installed $git_pkg (Retry)"
                    fi
                else
                    success "Installed $git_pkg"
                fi
            done
        fi
        
        # --- Recovery Checks ---
        log "Verifying critical components..."
        
        if ! command -v waybar &> /dev/null; then
            warn "Waybar missing. Installing stock..."
            exe pacman -Syu --noconfirm --needed waybar
        fi

        if ! runuser -u "$TARGET_USER" -- command -v awww &> /dev/null; then
            warn "Awww not found. Will try Swaybg later."
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
    warn "niri-applist.txt not found."
fi

# ------------------------------------------------------------------------------
# 5. Dotfiles
# ------------------------------------------------------------------------------
section "Step 5/9" "Deploying Dotfiles"

REPO_URL="https://github.com/SHORiN-KiWATA/ShorinArchExperience-ArchlinuxGuide.git"
TEMP_DIR="/tmp/shorin-repo"
rm -rf "$TEMP_DIR"

log "Cloning repository..."
if ! exe runuser -u "$TARGET_USER" -- git clone "$REPO_URL" "$TEMP_DIR"; then
    warn "Clone failed. Retrying..."
    if runuser -u "$TARGET_USER" -- git config --global --get url."https://gitclone.com/github.com/".insteadOf > /dev/null; then
        runuser -u "$TARGET_USER" -- git config --global --unset url."https://gitclone.com/github.com/".insteadOf
    else
        runuser -u "$TARGET_USER" -- git config --global url."https://gitclone.com/github.com/".insteadOf "https://github.com/"
    fi
    
    if ! exe runuser -u "$TARGET_USER" -- git clone "$REPO_URL" "$TEMP_DIR"; then
        error "Clone failed."
    fi
fi

if [ -d "$TEMP_DIR/dotfiles" ]; then
    BACKUP_NAME="config_backup_$(date +%s).tar.gz"
    log "Backing up ~/.config..."
    exe runuser -u "$TARGET_USER" -- tar -czf "$HOME_DIR/$BACKUP_NAME" -C "$HOME_DIR" .config
    
    log "Applying dotfiles..."
    exe runuser -u "$TARGET_USER" -- cp -rf "$TEMP_DIR/dotfiles/." "$HOME_DIR/"
    success "Dotfiles applied."
    
    # Clean non-shorin config
    if [ "$TARGET_USER" != "shorin" ]; then
        OUTPUT_KDL="$HOME_DIR/.config/niri/output.kdl"
        if [ -f "$OUTPUT_KDL" ]; then
            log "Clearing output.kdl..."
            exe runuser -u "$TARGET_USER" -- truncate -s 0 "$OUTPUT_KDL"
        fi
        
        EXCLUDE_FILE="$PARENT_DIR/exclude-dotfiles.txt"
        if [ -f "$EXCLUDE_FILE" ]; then
            log "Removing user-specific configs..."
            mapfile -t EXCLUDES < <(grep -vE "^\s*#|^\s*$" "$EXCLUDE_FILE" | tr -d '\r')
            for item in "${EXCLUDES[@]}"; do
                item=$(echo "$item" | xargs)
                [ -z "$item" ] && continue
                REMOVE_TARGET="$HOME_DIR/.config/$item"
                if [ -d "$REMOVE_TARGET" ]; then exe rm -rf "$REMOVE_TARGET"; fi
            done
        fi
    fi

    # Ultimate Fallback
    if ! runuser -u "$TARGET_USER" -- command -v awww &> /dev/null; then
        warn "Awww missing. Switching to Swaybg..."
        exe pacman -Syu --noconfirm --needed swaybg
        SCRIPT_PATH="$HOME_DIR/.config/scripts/niri_set_overview_blur_dark_bg.sh"
        if [ -f "$SCRIPT_PATH" ]; then
            sed -i 's/^WALLPAPER_BACKEND="awww"/WALLPAPER_BACKEND="swaybg"/' "$SCRIPT_PATH"
            success "Switched to Swaybg."
        fi
    fi
else
    warn "Dotfiles directory missing. Configuration skipped."
fi

# ------------------------------------------------------------------------------
# 6. Wallpapers
# ------------------------------------------------------------------------------
section "Step 6/9" "Wallpapers"
WALL_DEST="$HOME_DIR/Pictures/Wallpapers"
if [ -d "$TEMP_DIR/wallpapers" ]; then
    exe runuser -u "$TARGET_USER" -- mkdir -p "$WALL_DEST"
    exe runuser -u "$TARGET_USER" -- cp -rf "$TEMP_DIR/wallpapers/." "$WALL_DEST/"
    success "Wallpapers installed."
fi
rm -rf "$TEMP_DIR"

# ------------------------------------------------------------------------------
# 7. Hardware Tools
# ------------------------------------------------------------------------------
section "Step 7/9" "Hardware Tools"

exe runuser -u "$TARGET_USER" -- yay -Syu --noconfirm --needed ddcutil-service
gpasswd -a "$TARGET_USER" i2c

exe pacman -Syu --noconfirm --needed swayosd
systemctl enable --now swayosd-libinput-backend.service > /dev/null 2>&1

success "Hardware tools configured."

# ------------------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------------------
section "Step 9/9" "Cleanup"

rm -f "$SUDO_TEMP_FILE"
runuser -u "$TARGET_USER" -- git config --global --unset url."https://gitclone.com/github.com/".insteadOf
sed -i '/GOPROXY=https:\/\/goproxy.cn,direct/d' /etc/environment

success "Cleanup done."

# ------------------------------------------------------------------------------
# 10. Auto-Login
# ------------------------------------------------------------------------------
section "Final" "Boot Config"

USER_SYSTEMD_DIR="$HOME_DIR/.config/systemd/user"
WANTS_DIR="$USER_SYSTEMD_DIR/default.target.wants"
LINK_PATH="$WANTS_DIR/niri-autostart.service"
SERVICE_FILE="$USER_SYSTEMD_DIR/niri-autostart.service"

if [ "$SKIP_AUTOLOGIN" = true ]; then
    log "Auto-login skipped (Reason: $DM_FOUND or User Opt-out)."
    
    if [ -f "$LINK_PATH" ] || [ -f "$SERVICE_FILE" ]; then
        warn "Removing old auto-login services..."
        exe rm -f "$LINK_PATH"
        exe rm -f "$SERVICE_FILE"
        success "Cleanup successful."
    fi
else
    log "Configuring TTY Auto-login..."
    
    GETTY_DIR="/etc/systemd/system/getty@tty1.service.d"
    mkdir -p "$GETTY_DIR"
    cat <<EOT > "$GETTY_DIR/autologin.conf"
[Service]
ExecStart=
ExecStart=-/sbin/agetty --noreset --noclear --autologin $TARGET_USER - \${TERM}
EOT

    exe mkdir -p "$USER_SYSTEMD_DIR"
    cat <<EOT > "$SERVICE_FILE"
[Unit]
Description=Niri Session Autostart
After=graphical-session-pre.target

[Service]
ExecStart=/usr/bin/niri-session
Restart=on-failure

[Install]
WantedBy=default.target
EOT

    exe mkdir -p "$WANTS_DIR"
    exe ln -sf "../niri-autostart.service" "$LINK_PATH"
    
    exe chown -R "$TARGET_USER:$TARGET_USER" "$HOME_DIR/.config/systemd"
    success "Auto-login configured."
fi

log "Module 04 completed."