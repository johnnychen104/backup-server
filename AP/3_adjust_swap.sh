1) swapon --show
2) sudo swapoff -a && sudo rm -f /swapfile && sudo fallocate -l 8G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile && sudo sed -i '/\/swapfile none swap sw 0 0/d' /etc/fstab && echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
3) swapon --show && free -h
