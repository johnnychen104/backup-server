#!/bin/bash

# =================================================================
# Generic Backup Script: Pull Data, Compress, Upload to S3 (one shot)
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
# Usage: ./1_run_backup_and_upload.sh <path_to_config_file>
# =================================================================

CONFIG_FILE="$1"

# 1. Check Configuration
if [ -z "$CONFIG_FILE" ]; then
    echo "Error: No config file provided."
    echo "Usage: $0 <path_to_config_file>"
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Config file not found: $CONFIG_FILE"
    exit 1
fi

# 2. Load Configuration
source "$CONFIG_FILE"

# 3. Validate Required Variables
if [ -z "$AP_HOST" ] || [ -z "$IDS" ] || [ -z "$LOCAL_BACKUP_DIR" ] || [ -z "$S3_BUCKET" ]; then
    echo "Error: Config file missing required variables (AP_HOST, IDS, LOCAL_BACKUP_DIR, S3_BUCKET)."
    exit 1
fi

# 4. Setup Logging
LOG_FILE="${LOG_FILE:-/home/ubuntu/logs/backup_default.log}"
mkdir -p "$(dirname "$LOG_FILE")"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | [$AP_HOST] | $1" | tee -a "$LOG_FILE"
}

SSH_CMD="ssh -o StrictHostKeyChecking=no"
if [ -n "${SSH_KEY_PATH}" ]; then
    SSH_CMD="ssh -o StrictHostKeyChecking=no -i ${SSH_KEY_PATH}"
fi
S3_BUCKET="${S3_BUCKET%/}"

log "Starting Backup+Upload run using config: $CONFIG_FILE"
log "Local staging directory: $LOCAL_BACKUP_DIR"

# 5. Main Loop
for ID in "${IDS[@]}"; do
    # Support "slug-taxid" style IDs (see configs/AP00X.conf), same
    # convention the wrapper generator uses.
    if [[ "$ID" == *-* ]]; then
        PURE_ID="${ID##*-}"
        S3_DEST_NAME="${ID}"
    else
        PURE_ID="${ID}"
        S3_DEST_NAME="${DNS:-ehrms2}_${ID}"
    fi

    FOLDER_NAME="ehrms2_${PURE_ID}"          # AP Server Source Folder
    BACKUP_NAME="ehrms2_${PURE_ID}"          # Backup Server Destination Folder

    log "Processing $PURE_ID ..."

    # --- 1. Pull (rsync) ---
    TIMESTAMP=$(date '+%Y%m%d%H%M%S')
    TARGET_DIR="$LOCAL_BACKUP_DIR/$BACKUP_NAME/$TIMESTAMP"
    mkdir -p "$TARGET_DIR"

    log "Rsyncing data from $AP_HOST ($FOLDER_NAME)..."
    rsync -az -e "$SSH_CMD" "$REMOTE_USER@$AP_HOST:$REMOTE_BASE_DIR/$FOLDER_NAME/uploads/" "$TARGET_DIR/uploads/"
    rsync -az -e "$SSH_CMD" "$REMOTE_USER@$AP_HOST:$REMOTE_BASE_DIR/$FOLDER_NAME/logs/" "$TARGET_DIR/logs/"
    rsync -az -e "$SSH_CMD" "$REMOTE_USER@$AP_HOST:$REMOTE_BASE_DIR/$FOLDER_NAME/.ssl/" "$TARGET_DIR/.ssl/"

    if [ $? -ne 0 ]; then
        log "Error during rsync for $PURE_ID. Skipping compression/upload."
        continue
    fi
    log "Rsync completed for $PURE_ID."

    # --- 2. Compress ---
    log "Compressing data..."
    ( cd "$LOCAL_BACKUP_DIR/$BACKUP_NAME" && tar -czf "$TIMESTAMP.tar.gz" "$TIMESTAMP" --remove-files )

    if [ $? -ne 0 ]; then
        log "Error during compression for $PURE_ID. Skipping upload."
        continue
    fi
    log "Compression successful: $TIMESTAMP.tar.gz"

    # --- 3. Upload immediately (no separate sync stage/folder) ---
    log "Uploading $TIMESTAMP.tar.gz to S3..."
    aws s3 cp "$LOCAL_BACKUP_DIR/$BACKUP_NAME/$TIMESTAMP.tar.gz" "$S3_BUCKET/$S3_DEST_NAME/AP_Backup/$TIMESTAMP.tar.gz"

    if [ $? -eq 0 ]; then
        log "Upload successful for $PURE_ID."
        # Uploaded successfully -> no need to keep the local copy around.
        rm -f "$LOCAL_BACKUP_DIR/$BACKUP_NAME/$TIMESTAMP.tar.gz"
    else
        log "Error uploading $PURE_ID. Keeping local file for retry on next run."
    fi

    # Safety net: prune anything that repeatedly failed to upload and is going stale.
    find "$LOCAL_BACKUP_DIR/$BACKUP_NAME" -name "*.tar.gz" -mtime +2 -delete

    echo "----------------------------------------" >> "$LOG_FILE"
done

log "All backup+upload tasks completed for $AP_HOST."
