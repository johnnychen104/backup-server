# DB 備份伺服器 變更紀錄

## 線上實際架構（2026-10-20 確認）

- 主機：`hrmax-customer-DB-backup-server`（sys31 / ap-northeast-1 / `i-0dee0336386b22024`，私有 IP 193.168.8.19，用 SSM 連線）
- **以伺服器上的腳本為準**。本目錄的 `1_run_db_backup_and_upload.sh` 與 `configs/*.conf` 是 9/29 在拿不到線上檔時重建的版本，已過時，**不要部署**。

| RDS | 目錄 | 排程（ubuntu crontab） |
|---|---|---|
| hrmax001 | `/home/ubuntu/ehrms2_backup_rds_hrmax001/` | `_log` 03:00、`_2h` 03:03、`_1h` 03:06 並行 |
| hrmax003 | `/home/ubuntu/ehrms2_backup_rds_hrmax003/` | 同上 |
| hrmax004 | `/home/ubuntu/ehrms2_backup_rds_hrmax004/` | `_log` 03:00、`_1h` 03:06 |

- `104DB_backupAll_rds_hrmax00X_{log,1h,2h}.sh`：逐間公司呼叫核心腳本的清單（含 DB 連線參數，勿收進 git）
- `104DB_backup_rds_hrmax00X.sh`：核心腳本，三台只差 `backupPath`
  - **第 1～104 行（參數、mysqldump、逐表 dump）不可修改**，只能動後面的壓縮／保存／上傳
  - 壓縮後立即上傳 S3；本機每個 DB 保留最新 3 份 `.tar`；有任何一份上傳失敗就不清理，下次執行會補傳
- S3 路徑：
  - 客戶 DB → `s3://hrmax-backup-singapore/<英文簡稱>-<統編>/DB_Backup/`
  - 系統 DB（`ehrms2_log`、`ehrms2_default`、`ehrms2_kpi001`）→ `s3://hrmax-backup-singapore/RDS-hrmax00X/<DB名>/`
- S3 客戶資料夾對照檔：`/home/ubuntu/ehrms2_backup_rds_s3_map.txt`（格式：每行一個資料夾名 `<英文簡稱>-<統編>`，`#` 開頭為註解）
- Bucket lifecycle：所有物件 7 天後轉 GLACIER，1827 天後刪除

### 新客戶上線

1. 在對應 RDS 的 `_1h.sh` 或 `_2h.sh` 加一行呼叫
2. 在 `/home/ubuntu/ehrms2_backup_rds_s3_map.txt` 加一行 `<英文簡稱>-<統編>`
   - 英文簡稱要跟 AP 備份用的一致（例：`umedia-27375986`）
   - bucket 已有 `*-<統編>/` 資料夾時以 bucket 為準；沒有才查對照檔建立新路徑；兩邊都查不到 → 不上傳、本機保留、log 印 FAIL

---

## 2026-10-20

### 1. 核心腳本：新客戶可依對照檔建立 S3 資料夾
- 問題：10/15 版只會用統編去 bucket 找既有資料夾，找不到就不上傳；新客戶沒有英文簡稱可用（只寫在 `s3sync.sh`），要等 AP 備份先建出資料夾，DB 備份最快隔天才補傳
- 修改：S3 路徑判斷改為「bucket 唯一資料夾 → 對照檔 → FAIL 保留本機」；bucket 有多個符合仍視為 FAIL
- 範圍：只動上傳段（約第 121 行起），第 1～104 行已用 md5 確認與原檔相同
- 原檔備份：`104DB_backup_rds_hrmax00{1,3,4}.sh.bak.20261020`
- 對照檔初版 108 筆，來源為三支 `s3sync.sh` + bucket 既有資料夾，已逐筆與 bucket 比對無衝突
- 同日改版：對照檔格式由 `<統編> <英文簡稱>` 改為 `<英文簡稱>-<統編>`（直接等於 S3 資料夾名）；對照檔同統編多筆視為 FAIL；可容忍註解行與 CRLF
  - 改版前備份：`104DB_backup_rds_hrmax00{1,3,4}.sh.bak.20261020b`、`ehrms2_backup_rds_s3_map.txt.bak.20261020b`

### 2. 停用 08:00 `s3sync.sh`
- 核心腳本 10/15 起已即時上傳，`s3sync.sh` 變成重複上傳，且清單已與實際 dump 清單不一致
- hrmax003 的 `s3sync.sh` 有 29 間寫到小寫 `DB_backup/`，造成 10/15 後同一份備份在 S3 存兩份
- crontab 三行 `s3sync.sh` 已註解；原 crontab 備份：`/home/ubuntu/crontab.bak.20261020`
- 腳本檔本身保留未刪

### 3. S3 清理
- 刪除 10/15 後 `s3sync` 重複寫入 `DB_backup/` 的 145 個檔（255.6 GB，29 間客戶）；刪前逐一確認 `DB_Backup/` 有同名同大小檔、且仍為 STANDARD
- 刪除 `grobesttaiwan-83395697/DB_backup/ehrms2_83395697-20261015075334/`（394 檔，6.87 GB）：10/15 08:00 `s3sync` 在 dump 進行中同步到的未壓縮半成品；完整 tar 在 `DB_Backup/`

### 4. 決定：舊路徑資料不搬移
- S3 上客戶 DB 備份有三種路徑：`DB-Backup/`（約 5 TB）、`DB_backup/`（約 6.2 TB）、`DB_Backup/`（約 15 TB，現行）
- 舊檔幾乎都已在 GLACIER，搬移需先解凍、會產生取回與提前刪除費，且複製會重設 lifecycle 起算日（5 年到期延後）
- 決定：只統一新寫入路徑為 `DB_Backup/`，舊路徑不再新增，由 lifecycle 自然到期；還原時依檔名 `ehrms2_<統編>-<時間>.tar` 到三個路徑找

### 待辦
- [ ] 2026-10-21 08:00 後確認三台 RDS 的 03:00 備份都已上傳到 `DB_Backup/`（新版首次執行，且已無 `s3sync` 補傳）
- [ ] 清掉 hrmax003 未使用的 `104_control.sh`（8/3 舊版，無任何腳本呼叫）
- [ ] 核心腳本 166～181 行註解掉的舊保留邏輯可清除
- [ ] 把線上腳本（去除密碼）收進本 repo，取代 `1_run_db_backup_and_upload.sh` 重建版
- [ ] 密碼目前明碼寫在 wrapper 命令列（`ps` 看得到），可改用 `~/.my.cnf`
