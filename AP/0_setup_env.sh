#!/bin/bash

# =================================================================
# Backup Server Initialization Script (Ubuntu 24.04 ~ 26.04)
# 備份伺服器環境初始化腳本 (支援 Ubuntu 24.04 ~ 26.04)
# =================================================================

echo "Starting Backup Server Setup..."
echo "開始設定 Backup Server 環境..."

# 0. Check OS version (informational only, does not block setup)
# 0. 檢查作業系統版本 (僅供參考，不會中斷安裝)
if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo "Detected OS: ${PRETTY_NAME:-unknown}"
    echo "偵測到的作業系統：${PRETTY_NAME:-未知}"
    if [ "${ID:-}" = "ubuntu" ]; then
        MAJOR_VERSION="${VERSION_ID%%.*}"
        if [ "${MAJOR_VERSION:-0}" -lt 24 ] 2>/dev/null || [ "${MAJOR_VERSION:-0}" -gt 26 ] 2>/dev/null; then
            echo "Warning: this script is written for Ubuntu 24.04 ~ 26.04, current version is ${VERSION_ID}. Continuing anyway."
            echo "警告：這支腳本是針對 Ubuntu 24.04 ~ 26.04 撰寫，目前偵測到版本為 ${VERSION_ID}，仍會繼續執行。"
        fi
    else
        echo "Warning: this does not look like Ubuntu (ID=${ID:-unknown}). Continuing anyway."
        echo "警告：偵測到的作業系統似乎不是 Ubuntu (ID=${ID:-未知})，仍會繼續執行。"
    fi
fi

# 1. Update System
# 1. 更新系統套件
sudo apt-get update && sudo apt-get upgrade -y

# 2. Install Required Tools
# 2. 安裝所需工具
# aws-cli: For S3 sync            aws-cli：用來同步/上傳資料到 S3
# rsync: For pulling data         rsync：用來從 AP 主機 pull 資料回來
# zip/unzip: General utility      zip/unzip：一般壓縮工具
echo "Installing dependencies..."
echo "安裝相依套件..."
sudo apt-get install -y awscli rsync zip unzip

# 3. Create Directories
# 3. 建立所需目錄
echo "Creating directories..."
echo "建立目錄..."
mkdir -p /home/ubuntu/backups
mkdir -p /home/ubuntu/logs
mkdir -p /home/ubuntu/scripts

# 4. Setup Permissions
# 4. 設定資料夾權限
chown -R ubuntu:ubuntu /home/ubuntu/backups
chown -R ubuntu:ubuntu /home/ubuntu/logs
chown -R ubuntu:ubuntu /home/ubuntu/scripts

echo "Setup Complete!"
echo "環境設定完成！"
echo "---------------------------------------------------"
echo "Next Steps:"
echo "後續步驟："
echo "1. Copy the backup scripts to /home/ubuntu/scripts/"
echo "   把備份腳本複製到 /home/ubuntu/scripts/"
echo "2. Configure AWS CLI: 'aws configure'"
echo "   設定 AWS CLI：執行 'aws configure'"
echo "3. Setup SSH Key: Copy private key to ~/.ssh/id_rsa and chmod 600"
echo "   設定 SSH 金鑰：把私鑰複製到 ~/.ssh/id_rsa 並 chmod 600"
echo "4. Run 2_generate_wrappers.sh to generate per-company wrapper scripts"
echo "   執行 2_generate_wrappers.sh，產生每間公司的 wrapper 腳本"
echo "5. Add the generated run_all_*.sh scripts (or 1_run_backup_and_upload.sh) to crontab"
echo "   把產生出來的 run_all_*.sh(或 1_run_backup_and_upload.sh)加進 crontab"
echo "---------------------------------------------------"
