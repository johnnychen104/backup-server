#!/usr/bin/env bash
# =================================================================
# 產生 DB 備份用的 S3 客戶資料夾對照檔 ehrms2_backup_rds_s3_map.txt
#
# 來源：../AP/configs/*.conf 的 IDS=( "<英文簡稱>-<統編>" ... )
# 新客戶只需要加進 AP config，不用再手動維護對照檔。
#
# 用法：
#   ./gen_s3_map.sh                      只產生到 ./out/ehrms2_backup_rds_s3_map.txt 並檢查重複
#   ./gen_s3_map.sh --diff <現行對照檔>   另外比對現行檔(先自備份機 scp 回來)：列出新增 / 只在現行檔的項目
#   ./gen_s3_map.sh --merge <現行對照檔>  產生「現行檔 ∪ AP config」，只會新增、不會刪除既有項目
#
# 本腳本只在本機產生檔案，不連任何主機；上傳到 DB 備份機請另外 scp。
# =================================================================
set -u

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
AP_CONF_DIR="$BASE_DIR/../AP/configs"
OUT_DIR="$BASE_DIR/out"
OUT_FILE="$OUT_DIR/ehrms2_backup_rds_s3_map.txt"
MODE="plain"
CURRENT=""

case "${1:-}" in
    --diff)  MODE="diff";  CURRENT="${2:-}" ;;
    --merge) MODE="merge"; CURRENT="${2:-}" ;;
    "")      ;;
    *) echo "Usage: $0 [--diff|--merge <現行對照檔>]"; exit 1 ;;
esac
if [ "$MODE" != "plain" ] && [ ! -f "$CURRENT" ]; then
    echo "Error: 找不到現行對照檔：$CURRENT"; exit 1
fi

mkdir -p "$OUT_DIR"
TMP_AP="$(mktemp)"; trap 'rm -f "$TMP_AP" "$TMP_AP.cur" "$TMP_AP.all" "$TMP_AP.ok"' EXIT

# 1. 從各 AP config 取出 IDS 內的 "<英文簡稱>-<統編>"
for f in "$AP_CONF_DIR"/*.conf; do
    awk '/^IDS=\(/{f=1;next} f&&/^\)/{f=0} f&&/^[ \t]*"/{gsub(/[" \t\r]/,""); print}' "$f"
done | sort -u > "$TMP_AP"

# 2. 格式檢查：必須是 <英文簡稱>-<8 位統編>
BAD=$(grep -Ev '^[A-Za-z0-9_-]+-[0-9]{8}$' "$TMP_AP" || true)
if [ -n "$BAD" ]; then
    echo "WARN: 以下項目沒有英文簡稱或格式不符 <英文簡稱>-<8位統編>，已排除、不寫入對照檔，請確認："
    echo "$BAD" | sed 's/^/  /'
    grep -E '^[A-Za-z0-9_-]+-[0-9]{8}$' "$TMP_AP" > "$TMP_AP.ok"; mv "$TMP_AP.ok" "$TMP_AP"
fi

# 3. 同一統編出現多個英文簡稱 = 對照檔會被視為 FAIL
DUP=$(awk -F- '{print $NF}' "$TMP_AP" | sort | uniq -d || true)
if [ -n "$DUP" ]; then
    echo "ERROR: 以下統編在 AP config 出現多個英文簡稱："
    for t in $DUP; do grep -- "-$t\$" "$TMP_AP" | sed 's/^/  /'; done
    exit 1
fi

# 4. 與現行檔比對 / 合併
if [ "$MODE" != "plain" ]; then
    tr -d '\r' < "$CURRENT" | grep -Ev '^[ \t]*(#|$)' | sort -u > "$TMP_AP.cur"
    echo "AP config：$(wc -l < "$TMP_AP") 筆；現行對照檔：$(wc -l < "$TMP_AP.cur") 筆"
    echo "--- 只在 AP config（合併後會新增）---"; comm -23 "$TMP_AP" "$TMP_AP.cur" | sed 's/^/  + /'
    echo "--- 只在現行對照檔（AP config 沒有；merge 會保留）---"; comm -13 "$TMP_AP" "$TMP_AP.cur" | sed 's/^/  = /'
    # 同統編不同簡稱 (現行檔 vs AP config)
    sort -u "$TMP_AP" "$TMP_AP.cur" > "$TMP_AP.all"
    CONFLICT=$(awk -F- '{print $NF}' "$TMP_AP.all" | sort | uniq -d || true)
    if [ -n "$CONFLICT" ]; then
        echo "ERROR: 現行檔與 AP config 對同一統編的英文簡稱不一致："
        for t in $CONFLICT; do grep -- "-$t\$" "$TMP_AP.all" | sed 's/^/  /'; done
        exit 1
    fi
fi

# 5. 輸出
SRC="$TMP_AP"; [ "$MODE" = "merge" ] && SRC="$TMP_AP.all"
{
    echo "# S3 客戶資料夾對照檔（格式：<英文簡稱>-<統編>，# 開頭為註解）"
    echo "# 由 gen_s3_map.sh 自 AP/configs/*.conf 產生，$(date '+%Y-%m-%d')；請改 AP config，不要直接改此檔"
    cat "$SRC"
} > "$OUT_FILE"
echo "已產生：${OUT_FILE}（$(grep -vc '^#' "$OUT_FILE") 筆，模式：${MODE}）"
