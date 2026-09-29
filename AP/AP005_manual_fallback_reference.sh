#!/bin/bash
# [Generated Wrapper for Backup Server - Pull Mode]
# Target AP: 193.168.8.35
# Company ID: 70771944
# Real Storage: /mnt/AP005_backup

# 定義變數
AP_HOST="193.168.8.35"
REMOTE_USER="ubuntu"
REMOTE_BASE_DIR="/home/ubuntu"
SSH_KEY_PATH="/home/ubuntu/johnny.pem"
ID="70771944"
LOCAL_BACKUP_DIR="/mnt/AP005_backup"

FOLDER_NAME="ehrms2_70771944"
BACKUP_NAME="ehrms2_70771944"

# 產生時間戳記 (模擬原本邏輯)
TIMESTAMP=$(date '+%Y%m%d%H%M%S')
TARGET_DIR="${LOCAL_BACKUP_DIR}/${BACKUP_NAME}/${TIMESTAMP}"

echo "[Wrapper] Starting Pull Backup for $ID from $AP_HOST..."
echo "[Wrapper] Saving to: $TARGET_DIR"

mkdir -p "$TARGET_DIR"

# 1. Rsync (Pull)
# 檢查是否有指定 SSH Key
SSH_CMD="ssh -o StrictHostKeyChecking=no"
if [ -n "${SSH_KEY_PATH}" ]; then
    SSH_CMD="ssh -o StrictHostKeyChecking=no -i ${SSH_KEY_PATH}"
fi

# 依序嘗試常見目錄，避免遠端實際目錄層級不同時直接失敗
REMOTE_ROOT_CANDIDATES=(
    "${REMOTE_BASE_DIR}/${FOLDER_NAME}"
    "${REMOTE_BASE_DIR}/AP005/${FOLDER_NAME}"
    "${REMOTE_BASE_DIR}/ehrms2_backup_${ID}/${FOLDER_NAME}"
    "${REMOTE_BASE_DIR}/ehrms2_backup_${ID}"
)

sync_section() {
    section="$1"
    local_target="$2"

    for remote_root in "${REMOTE_ROOT_CANDIDATES[@]}"; do
        remote_path="${remote_root}/${section}/"
        echo "[Wrapper] Trying: ${remote_path}"

        if rsync -az -e "$SSH_CMD" "${REMOTE_USER}@${AP_HOST}:${remote_path}" "$local_target"; then
            echo "[Wrapper] Synced ${section} from ${remote_root}"
            return 0
        fi
    done

    echo "[Wrapper] Error: Rsync failed (${section}). Tried all candidate paths."
    return 1
}

sync_section "uploads" "$TARGET_DIR/uploads/" || exit 1
sync_section "logs" "$TARGET_DIR/logs/" || exit 1
sync_section ".ssl" "$TARGET_DIR/.ssl/" || exit 1


# 2. Compress (Tar)
cd "${LOCAL_BACKUP_DIR}/${BACKUP_NAME}"
tar -czf "${TIMESTAMP}.tar.gz" "${TIMESTAMP}" --remove-files

if [ $? -eq 0 ]; then
    echo "[Wrapper] Backup Success: ${TIMESTAMP}.tar.gz"
else
    echo "[Wrapper] Error: Compression failed."
    exit 1
fi