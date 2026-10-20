# DB 備份 (RDS mysqldump + Upload)

> **⚠️ 2026-10-20 更新：本目錄的 `1_run_db_backup_and_upload.sh` 與 `configs/` 已過時，不要部署。**
> 線上實際架構、變更紀錄與新客戶上線步驟見 [CHANGELOG.md](CHANGELOG.md)。

從 RDS (`hrmax001`、`hrmax003`) 對每間公司的 schema 跑 `mysqldump`，壓縮後**立刻上傳 S3**，
本地備份檔保留 3 天(`LOCAL_RETENTION_DAYS`，預設 3)當作快速還原用的副本，過期才清掉，
不是上傳成功就立刻刪(跟 AP 端做法一致)。

## ⚠️ 重要：`1_run_db_backup_and_upload.sh` 是重建版，部署前要驗證

實際在備份伺服器上執行的 `104DB_backup_rds_hrmax001.sh` / `104DB_backup_rds_hrmax003.sh`
(被 `BackUp/104DB_backupAll_rds_hrmax001.sh` / `_hrmax003.sh` 逐間公司呼叫) 這兩支腳本的
本體，從頭到尾都沒有被收進這個安裝包資料夾 —— 資料夾裡只有「呼叫它們的清單檔」，本體
只存在備份伺服器上。

`1_run_db_backup_and_upload.sh` 是依照最接近的既有範本
(`BackUp/104DB_backup_DB002.sh`，會清掉 dump 內容裡 `DEFINER=` 的那個版本) 重建的，
並把原本另外用 `BackUp/hrmax003` 那份手動維護的 `aws s3 sync` 清單做的上傳動作，
合併進同一支腳本、同一次迴圈裡立刻執行。**部署前務必跟備份伺服器上真正在跑的版本
比對一次**，確認沒有遺漏原本的行為(例如既有的 log 記錄方式、保留天數等)。

## 檔案

| 檔案 | 用途 |
| --- | --- |
| `1_run_db_backup_and_upload.sh` | 讀一個 config，逐間公司 dump→壓縮→上傳→本地保留 3 天 |
| `configs/hrmax001.conf` | hrmax001 的公司清單 (ID → slug-統編 對應) |
| `configs/hrmax003.conf` | hrmax003 的公司清單 |
| `crontab_example.txt` | crontab 設定範例 |
| `rds-hrmax001.md` / `rds-hrmax003.md` | 該 RDS 實例目前有哪些 database 的參考清單 |

## 用法

```bash
DB_PASSWORD='...' ./1_run_db_backup_and_upload.sh configs/hrmax001.conf
```

密碼**不要**寫進 `configs/*.conf`(這兩個檔案會進 git)，用環境變數帶入，或是另外準備一份
不進 git 的 `.secrets/hrmax001_pw` 之類的檔案在 crontab 裡讀取，見 `crontab_example.txt`。

## config 裡的公司對應是重建的，有幾筆待驗證

`configs/hrmax001.conf` 與 `configs/hrmax003.conf` 的 `IDS` 清單，是拿
`BackupServer_Deploy/hrmax001-databases` / `hrmax003-databases` (RDS 上實際
`SHOW DATABASES` 的結果) 去對照 AP 那邊的 `configs/AP00*.conf` 統編清單、以及
`BackUp/hrmax003` 裡本來就有的上傳對應關係，重建出來的。找不到對應公司代稱的統編
會標註 `# no slug mapping found - verify`，上傳路徑會 fallback 用裸統編命名 —
部署前建議找熟悉客戶清單的人核對一次，其中 `88888888` 看起來像測試用的 schema。

## 這次改了什麼(相對於舊版 `BackUp/`)

- 舊版是兩段式：`104DB_backup_rds_hrmax00X.sh` 只負責 dump 到本地
  `/mnt/rds_hrmax00X_backup/`，上傳是另外一份手動維護、逐行 `aws s3 sync` 的清單檔
  (`BackUp/hrmax003`，且 hrmax001 從沒有對應的清單檔)，執行時機也跟 dump 分開。
- 新版把 dump→壓縮→上傳 合併進同一支腳本、同一次迴圈，不再需要另外維護一份上傳清單，
  也不會讓 dump 出來的檔案在本地等一段時間才被上傳。上傳後本地備份檔一樣保留 3 天
  (`LOCAL_RETENTION_DAYS`)當作快速還原副本，超過天數才由排程清掉。
- `BackUp/` 裡的 `104DB_backup_DB001.sh` / `DB002.sh` / `DB003.sh`
  (含 `_import` 版本) 是本機 MariaDB(非 RDS)時代的版本，判斷已不是目前架構在用，
  沒有搬進這個 repo；如果 DB001/002/003 這幾台機器還在運作中，需要另外確認是否仍要保留。
