#!/bin/bash

# 脚本功能：
# 从随机老婆图片生成api下载图片，存在.cache/fastfetch_waifu目录。
# 运行时如果库存不足，会在后台补货；如果库存超限，会清理旧图。

# --- 1. 配置区域 (在此修改数值) ---
CACHE_DIR="$HOME/.cache/fastfetch_waifu"
LOCK_FILE="/tmp/fastfetch_waifu.lock"

# [修改点 1 & 3] 设置为环境变量，方便调节
DOWNLOAD_BATCH_SIZE=10   # 每次补货下载多少张
MAX_CACHE_LIMIT=100      # 最大库存上限
MIN_TRIGGER_LIMIT=60     # 库存少于多少张时开始补货

mkdir -p "$CACHE_DIR"

# --- 2. 核心函数 ---

get_random_url() {
    # 增加连接超时设置，防止断网时死等
    local TIMEOUT="--connect-timeout 5 --max-time 15"
    
    RAND=$(( ( RANDOM % 3 ) + 1 ))
    case $RAND in
        1) curl -s $TIMEOUT "https://api.waifu.im/search?included_tags=waifu&is_nsfw=false" | jq -r '.images[0].url' ;;
        2) curl -s $TIMEOUT "https://nekos.best/api/v2/waifu" | jq -r '.results[0].url' ;;
        3) curl -s $TIMEOUT "https://api.waifu.pics/sfw/waifu" | jq -r '.url' ;;
    esac
}

download_one_image() {
    URL=$(get_random_url)
    if [[ "$URL" =~ ^http ]]; then
        FILENAME="waifu_$(date +%s%N)_$RANDOM.jpg"
        TARGET_PATH="$CACHE_DIR/$FILENAME"
        
        # 下载
        curl -s -L --connect-timeout 5 --max-time 15 -o "$TARGET_PATH" "$URL"
        
        # [安全验证] 确保下载的是真图片，不是 404 页面的 HTML
        if [ -s "$TARGET_PATH" ]; then
            # 如果有 file 命令，检查 mime type
            if command -v file >/dev/null 2>&1; then
                if ! file --mime-type "$TARGET_PATH" | grep -q "image/"; then
                    rm -f "$TARGET_PATH" # 假文件，删除
                fi
            fi
        else
            rm -f "$TARGET_PATH" # 空文件，删除
        fi
    fi
}

background_job() {
    (
        # 获取锁，防止多终端同时下载
        flock -n 200 || exit 1
        
        # --- 临界区 ---
        
        # 1. 补货检查
        CURRENT_COUNT=$(find "$CACHE_DIR" -maxdepth 1 -name "*.jpg" 2>/dev/null | wc -l)

        # 只有库存 < 触发线(20) 时，才开始补货
        if [ "$CURRENT_COUNT" -lt "$MIN_TRIGGER_LIMIT" ]; then
            # [修改点 2] 使用变量控制循环次数
            for ((i=1; i<=DOWNLOAD_BATCH_SIZE; i++)); do
                download_one_image
                sleep 0.5
            done
        fi

        # 2. 清理逻辑
        FINAL_COUNT=$(find "$CACHE_DIR" -maxdepth 1 -name "*.jpg" 2>/dev/null | wc -l)
        
        # [修改点 2] 超过上限(100) 时清理
        if [ "$FINAL_COUNT" -gt "$MAX_CACHE_LIMIT" ]; then
             # 计算需要从第几行开始删除 (上限+1)
             DELETE_START_LINE=$((MAX_CACHE_LIMIT + 1))
             
             # 删除旧图 (保留最新的 MAX_CACHE_LIMIT 张)
             ls -tp "$CACHE_DIR"/*.jpg 2>/dev/null | tail -n +$DELETE_START_LINE | xargs -I {} rm -- "{}"
        fi
        
        # --- 结束 ---
        
    ) 200>"$LOCK_FILE"
}

# --- 3. 主程序逻辑 ---

# 开启 nullglob
shopt -s nullglob
FILES=("$CACHE_DIR"/*.jpg)
NUM_FILES=${#FILES[@]}
shopt -u nullglob

SELECTED_IMG=""

if [ "$NUM_FILES" -gt 0 ]; then
    # === 场景 A: 有库存 (秒开) ===
    RAND_INDEX=$(( RANDOM % NUM_FILES ))
    SELECTED_IMG="${FILES[$RAND_INDEX]}"
    
    # 偷偷在后台检查是否需要补货
    background_job >/dev/null 2>&1 &
    
else
    # === 场景 B: 没库存 (用户选择等待) ===
    echo "库存为空，正在获取新老婆..."
    
    # 强制同步下载一张
    download_one_image
    
    # 再次检查是否有文件了
    shopt -s nullglob
    FILES=("$CACHE_DIR"/*.jpg)
    shopt -u nullglob
    
    if [ ${#FILES[@]} -gt 0 ]; then
        SELECTED_IMG="${FILES[0]}"
        # 既然已经有一张了，剩下的交给后台慢慢补
        background_job >/dev/null 2>&1 &
    fi
fi

# 运行 Fastfetch
if [ -n "$SELECTED_IMG" ] && [ -f "$SELECTED_IMG" ]; then
    fastfetch --logo "$SELECTED_IMG" --logo-preserve-aspect-ratio true "$@"
    
    # 阅后即焚
    rm -f "$SELECTED_IMG"
else
    # 只有彻底断网且缓存为空时才会显示这个
    echo "图片获取彻底失败（可能是网络问题），暂用默认 Logo"
    fastfetch "$@"
fi