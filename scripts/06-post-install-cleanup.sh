#!/bin/bash

# ==============================================================================
# 06-post-install-cleanup.sh - System Cleanup & Snapshot Management
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/00-utils.sh"

check_root

section "Phase 6" "System Cleanup & Snapshot Management"

# ------------------------------------------------------------------------------
# Function: Clean Intermediate Snapper Snapshots
# ------------------------------------------------------------------------------
clean_intermediate_snapshots() {
    local config_name="$1"
    local marker_name="Before Shorin Setup"
    
    # 1. 检查 Snapper 配置是否存在
    if ! snapper -c "$config_name" list &>/dev/null; then
        warn "Snapper config '$config_name' not found. Skipping."
        return
    fi

    log "Scanning intermediate snapshots for config: $config_name..."

    # 2. 获取锚点快照的 ID
    # 这里的 tail -n 1 确保如果有多个同名快照，取最新的那一个作为锚点
    local start_id
    start_id=$(snapper -c "$config_name" list --columns number,description | grep "$marker_name" | awk '{print $1}' | tail -n 1)

    if [ -z "$start_id" ]; then
        warn "Marker snapshot '$marker_name' not found in '$config_name'. Skipping cleanup to be safe."
        return
    fi

    info_kv "Marker Found" "ID: $start_id ($marker_name)"

    # 3. 获取所有 ID 大于 start_id 的快照
    local snapshots_to_delete=()
    
    # 使用 process substitution 避免管道子 shell 问题
    while read -r line; do
        local id
        local type
        
        # [Corrected Logic] Snapper list format is: " # | Type | ..."
        # So Type is in column 3, not 2.
        id=$(echo "$line" | awk '{print $1}')
        type=$(echo "$line" | awk '{print $3}')

        # 确保 ID 是数字
        if [[ "$id" =~ ^[0-9]+$ ]]; then
            if [ "$id" -gt "$start_id" ]; then
                # 删除 pacman 产生的 pre/post 以及手动产生的 single
                if [[ "$type" == "pre" || "$type" == "post" || "$type" == "single" ]]; then
                    snapshots_to_delete+=("$id")
                fi
            fi
        fi
    done < <(snapper -c "$config_name" list --columns number,type)

    # 4. 执行删除
    if [ ${#snapshots_to_delete[@]} -gt 0 ]; then
        log "Deleting ${#snapshots_to_delete[@]} junk snapshots in '$config_name'..."
        
        # 批量删除
        if exe snapper -c "$config_name" delete "${snapshots_to_delete[@]}"; then
            success "Cleaned $config_name (removed: ${snapshots_to_delete[*]})"
        else
            error "Failed to delete some snapshots in $config_name"
        fi
    else
        log "No junk snapshots found after marker in '$config_name'."
    fi
}

# ------------------------------------------------------------------------------
# Main Execution
# ------------------------------------------------------------------------------

# 1. Clean Package Cache (Optional but recommended)
log "Cleaning Pacman/Yay cache..."
exe pacman -Sc --noconfirm

# 2. Clean Snapshots
# 定义需要清理的配置列表
TARGET_CONFIGS=("root" "home")

for config in "${TARGET_CONFIGS[@]}"; do
    clean_intermediate_snapshots "$config"
done

log "Module 06 completed."