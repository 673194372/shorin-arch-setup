#!/bin/bash

# ==============================================================================
# 07-grub-theme.sh - GRUB Bootloader Theming (Visual Enhanced & Optional)
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/00-utils.sh"

check_root

# ------------------------------------------------------------------------------
# 0. Pre-check: Is GRUB installed?
# ------------------------------------------------------------------------------
if ! command -v grub-mkconfig >/dev/null 2>&1; then
    echo ""
    warn "GRUB (grub-mkconfig) not found on this system."
    log "Skipping GRUB theme installation."
    exit 0
fi

section "Phase 7" "GRUB Theme Customization"

# ------------------------------------------------------------------------------
# 1. Detect Themes
# ------------------------------------------------------------------------------
log "Scanning for themes in 'grub-themes' folder..."

SOURCE_BASE="$PARENT_DIR/grub-themes"
DEST_DIR="/boot/grub/themes"

# Case 1: Repo folder missing
if [ ! -d "$SOURCE_BASE" ]; then
    warn "Directory 'grub-themes' not found in repo."
    exit 0
fi

# [Fix] 使用 sort 确保每次运行顺序一致
mapfile -t FOUND_DIRS < <(find "$SOURCE_BASE" -mindepth 1 -maxdepth 1 -type d | sort)
THEME_PATHS=()
THEME_NAMES=()

for dir in "${FOUND_DIRS[@]}"; do
    if [ -f "$dir/theme.txt" ]; then
        THEME_PATHS+=("$dir")
        THEME_NAMES+=("$(basename "$dir")")
    fi
done

# Case 2: No valid themes found
if [ ${#THEME_NAMES[@]} -eq 0 ]; then
    warn "No valid theme folders (containing theme.txt) found."
    exit 0
fi

# ------------------------------------------------------------------------------
# 2. Select Theme (TUI Menu)
# ------------------------------------------------------------------------------

if [ ${#THEME_NAMES[@]} -eq 1 ]; then
    SELECTED_INDEX=0
    log "Only one theme detected. Auto-selecting: ${THEME_NAMES[0]}"
else
    # --- 动态计算菜单宽度 ---
    TITLE_TEXT="Select GRUB Theme (60s Timeout)"
    MAX_LEN=${#TITLE_TEXT}

    for name in "${THEME_NAMES[@]}"; do
        ITEM_LEN=$((${#name} + 20))
        if (( ITEM_LEN > MAX_LEN )); then
            MAX_LEN=$ITEM_LEN
        fi
    done

    MENU_WIDTH=$((MAX_LEN + 4))

    # --- 渲染菜单 ---
    echo ""
    
    # 生成横线
    LINE_STR=""
    printf -v LINE_STR "%*s" "$MENU_WIDTH" ""
    LINE_STR=${LINE_STR// /─}

    # 顶部
    echo -e "${H_PURPLE}╭${LINE_STR}╮${NC}"

    # 标题
    TITLE_PADDING_LEN=$(( (MENU_WIDTH - ${#TITLE_TEXT}) / 2 ))
    RIGHT_PADDING_LEN=$((MENU_WIDTH - ${#TITLE_TEXT} - TITLE_PADDING_LEN))
    
    T_PAD_L=""; printf -v T_PAD_L "%*s" "$TITLE_PADDING_LEN" ""
    T_PAD_R=""; printf -v T_PAD_R "%*s" "$RIGHT_PADDING_LEN" ""
    
    echo -e "${H_PURPLE}│${NC}${T_PAD_L}${BOLD}${TITLE_TEXT}${NC}${T_PAD_R}${H_PURPLE}│${NC}"
    echo -e "${H_PURPLE}├${LINE_STR}┤${NC}"

    # 选项
    for i in "${!THEME_NAMES[@]}"; do
        NAME="${THEME_NAMES[$i]}"
        DISPLAY_IDX=$((i+1))
        
        # 定义显示字符串
        if [ "$i" -eq 0 ]; then
            RAW_STR=" [$DISPLAY_IDX] $NAME - Default"
            COLOR_STR=" ${H_CYAN}[$DISPLAY_IDX]${NC} ${NAME} - ${H_GREEN}Default${NC}"
        else
            RAW_STR=" [$DISPLAY_IDX] $NAME"
            COLOR_STR=" ${H_CYAN}[$DISPLAY_IDX]${NC} ${NAME}"
        fi

        # 计算填充
        PADDING=$((MENU_WIDTH - ${#RAW_STR}))
        PAD_STR=""; 
        if [ "$PADDING" -gt 0 ]; then
            printf -v PAD_STR "%*s" "$PADDING" ""
        fi
        
        echo -e "${H_PURPLE}│${NC}${COLOR_STR}${PAD_STR}${H_PURPLE}│${NC}"
    done

    # 底部
    echo -e "${H_PURPLE}╰${LINE_STR}╯${NC}"
    echo ""

    # --- [Fix] 修复 read 输入 ---
    # 分开打印提示符和读取输入，避免ANSI颜色代码导致的 read 异常
    echo -ne "   ${H_YELLOW}Enter choice [1-${#THEME_NAMES[@]}]: ${NC}"
    read -t 60 USER_CHOICE
    
    # 如果超时或直接回车，echo 一个换行符以免显示错乱
    if [ -z "$USER_CHOICE" ]; then
        echo "" 
    fi

    # 默认值处理
    USER_CHOICE=${USER_CHOICE:-1}

    # 验证
    if ! [[ "$USER_CHOICE" =~ ^[0-9]+$ ]] || [ "$USER_CHOICE" -lt 1 ] || [ "$USER_CHOICE" -gt "${#THEME_NAMES[@]}" ]; then
        log "Invalid choice or timeout. Defaulting to first option..."
        SELECTED_INDEX=0
    else
        SELECTED_INDEX=$((USER_CHOICE-1))
    fi
fi

THEME_SOURCE="${THEME_PATHS[$SELECTED_INDEX]}"
THEME_NAME="${THEME_NAMES[$SELECTED_INDEX]}"

info_kv "Selected" "$THEME_NAME"

# ------------------------------------------------------------------------------
# 3. Install Theme Files
# ------------------------------------------------------------------------------
log "Installing theme files..."

if [ ! -d "$DEST_DIR" ]; then
    exe mkdir -p "$DEST_DIR"
fi

if [ -d "$DEST_DIR/$THEME_NAME" ]; then
    log "Removing existing version..."
    exe rm -rf "$DEST_DIR/$THEME_NAME"
fi

exe cp -r "$THEME_SOURCE" "$DEST_DIR/"

if [ -f "$DEST_DIR/$THEME_NAME/theme.txt" ]; then
    success "Theme installed to $DEST_DIR/$THEME_NAME"
else
    error "Failed to copy theme files."
    exit 1
fi

# ------------------------------------------------------------------------------
# 4. Configure /etc/default/grub
# ------------------------------------------------------------------------------
log "Configuring GRUB settings..."

GRUB_CONF="/etc/default/grub"
THEME_PATH="$DEST_DIR/$THEME_NAME/theme.txt"

if [ -f "$GRUB_CONF" ]; then
    # [Fix] 优先取消注释并修改，而不是无脑追加
    # 1. 检查是否存在未注释的 GRUB_THEME
    if grep -q "^GRUB_THEME=" "$GRUB_CONF"; then
        log "Updating active GRUB_THEME..."
        exe sed -i "s|^GRUB_THEME=.*|GRUB_THEME=\"$THEME_PATH\"|" "$GRUB_CONF"
    
    # 2. 检查是否存在被注释的 #GRUB_THEME
    elif grep -q "^#GRUB_THEME=" "$GRUB_CONF"; then
        log "Uncommenting and setting GRUB_THEME..."
        exe sed -i "s|^#GRUB_THEME=.*|GRUB_THEME=\"$THEME_PATH\"|" "$GRUB_CONF"
        
    # 3. 如果都没有，则追加
    else
        log "Appending GRUB_THEME entry..."
        echo "GRUB_THEME=\"$THEME_PATH\"" >> "$GRUB_CONF"
    fi
    
    # 图形终端设置
    if grep -q "^GRUB_TERMINAL_OUTPUT=\"console\"" "$GRUB_CONF"; then
        log "Enabling graphical terminal..."
        exe sed -i 's/^GRUB_TERMINAL_OUTPUT="console"/#GRUB_TERMINAL_OUTPUT="console"/' "$GRUB_CONF"
    fi
    
    if ! grep -q "^GRUB_GFXMODE=" "$GRUB_CONF"; then
        echo 'GRUB_GFXMODE=auto' >> "$GRUB_CONF"
    fi
    
    success "Configuration updated."
else
    error "$GRUB_CONF not found."
    exit 1
fi

# ------------------------------------------------------------------------------
# 5. Apply Changes
# ------------------------------------------------------------------------------
log "Generating new GRUB configuration..."

if exe grub-mkconfig -o /boot/grub/grub.cfg; then
    success "GRUB updated successfully."
else
    error "Failed to update GRUB."
    warn "You may need to run 'grub-mkconfig' manually."
fi

log "Module 07 completed."