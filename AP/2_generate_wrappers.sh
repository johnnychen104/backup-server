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

# -----------------------------------------------------------------
# 0. S3 客戶資料夾標記
#    DB 備份腳本(104DB_backup_rds_hrmax00X.sh)靠「bucket 最上層已有 *-<統編>/ 資料夾」
#    決定上傳位置。新客戶在 AP 第一次備份前 bucket 還沒有資料夾，DB 備份(03:00)會
#    比 AP 備份(04:00 起)先跑而 FAIL，所以安裝(跑本產生器)時就先建好 0 byte 標記
#    <英文簡稱>-<統編>/ ，DB 備份就不需要再維護 ehrms2_backup_rds_s3_map.txt。
#    - bucket 已有同統編的資料夾 → 不建(避免出現兩個同統編資料夾，DB 備份會 FAIL)
#    - 沒有英文簡稱的項目 → 略過並警告
#    - 失敗只警告，不中斷 wrapper 產生
#    用法：./2_generate_wrappers.sh            建標記並產生 wrapper
#          ./2_generate_wrappers.sh --dry-run  只預覽會建哪些標記，不建、也不產生 wrapper
# -----------------------------------------------------------------
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

ensure_s3_markers() {
    local pairs B ID CUST MATCH LISTING="" LISTED_BUCKET="" CREATED=0 EXISTS=0 SKIPPED=0
    pairs=$(for CF in "$CONFIG_DIR"/*.conf; do
        [ -e "$CF" ] || continue
        ( source "$CF"; for ID in "${IDS[@]}"; do echo "${S3_BUCKET%/} $ID"; done )
    done)
    [ -n "$pairs" ] || return 0

    while read -r B ID; do
        [ -n "$ID" ] || continue
        if [[ "$ID" != *-* ]]; then
            echo "  [S3 marker] WARN 沒有英文簡稱，略過：${ID}（請確認 S3 資料夾名稱）"; SKIPPED=$((SKIPPED+1)); continue
        fi
        if [ "$B" != "$LISTED_BUCKET" ]; then
            if ! LISTING=$(aws s3 ls "$B/" 2>/dev/null | awk '{print $2}'); then
                echo "  [S3 marker] WARN 無法列出 $B，略過所有標記建立"; return 0
            fi
            LISTED_BUCKET="$B"
        fi
        CUST="${ID##*-}"
        MATCH=$(printf '%s\n' "$LISTING" | grep -E -- "-${CUST}/$" || true)
        if [ -n "$MATCH" ]; then
            EXISTS=$((EXISTS+1))
            [ "$MATCH" = "${ID}/" ] || echo "  [S3 marker] WARN bucket 已有 ${MATCH}，與 config 的 ${ID} 不同，不建標記"
            continue
        fi
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "  [S3 marker] DRY-RUN 會建立：${B}/${ID}/"; CREATED=$((CREATED+1)); continue
        fi
        if aws s3api put-object --bucket "${B#s3://}" --key "${ID}/" >/dev/null 2>&1; then
            echo "  [S3 marker] 已建立：${B}/${ID}/"; CREATED=$((CREATED+1))
            LISTING="${LISTING}"$'\n'"${ID}/"
        else
            echo "  [S3 marker] WARN 建立失敗：${B}/${ID}/（不影響 wrapper 產生；DB 備份可能 FAIL，請手動處理）"
        fi
    done <<< "$pairs"
    echo "  [S3 marker] 已存在 ${EXISTS}、$([ "$DRY_RUN" -eq 1 ] && echo 預計建立 || echo 已建立) ${CREATED}、略過 ${SKIPPED}"
}

echo "Checking S3 customer folder markers..."
ensure_s3_markers
if [ "$DRY_RUN" -eq 1 ]; then
    echo "Dry-run: 未產生任何 wrapper。"
    exit 0
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
            OLD_SYNC_SCRIPT="$WRAPPER_DIR/s3sync.sh"

            mkdir -p "$WRAPPER_DIR"

            # 舊版(兩階段)產生器會多留一支 s3sync.sh，現在 104AP_backup.sh
            # 已經把上傳合併進去了，不需要它，清掉舊客戶資料夾裡的殘留檔
            # 避免混淆(新客戶不會有這支檔案，這是正常、預期的)。
            if [ -f "$OLD_SYNC_SCRIPT" ]; then
                rm -f "$OLD_SYNC_SCRIPT"
                echo "  -> Removed stale s3sync.sh from old two-stage design: $OLD_SYNC_SCRIPT"
            fi

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
REMOTE_USER="${REMOTE_USER:-ubuntu}"
REMOTE_BASE_DIR="$REMOTE_BASE_DIR"
SSH_KEY_PATH="${SSH_KEY_PATH}"
ID="$PURE_ID"
LOCAL_BACKUP_DIR="$LOCAL_BACKUP_DIR"
S3_BUCKET="${S3_BUCKET%/}"
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

# .ssl（不是每間公司都一定有這個資料夾，失敗只記警告、不中斷整支備份）
rsync -az -e "\$SSH_CMD" "\${REMOTE_USER}@\${AP_HOST}:\${REMOTE_BASE_DIR}/\${FOLDER_NAME}/.ssl/"     "\$TARGET_DIR/.ssl/"     || echo "[Wrapper] Warning: Rsync failed (.ssl), continuing anyway."

# App server logs（獨立實例，cwd=packages/@104ha/ehrms-max-app-api）
rsync -az -e "\$SSH_CMD" "\${REMOTE_USER}@\${AP_HOST}:\${REMOTE_BASE_DIR}/\${FOLDER_NAME}/packages/@104ha/ehrms-max-app-api/logs/" "\$TARGET_DIR/logs_app/" || { echo "[Wrapper] Error: Rsync failed (logs_app)."; exit 1; }

# OpenAPI server logs（獨立實例，cwd=packages/@104ha/open-api-server）
# 失敗只記警告、不中斷整支備份
rsync -az -e "\$SSH_CMD" "\${REMOTE_USER}@\${AP_HOST}:\${REMOTE_BASE_DIR}/\${FOLDER_NAME}/packages/@104ha/open-api-server/logs/" "\$TARGET_DIR/logs_openapi/" || echo "[Wrapper] Warning: Rsync failed (logs_openapi), continuing anyway."

# 2. Compress（zstd -3 單執行緒；2026-11-13 實測比 gzip -6 省 56% 時間、壓縮階段 CPU 約 51% → 20%）
cd "\${LOCAL_BACKUP_DIR}/\${BACKUP_NAME}"
tar -I 'zstd -3 -T1' -cf "\${TIMESTAMP}.tar.zst" "\${TIMESTAMP}" --remove-files

if [ \$? -ne 0 ]; then
    echo "[Wrapper] Error: Compression failed."
    exit 1
fi
echo "[Wrapper] Backup Success: \${TIMESTAMP}.tar.zst"

# 3. Upload immediately (no separate sync stage / staging folder)
echo "[Wrapper] Uploading \${TIMESTAMP}.tar.zst to S3..."
if aws s3 cp "\${LOCAL_BACKUP_DIR}/\${BACKUP_NAME}/\${TIMESTAMP}.tar.zst" "\${S3_BUCKET}/\${S3_DEST_NAME}/AP_Backup/\${TIMESTAMP}.tar.zst"; then
    echo "[Wrapper] S3 Upload Success. Keeping local copy for ${LOCAL_RETENTION_DAYS:-3} days."
else
    echo "[Wrapper] Error: S3 Upload failed. Keeping local file for retry on next run."
fi

# 4. Local retention: keep the last ${LOCAL_RETENTION_DAYS:-3} days on the
#    backup server as a quick restore copy (already uploaded to S3 either way).
#    find -mtime 會捨去小數，+N 實際會留 N+1 份，所以用 N-1 才是「含今天共 N 份」。
#    切換 zstd 期間 .tar.gz 與 .tar.zst 並存，兩種都清；舊 .tar.gz 全部過期後可拿掉第一行。
find "\${LOCAL_BACKUP_DIR}/\${BACKUP_NAME}" -type f -name "*.tar.gz" -mtime +$(( ${LOCAL_RETENTION_DAYS:-3} - 1 )) -delete
find "\${LOCAL_BACKUP_DIR}/\${BACKUP_NAME}" -type f -name "*.tar.zst" -mtime +$(( ${LOCAL_RETENTION_DAYS:-3} - 1 )) -delete
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
