#!/bin/bash

# =================================================================
# Backup Server Initialization Script (Ubuntu 24.04)
# =================================================================

echo "Starting Backup Server Setup..."

# 1. Update System
sudo apt-get update && sudo apt-get upgrade -y

# 2. Install Required Tools
# aws-cli: For S3 sync
# rsync: For pulling data
# zip/unzip: General utility
echo "Installing dependencies..."
sudo apt-get install -y awscli rsync zip unzip

# 3. Create Directories
echo "Creating directories..."
mkdir -p /home/ubuntu/backups
mkdir -p /home/ubuntu/logs
mkdir -p /home/ubuntu/scripts

# 4. Setup Permissions
chown -R ubuntu:ubuntu /home/ubuntu/backups
chown -R ubuntu:ubuntu /home/ubuntu/logs
chown -R ubuntu:ubuntu /home/ubuntu/scripts

echo "Setup Complete!"
echo "---------------------------------------------------"
echo "Next Steps:"
echo "1. Copy the backup scripts to /home/ubuntu/scripts/"
echo "2. Configure AWS CLI: 'aws configure'"
echo "3. Setup SSH Key: Copy private key to ~/.ssh/id_rsa and chmod 600"
echo "4. Run 2_generate_wrappers.sh to generate per-company wrapper scripts"
echo "5. Add the generated run_all_*.sh scripts (or 1_run_backup_and_upload.sh) to crontab"
echo "---------------------------------------------------"
