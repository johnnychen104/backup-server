# backup-server

備份伺服器(Backup Server)的完整部署套件，獨立成一個 repo，方便追蹤變更與版本管理。

分成兩個方向，對應兩種不同的來源機器：

| 方向 | 說明 | 詳細文件 |
|---|---|---|
| [AP/](AP/README.md) | 從各台 AP 主機 (AP001~AP005) pull 回 uploads/logs/.ssl，壓縮後上傳 S3 | [AP/README.md](AP/README.md) |
| [DB/](DB/README.md) | 從 RDS (hrmax001、hrmax003) mysqldump 出各公司資料庫，上傳 S3 | [DB/README.md](DB/README.md) |

## 這次重整做了什麼

1. **整併重複腳本**：原本 `BackupServer_Deploy/` 裡有兩支功能重疊的 `3_generate_wrapper.sh`
   (單數，AP005 專用) 與 `3_generate_wrappers.sh`(複數，通用版，線上實際使用的版本)，
   以及一支明顯是誤植的 `cat 3_generate_wrappers.sh`。整理後只保留線上真正在用的版本
   (改名為 `AP/2_generate_wrappers.sh`)。同樣地 `Backup_Scripts/` 底下的
   `backup_server_run_all_backups.sh`／`backup_server_run_all_s3sync.sh` 是帶
   `[請修改]` 註記的舊草稿模板，功能已被 `AP/1_run_backup_and_upload.sh` 取代。
2. **AP 與 DB 兩個方向分開**：`BackupServer_Deploy/` 與 `Backup_Scripts/` 的內容對應 AP
   (pull 模式)；`BackUp/` 裡的 `104DB_backup_rds_hrmax001.sh` / `hrmax003.sh` 呼叫鏈對應
   DB (RDS mysqldump)。`BackUp/` 裡其餘 `104DB_backup_DB001.sh`／`DB002.sh`／`DB003.sh`
   是更早期、本機 MariaDB(非 RDS)時代的版本，判斷已不是目前架構在用的，沒有搬進這個 repo。
3. **備份完成後直接上傳**：這是這次重整的重點。舊設計是「兩階段」——先把所有公司的資料
   pull/dump 到本地，累積成一個暫存資料夾，等排程的第二階段(或是像 `BackUp/hrmax003`
   那樣手動維護的一長串 `aws s3 sync` 清單)再一次全部上傳。新設計把 pull/dump →
   壓縮 → 上傳 S3 → 清本地，合併成「每間公司」跑一次的單一流程，不再需要暫存的
   「上傳資料夾」，S3 上傳流量也會分散在整個跑批過程中，而不是集中在同一個時間點對
   S3 打一堆平行請求，減輕單一機器在同一時刻的網路/CPU 壓力。

## 目錄結構

```
backup-server/
├── AP/                     # AP 主機備份 (pull + compress + upload)
│   ├── 0_setup_env.sh
│   ├── 1_run_backup_and_upload.sh   # 通用版，讀 config 逐間公司跑
│   ├── 2_generate_wrappers.sh       # 依 configs/*.conf 產生每間公司的 wrapper
│   ├── 3_adjust_swap.sh
│   ├── configs/AP001.conf ~ AP005.conf
│   ├── crontab_example.txt
│   ├── CWdashboard.json
│   └── README.md
└── DB/                     # RDS 備份 (mysqldump + upload)
    ├── 1_run_db_backup_and_upload.sh  # DRAFT - 見 DB/README.md 的重要警告
    ├── configs/hrmax001.conf, hrmax003.conf
    ├── crontab_example.txt
    ├── rds-hrmax001.md, rds-hrmax003.md
    └── README.md
```

## 尚待確認/後續事項

- **DB 側的核心 dump 腳本目前是重建版，不是照抄線上原始檔**：因為
  `104DB_backup_rds_hrmax001.sh` / `hrmax003.sh` 本體從沒被收進這個安裝包資料夾裡
  (只有呼叫它的 `104DB_backupAll_rds_*.sh` 清單檔)，實際內容只存在備份伺服器上。
  部署前務必比對 `DB/1_run_db_backup_and_upload.sh` 跟伺服器上真正在跑的版本，
  確認沒有遺漏原本的行為。
- `DB/configs/*.conf` 裡有幾個統編找不到對應的公司代稱(標了 `# no slug mapping
  found - verify`)，上傳路徑會 fallback 用裸統編命名，建議照 `109. Testing` 前
  跟熟悉客戶清單的人核對一次。
- 密碼一律不寫進 `configs/*.conf`，用環境變數或另外一份不進 git 的檔案帶入
  (兩邊 README 都有範例)。
