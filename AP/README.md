# AP 備份 (Pull + Compress + Upload)

從各台 AP 主機 (AP001~AP005) 用 rsync pull 回 `uploads/`、`logs/`、`.ssl/`，
在 Backup Server 上壓縮成 `tar.gz`，**壓縮完立刻上傳 S3**，本地備份檔保留 3 天
(`LOCAL_RETENTION_DAYS`，預設 3)當作快速還原用的副本，過期才清掉，不是上傳成功就立刻刪。

## 檔案

| 檔案 | 用途 |
| --- | --- |
| `0_setup_env.sh` | Backup Server 環境初始化 (Ubuntu 24.04 ~ 26.04) |
| `1_run_backup_and_upload.sh` | 通用版：吃一個 config，逐間公司 pull→壓縮→上傳→本地保留 3 天 |
| `2_generate_wrappers.sh` | 讀 `configs/*.conf`，幫每間公司產生獨立的 wrapper script + 每台 AP 一支 run-all |
| `3_adjust_swap.sh` | 調整 swap 大小的指令備忘 |
| `configs/AP001.conf` ~ `AP005.conf` | 每台 AP 的連線資訊、公司清單、S3 bucket |
| `crontab_example.txt` | crontab 設定範例 |
| `CWdashboard.json` | CloudWatch Dashboard 設定 |

## 兩種用法都可以，正式環境目前是用「產生 wrapper」

1. **產生 wrapper (正式環境用這個)**：

   ```bash
   ./2_generate_wrappers.sh
   ```

   會依照 `configs/*.conf` 在 `/home/ubuntu/<AP_NAME>/ehrms2_backup_<ID>/104AP_backup.sh`
   產生「每間公司一支、pull+壓縮+上傳一次做完」的腳本，並在
   `/home/ubuntu/backups/run_all_104AP_backups_<AP_NAME>.sh` 產生該台 AP 的彙總腳本。
   crontab 只需要排這支彙總腳本(見 `crontab_example.txt`)，**每台 AP 一行就好，不用再
   多排一個 S3 sync 的排程**。

   新增/異動客戶時，照舊作法：把客戶加進對應的 `configs/AP00X.conf`，再重跑
   `./2_generate_wrappers.sh` 一次 — 它會把**該台 AP 底下所有客戶**的 wrapper
   全部重新產生、覆蓋掉舊檔(不是只加新客戶那一份)，這是預期行為，直接覆蓋即可。

2. **手動/單次跑 (不想先產生 wrapper 時)**：

   ```bash
   ./1_run_backup_and_upload.sh configs/AP001.conf
   ```

## 這次改了什麼(相對於舊版 `BackupServer_Deploy/`)

- 舊版是兩階段：`1_run_pull_backup.sh` 只 pull+壓縮，`2_run_s3_sync.sh` 另外排在
  之後幾小時上傳；`3_generate_wrappers.sh` 產生的 wrapper 也是分成
  `104AP_backup.sh` + `s3sync.sh` 兩支。這會讓本地累積一個「等待上傳」的暫存資料夾，
  而且所有公司的上傳集中在同一個排程時間點一起打 S3。
- 新版把 pull→壓縮→上傳 合併進同一支腳本、同一次迴圈，上傳流量自然分散在整個跑批
  過程，不再需要獨立的「等待上傳」資料夾或第二段排程。本地的 tar.gz 上傳後仍保留
  3 天(`LOCAL_RETENTION_DAYS`)當作快速還原副本，超過天數才由排程清掉。
- 刪除了兩支功能重疊、線上只有一支在用的產生器 (`3_generate_wrapper.sh` 單數版
  是舊的 AP005 專用草稿，已刪除；`cat 3_generate_wrappers.sh` 是誤植的殘留檔，也已刪除)。
- `BackupServer_Deploy/run_all_104AP_backups.sh` 與 `run_all_s3sync.sh` 是舊產生器
  "production 執行後留下的產物"，內容是舊架構產生的結果，跟著舊架構一起淘汰；正式環境
  改用 `2_generate_wrappers.sh` 重新產生即可，不需要手動維護這兩個檔案。

## 已知待處理

- `AP005` 實際部署過一份手動修過的版本 (原檔在 `BackUp/AP005`)，因為 AP005 的遠端目錄
  結構跟其他 AP 不太一樣，原本的版本會依序嘗試好幾種可能路徑
  (`REMOTE_ROOT_CANDIDATES`) 才 rsync 成功。目前的 `2_generate_wrappers.sh`
  還是假設單一固定路徑；如果重新產生 AP005 的 wrapper 導致 rsync 失敗，記得把
  那段「依序嘗試路徑」的邏輯加回去。
