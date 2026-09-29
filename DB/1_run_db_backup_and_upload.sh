#!/bin/bash

# =================================================================
# !! DRAFT - VERIFY BEFORE DEPLOYING !!
#
# The scripts actually invoked in production (104DB_backup_rds_hrmax001.sh /
# 104DB_backup_rds_hrmax003.sh, called per-company from
# 104DB_backupAll_rds_hrmax001.sh / _hrmax003.sh) were not present in this
# local install package - they only exist on the DB backup EC2 instance
# itself. This script reconstructs the same dump behaviour from the closest
# known template (BackUp/104DB_backup_DB002.sh, the DEFINER-stripped
# version) and folds in the upload step that was previously a separate,
# manually maintained list (BackUp/hrmax003 - a batch of `aws s3 sync`
# lines run some time after the dump). Diff this against the live script
# on the backup server (or fetch it and replace this file) before relying
# on it for production backups.
#
# Design goal: same as the AP side - dump a company, upload it, delete the
# local copy, move to the next company. No more "dump everything for this
# RDS instance, then separately upload everything later" - that's what
# created the pile of local dumps + the standalone hrmax003 upload list.
#
# Usage: ./1_run_db_backup_and_upload.sh <path_to_config_file>
#   Requires DB_PASSWORD to be set in the environment (do not commit
#   passwords into configs/*.conf).
# =================================================================

CONFIG_FILE="$1"

if [ -z "$CONFIG_FILE" ] || [ ! -f "$CONFIG_FILE" ]; then
    echo "Usage: $0 <path_to_config_file>"
    exit 1
fi

source "$CONFIG_FILE"

if [ -z "$DB_HOST" ] || [ -z "$IDS" ] || [ -z "$LOCAL_BACKUP_DIR" ] || [ -z "$S3_BUCKET" ]; then
    echo "Error: Config file missing required variables (DB_HOST, IDS, LOCAL_BACKUP_DIR, S3_BUCKET)."
    exit 1
fi

if [ -z "$DB_PASSWORD" ]; then
    echo "Error: DB_PASSWORD not set in environment. Export it before running, e.g.:"
    echo "  DB_PASSWORD='...' ./1_run_db_backup_and_upload.sh $CONFIG_FILE"
    exit 1
fi

LOG_FILE="${LOG_FILE:-/home/ubuntu/logs/db_backup_$(basename "$CONFIG_FILE" .conf).log}"
mkdir -p "$(dirname "$LOG_FILE")"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | [$DB_HOST] | $1" | tee -a "$LOG_FILE"
}

mysql_dump_exe=/usr/bin/mysqldump
mysql_exe=/usr/bin/mysql
S3_BUCKET="${S3_BUCKET%/}"

backup_one() {
    local ID="$1"
    local S3_DEST_NAME DB_NAME

    if [[ "$ID" == ehrms2_* ]]; then
        # already a literal schema name (system schema, e.g. ehrms2_default)
        S3_DEST_NAME="$ID"
        DB_NAME="$ID"
    elif [[ "$ID" == *-* ]]; then
        S3_DEST_NAME="$ID"
        DB_NAME="ehrms2_${ID##*-}"
    else
        S3_DEST_NAME="ehrms2_${ID}"
        DB_NAME="ehrms2_${ID}"
    fi

    log "Processing $DB_NAME ..."

    TIMESTAMP=$(date '+%Y%m%d%H%M%S')
    TARGET_FOLDER="$LOCAL_BACKUP_DIR/$DB_NAME/$DB_NAME-$TIMESTAMP"
    mkdir -m 755 -p "$TARGET_FOLDER"

    # sp/function
    $mysql_dump_exe --host="$DB_HOST" --user="$DB_USER" --password="$DB_PASSWORD" \
        --single-transaction --no-data --skip-triggers --no-create-db --no-create-info \
        --routines --comments "$DB_NAME" > "$TARGET_FOLDER/1_sp_fn.sql"
    sed -i 's/DEFINER=[^[:space:]]*[[:space:]]*//g' "$TARGET_FOLDER/1_sp_fn.sql"

    # schema
    $mysql_dump_exe --host="$DB_HOST" --user="$DB_USER" --password="$DB_PASSWORD" \
        --single-transaction --no-data "$DB_NAME" > "$TARGET_FOLDER/2_Schema.sql"
    sed -i 's/DEFINER=[^[:space:]]*[[:space:]]*//g' "$TARGET_FOLDER/2_Schema.sql"

    # data
    $mysql_dump_exe --host="$DB_HOST" --user="$DB_USER" --password="$DB_PASSWORD" \
        --single-transaction "$DB_NAME" > "$TARGET_FOLDER/3_Alldata.sql"
    sed -i 's/DEFINER=[^[:space:]]*[[:space:]]*//g' "$TARGET_FOLDER/3_Alldata.sql"

    # events
    $mysql_dump_exe --host="$DB_HOST" --user="$DB_USER" --password="$DB_PASSWORD" \
        --single-transaction --no-data --skip-triggers --no-create-db --no-create-info \
        --events --comments "$DB_NAME" > "$TARGET_FOLDER/4_event.sql"
    sed -i 's/DEFINER=[^[:space:]]*[[:space:]]*//g' "$TARGET_FOLDER/4_event.sql"

    if [ $? -ne 0 ]; then
        log "Error dumping $DB_NAME. Skipping upload."
        return 1
    fi
    log "Dump complete for $DB_NAME."

    # compress
    ( cd "$LOCAL_BACKUP_DIR/$DB_NAME" && tar -czf "$DB_NAME-$TIMESTAMP.tar.gz" "$DB_NAME-$TIMESTAMP" --remove-files )
    if [ $? -ne 0 ]; then
        log "Error compressing $DB_NAME."
        return 1
    fi

    # upload immediately (no separate sync stage / staging list)
    log "Uploading $DB_NAME-$TIMESTAMP.tar.gz to S3..."
    if aws s3 cp "$LOCAL_BACKUP_DIR/$DB_NAME/$DB_NAME-$TIMESTAMP.tar.gz" \
        "$S3_BUCKET/$S3_DEST_NAME/DB_backup/$DB_NAME-$TIMESTAMP.tar.gz"; then
        log "Upload successful for $DB_NAME."
        rm -f "$LOCAL_BACKUP_DIR/$DB_NAME/$DB_NAME-$TIMESTAMP.tar.gz"
    else
        log "Error uploading $DB_NAME. Keeping local file for retry on next run."
    fi

    # optional: log into ehrms2_log via sp_util_LogBackup, best-effort
    $mysql_exe -u"$DB_USER" -h"$DB_HOST" -p"$DB_PASSWORD" "$DBLOG_NAME" -N \
        -e "call sp_util_LogBackup('$DB_NAME','s3','$S3_BUCKET/$S3_DEST_NAME/DB_backup/','$DB_NAME-$TIMESTAMP.tar.gz','0','$(date '+%Y-%m-%d %H:%M:%S')');" \
        2>>"$LOG_FILE"

    # safety net for anything that repeatedly failed to upload
    find "$LOCAL_BACKUP_DIR/$DB_NAME" -mindepth 1 -mtime +2 \( -type f -o -type d \) -exec rm -rf -- {} +
}

log "Starting DB backup+upload run using config: $CONFIG_FILE"

for ID in "${IDS[@]}"; do
    backup_one "$ID"
    echo "----------------------------------------" >> "$LOG_FILE"
done

for SCHEMA in "${SYSTEM_SCHEMAS[@]}"; do
    backup_one "$SCHEMA"
    echo "----------------------------------------" >> "$LOG_FILE"
done

log "All DB backup+upload tasks completed for $DB_HOST."
