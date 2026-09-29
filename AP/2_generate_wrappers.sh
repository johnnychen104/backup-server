#!/bin/bash

# =================================================================
# Wrapper Generator for Backup Server
# 功能: 讀取 configs/*.conf，並在 Backup Server 上建立與 AP Server
#       路徑一致的「代理腳本」(Wrapper Script)。
#
#       每個統編只會產生「一支」腳本 (104AP_backup.sh)，內含：
#         Pull (rsync) -> Compress (tar) -> Upload (S3) -> Cleanup
#       一次跑完，不再需要獨立的 s3sync.sh 與第二階段排程，
#       備份完成後就直接上傳，不會有一堆等待上傳的暫存 tar.gz。
# =================================================================

BASE_DIR="$(dirname "$0")"
CONFIG_DIR="$BASE_DIR/configs"

if [ ! -d "$CONFIG_DIR" ]; then
    echo "Error: Config directory not found at $CONFIG_DIR"
    exit 1
fi

echo "Starting Wrapper Generation..."

for CONFIG_FILE in "$CONFIG_DIR"/*.conf; do
    [ -e "$CONFIG_FILE" ] || continue

    (
        source "$CONFIG_FILE"

        if [ -z "$AP_HOST" ] || [ -z "$IDS" ]; then
            echo "Skipping invalid config: $CONFIG_FILE"
            exit 0
        fi

        FILENAME="${CONFIG_FILE##*/}"
        AP_NAME="${FILENAME%.*}"

        if [ -z "$AP_NAME" ]; then
            echo "Error: Failed to extract AP_NAME from $CONFIG_FILE"
            exit 1
        fi

        DNS_PREFIX="${DNS:-ehrms2}"
        echo "Processing Config: $CONFIG_FILE (AP: $AP_HOST, Name: $AP_NAME)"
        echo "  -> Using DNS/Prefix: $DNS_PREFIX"

        RUN_ALL_LIST=()

        for ID in "${IDS[@]}"; do
            if [[ "$ID" == *-* ]]; then
                local_number="${ID##*-}"
                S3_DEST_NAME="${ID}"
                PURE_ID="${local_number}"
                BACKEND_FOLDER_NAME="ehrms2_${local_number}"
            else
                PURE_ID="${ID}"
                S3_DEST_NAME="${DNS_PREFIX}_${ID}"
                BACKEND_FOLDER_NAME="ehrms2_${PURE_ID}"
            fi

            WRAPPER_DIR="/home/ubuntu/${AP_NAME}/ehrms2_backup_${PURE_ID}"
            BACKUP_SCRIPT="$WRAPPER_DIR/104AP_backup.sh"

            mkdir -p "$WRAPPER_DIR"

            # ==========================================
            # 產生合併版 Backup+Upload 代理腳本
            # ==========================================
            cat > "$BACKUP_SCRIPT" <<EOF
#!/bin/bash
# [Generated Wrapper for Backup Server - Pull + Compress + Upload]
# Target AP: $AP_HOST
# AP Name: $AP_NAME
# Company ID: $PURE_ID

AP_HOST="$AP_HOST"
REMOTE_USER="\${REMOTE_USER:-ubuntu}"
REMOTE_BASE_DIR="$REMOTE_BASE_DIR"
SSH_KEY_PATH="${SSH_KEY_PATH}"
ID="$PURE_ID"
LOCAL_BACKUP_DIR="$LOCAL_BACKUP_DIR"
S3_BUCKET="\${S3_BUCKET%/}"
S3_DEST_NAME="${S3_DEST_NAME}"

FOLDER_NAME="${BACKEND_FOLDER_NAME}"
BACKUP_NAME="${BACKEND_FOLDER_NAME}"

TIMESTAMP=\$(date '+%Y%m%d%H%M%S')
TARGET_DIR="\${LOCAL_BACKUP_DIR}/\${BACKUP_NAME}/\${TIMESTAMP}"

echo "[Wrapper] Starting Pull Backup for \$ID from \$AP_HOST..."
echo "[Wrapper] Saving to: \$TARGET_DIR"

mkdir -p "\$TARGET_DIR"

SSH_CMD="ssh -o StrictHostKeyChecking=no"
if [ -n "\${SSH_KEY_PATH}" ]; then
    SSH_CMD="ssh -o StrictHostKeyChecking=no -i \${SSH_KEY_PATH}"
fi

# 1. Pull (rsync)
rsync -az -e "\$SSH_CMD" "\${REMOTE_USER}@\${AP_HOST}:\${REMOTE_BASE_DIR}/\${FOLDER_NAME}/uploads/" "\$TARGET_DIR/uploads/" || { echo "[Wrapper] Error: Rsync failed (uploads)."; exit 1; }
rsync -az -e "\$SSH_CMD" "\${REMOTE_USER}@\${AP_HOST}:\${REMOTE_BASE_DIR}/\${FOLDER_NAME}/logs/"    "\$TARGET_DIR/logs/"    || { echo "[Wrapper] Error: Rsync failed (logs).";    exit 1; }
rsync -az -e "\$SSH_CMD" "\${REMOTE_USER}@\${AP_HOST}:\${REMOTE_BASE_DIR}/\${FOLDER_NAME}/.ssl/"     "\$TARGET_DIR/.ssl/"     || { echo "[Wrapper] Error: Rsync failed (.ssl).";     exit 1; }

# 2. Compress
cd "\${LOCAL_BACKUP_DIR}/\${BACKUP_NAME}"
tar -czf "\${TIMESTAMP}.tar.gz" "\${TIMESTAMP}" --remove-files

if [ \$? -ne 0 ]; then
    echo "[Wrapper] Error: Compression failed."
    exit 1
fi
echo "[Wrapper] Backup Success: \${TIMESTAMP}.tar.gz"

# 3. Upload immediately (no separate sync stage / staging folder)
echo "[Wrapper] Uploading \${TIMESTAMP}.tar.gz to S3..."
if aws s3 cp "\${LOCAL_BACKUP_DIR}/\${BACKUP_NAME}/\${TIMESTAMP}.tar.gz" "\${S3_BUCKET}/\${S3_DEST_NAME}/AP_Backup/\${TIMESTAMP}.tar.gz"; then
    echo "[Wrapper] S3 Upload Success. Keeping local copy for ${LOCAL_RETENTION_DAYS:-3} days."
else
    echo "[Wrapper] Error: S3 Upload failed. Keeping local file for retry on next run."
fi

# 4. Local retention: keep the last ${LOCAL_RETENTION_DAYS:-3} days on the
#    backup server as a quick restore copy (already uploaded to S3 either way).
find "\${LOCAL_BACKUP_DIR}/\${BACKUP_NAME}" -type f -name "*.tar.gz" -mtime +${LOCAL_RETENTION_DAYS:-3} -delete
find "\${LOCAL_BACKUP_DIR}/\${BACKUP_NAME}" -mindepth 1 -maxdepth 1 -type d -mtime +1 -exec rm -rf {} +
exit 0
EOF
            chmod +x "$BACKUP_SCRIPT"
            echo "  -> Created Backup+Upload Wrapper: $BACKUP_SCRIPT"

            RUN_ALL_LIST+=("\"$BACKUP_SCRIPT\"")
        done

        RUN_ALL_DIR="/home/ubuntu/backups"
        mkdir -p "$RUN_ALL_DIR"

        RUN_ALL_SCRIPT="${RUN_ALL_DIR}/run_all_104AP_backups_${AP_NAME}.sh"
        cat > "$RUN_ALL_SCRIPT" <<EOF
#!/bin/bash
# [Generated Wrapper for Backup Server - Run All (Backup+Upload) for ${AP_NAME}]

LOG_DIR="/home/ubuntu/backups_logs/${AP_NAME}"
LOG_FILE="\$LOG_DIR/all_backups_${AP_NAME}_\$(date '+%Y-%m-%d').log"
mkdir -p "\$LOG_DIR"

find "\$LOG_DIR" -type f -name "all_backups_${AP_NAME}_*.log" -mtime +2 -delete

log() {
    echo "\$(date '+%Y-%m-%d %H:%M:%S') | \$1" | tee -a "\$LOG_FILE"
}

log "Starting all backups (pull+compress+upload) for ${AP_NAME}..."

scripts=(
$(printf '%s\n' "${RUN_ALL_LIST[@]}")
)

for script in "\${scripts[@]}"; do
    if [ -f "\$script" ]; then
        log "Running \$script..."
        "\$script"
    else
        log "Error: Script not found: \$script"
    fi
done

log "All tasks finished."
EOF
        chmod +x "$RUN_ALL_SCRIPT"
        echo "  -> Created Run-All Script: $RUN_ALL_SCRIPT"
    )
done

echo "---------------------------------------------------"
echo "Wrapper generation complete."
echo "Each generated 104AP_backup.sh now pulls, compresses AND uploads in one run."
echo "You only need ONE cron entry per AP (run_all_104AP_backups_<AP_NAME>.sh)."
echo "---------------------------------------------------"
