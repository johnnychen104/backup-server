#!/bin/bash

# =================================================================
# Generic Backup Script: Pull Data, Compress, Upload to S3 (one shot)
# 通用備份腳本：pull 資料 → 壓縮 → 上傳 S3，一次做完
#
# This replaces the old two-stage design (separate pull-script +
# separate S3-sync-script running hours apart). Each company is now
# pulled, compressed and uploaded immediately in the same loop
# iteration, so:
#   - there is no "staging folder" of tar.gz files waiting for a
#     later batch upload
#   - S3 upload traffic is spread out over the whole run instead of
#     hitting all at once during a single fixed sync window
#
# 取代舊版「兩階段」設計(pull 腳本跟 S3 sync 腳本分開排程、間隔數小時執行)。
# 現在每間公司在同一次迴圈裡就把 pull → 壓縮 → 上傳一次做完，好處是：
#   - 不會有一個「等待上傳」的暫存資料夾
#   - S3 上傳流量會分散在整個跑批過程中，而不是集中在同一個排程時間點
#
# The local tar.gz is kept on the backup server for LOCAL_RETENTION_DAYS
# (default 3) after upload, as a quick local restore copy - it is not
# deleted right after a successful upload.
#
# 本地的 tar.gz 上傳後仍會保留 LOCAL_RETENTION_DAYS 天(預設 3 天)，
# 當作快速還原用的副本，不是上傳成功就馬上刪。
#
# Usage: ./1_run_backup_and_upload.sh <path_to_config_file>
# 用法：./1_run_backup_and_upload.sh <config 檔案路徑>
# =================================================================

CONFIG_FILE="$1"

# 1. Check Configuration
# 1. 檢查是否有帶入 config 檔案
if [ -z "$CONFIG_FILE" ]; then
    echo "Error: No config file provided."
    echo "錯誤：沒有帶入 config 檔案。"
    echo "Usage: $0 <path_to_config_file>"
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Config file not found: $CONFIG_FILE"
    echo "錯誤：找不到 config 檔案：$CONFIG_FILE"
    exit 1
fi

# 2. Load Configuration
# 2. 讀入 config 檔案的變數 (AP_HOST、IDS、LOCAL_BACKUP_DIR、S3_BUCKET 等)
source "$CONFIG_FILE"

# 3. Validate Required Variables
# 3. 檢查必要變數是否都有設定
if [ -z "$AP_HOST" ] || [ -z "$IDS" ] || [ -z "$LOCAL_BACKUP_DIR" ] || [ -z "$S3_BUCKET" ]; then
    echo "Error: Config file missing required variables (AP_HOST, IDS, LOCAL_BACKUP_DIR, S3_BUCKET)."
    echo "錯誤：config 檔案缺少必要變數 (AP_HOST、IDS、LOCAL_BACKUP_DIR、S3_BUCKET)。"
    exit 1
fi

# 4. Setup Logging
# 4. 設定 log 檔案路徑
LOG_FILE="${LOG_FILE:-/home/ubuntu/logs/backup_default.log}"
mkdir -p "$(dirname "$LOG_FILE")"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | [$AP_HOST] | $1" | tee -a "$LOG_FILE"
}

# 建立 SSH 連線指令 (有指定 SSH_KEY_PATH 就用指定的金鑰)
SSH_CMD="ssh -o StrictHostKeyChecking=no"
if [ -n "${SSH_KEY_PATH}" ]; then
    SSH_CMD="ssh -o StrictHostKeyChecking=no -i ${SSH_KEY_PATH}"
fi
S3_BUCKET="${S3_BUCKET%/}"
# 本地備份保留天數，預設 3 天
LOCAL_RETENTION_DAYS="${LOCAL_RETENTION_DAYS:-3}"

log "Starting Backup+Upload run using config: $CONFIG_FILE"
log "Local staging directory: $LOCAL_BACKUP_DIR (kept $LOCAL_RETENTION_DAYS days after upload)"

# 5. Main Loop
# 5. 主要迴圈：逐一處理 config 裡的每間公司 (IDS 陣列)
for ID in "${IDS[@]}"; do
    # Support "slug-taxid" style IDs (see configs/AP00X.conf), same
    # convention the wrapper generator uses.
    # 支援「客戶代稱-統編」格式的 ID (見 configs/AP00X.conf)，
    # 跟 2_generate_wrappers.sh 用的規則一致；沒有代稱就直接用統編。
    if [[ "$ID" == *-* ]]; then
        PURE_ID="${ID##*-}"
        S3_DEST_NAME="${ID}"
    else
        PURE_ID="${ID}"
        S3_DEST_NAME="${DNS:-ehrms2}_${ID}"
    fi

    FOLDER_NAME="ehrms2_${PURE_ID}"          # AP Server Source Folder            # AP 主機上的來源資料夾
    BACKUP_NAME="ehrms2_${PURE_ID}"          # Backup Server Destination Folder   # Backup Server 上的目的地資料夾

    log "Processing $PURE_ID ..."

    # --- 1. Pull (rsync) ---
    # --- 1. 從 AP 主機 pull 資料回來 (rsync) ---
    TIMESTAMP=$(date '+%Y%m%d%H%M%S')
    TARGET_DIR="$LOCAL_BACKUP_DIR/$BACKUP_NAME/$TIMESTAMP"
    mkdir -p "$TARGET_DIR"

    log "Rsyncing data from $AP_HOST ($FOLDER_NAME)..."
    # 依序同步 uploads(上傳檔案)、logs(系統紀錄) 兩個必要目錄，任何一個失敗都要
    # 記錄下來、跳過這間公司
    RSYNC_FAILED=0
    rsync -az -e "$SSH_CMD" "$REMOTE_USER@$AP_HOST:$REMOTE_BASE_DIR/$FOLDER_NAME/uploads/" "$TARGET_DIR/uploads/" || RSYNC_FAILED=1
    rsync -az -e "$SSH_CMD" "$REMOTE_USER@$AP_HOST:$REMOTE_BASE_DIR/$FOLDER_NAME/logs/" "$TARGET_DIR/logs/" || RSYNC_FAILED=1
    # .ssl（不是每間公司都一定有這個資料夾，失敗只記警告、不影響這間公司的備份）
    rsync -az -e "$SSH_CMD" "$REMOTE_USER@$AP_HOST:$REMOTE_BASE_DIR/$FOLDER_NAME/.ssl/" "$TARGET_DIR/.ssl/" \
        || log "Warning: rsync failed (.ssl) for $PURE_ID, continuing anyway."
    # App server logs（獨立實例，cwd=packages/@104ha/ehrms-max-app-api）
    rsync -az -e "$SSH_CMD" "$REMOTE_USER@$AP_HOST:$REMOTE_BASE_DIR/$FOLDER_NAME/packages/@104ha/ehrms-max-app-api/logs/" "$TARGET_DIR/logs_app/" || RSYNC_FAILED=1
    # OpenAPI server logs（獨立實例，cwd=packages/@104ha/open-api-server）
    # 不是每間公司都一定有這個獨立實例，失敗只記警告、不影響這間公司的備份
    rsync -az -e "$SSH_CMD" "$REMOTE_USER@$AP_HOST:$REMOTE_BASE_DIR/$FOLDER_NAME/packages/@104ha/open-api-server/logs/" "$TARGET_DIR/logs_openapi/" \
        || log "Warning: rsync failed (logs_openapi) for $PURE_ID, continuing anyway."

    if [ "$RSYNC_FAILED" -ne 0 ]; then
        log "Error during rsync for $PURE_ID. Skipping compression/upload."
        continue
    fi
    log "Rsync completed for $PURE_ID."

    # --- 2. Compress ---
    # --- 2. 壓縮成 tar.gz，壓縮完就把原始資料夾刪掉 (--remove-files) ---
    log "Compressing data..."
    ( cd "$LOCAL_BACKUP_DIR/$BACKUP_NAME" && tar -czf "$TIMESTAMP.tar.gz" "$TIMESTAMP" --remove-files )

    if [ $? -ne 0 ]; then
        log "Error during compression for $PURE_ID. Skipping upload."
        continue
    fi
    log "Compression successful: $TIMESTAMP.tar.gz"

    # --- 3. Upload immediately (no separate sync stage/folder) ---
    # --- 3. 壓縮完立刻上傳 S3 (不用另外排一個上傳階段/資料夾) ---
    log "Uploading $TIMESTAMP.tar.gz to S3..."
    aws s3 cp "$LOCAL_BACKUP_DIR/$BACKUP_NAME/$TIMESTAMP.tar.gz" "$S3_BUCKET/$S3_DEST_NAME/AP_Backup/$TIMESTAMP.tar.gz"

    if [ $? -eq 0 ]; then
        log "Upload successful for $PURE_ID. Keeping local copy for $LOCAL_RETENTION_DAYS days."
    else
        log "Error uploading $PURE_ID. Keeping local file for retry on next run."
    fi

    # Local retention: keep the last LOCAL_RETENTION_DAYS days on the backup
    # server as a quick restore copy (already uploaded to S3 regardless).
    # 本地保留：不論上傳成功與否，本地檔案都留著，
    # 只清掉超過 LOCAL_RETENTION_DAYS 天的舊檔(已經上傳過的快速還原副本、或反覆上傳失敗的殘留檔)。
    find "$LOCAL_BACKUP_DIR/$BACKUP_NAME" -name "*.tar.gz" -mtime "+${LOCAL_RETENTION_DAYS}" -delete

    echo "----------------------------------------" >> "$LOG_FILE"
done

log "All backup+upload tasks completed for $AP_HOST."
