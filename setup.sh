#!/bin/bash
set -ex
exec >> /var/log/user-data.log 2>&1
export GIT_TERMINAL_PROMPT=0
export HOME=/home/ec2-user

echo "################################################################"
echo "Starting setup.sh"
echo "################################################################"

# Install required packages
# Amazon Linux uses dnf, not apt-get
dnf update -y
dnf install -y wget git python3 python3-pip net-tools unzip kernel-devel-$(uname -r) kernel-headers-$(uname -r)

# Install CUDA driver and toolkit via package manager
# Using dnf is more reliable than the .run installer as it handles
# kernel and gcc version compatibility automatically
dnf config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/amzn2023/x86_64/cuda-amzn2023.repo

# Remove any stale rhel8 repo that may have been added previously
rm -f /etc/yum.repos.d/cuda-rhel8*.repo

dnf clean all
dnf install -y nvidia-driver nvidia-driver-cuda

# Install git-lfs
# Amazon Linux uses the rpm script, not the deb script
curl -s https://packagecloud.io/install/repositories/github/git-lfs/script.rpm.sh | bash
dnf install -y git-lfs
sudo -u ec2-user HOME=/home/ec2-user git lfs install --skip-smudge

echo "################################################################"
echo "Downloading SD v2.1 model"
echo "################################################################"

# Download the SD v2.1 model from HuggingFace and move it to the models directory
cd /data
sudo -u ec2-user HOME=/home/ec2-user git clone --depth 1 https://huggingface.co/Manojb/stable-diffusion-2-1-base
cd /data/stable-diffusion-2-1-base
sudo -u ec2-user HOME=/home/ec2-user git lfs pull --include "v2-1_512-ema-pruned.ckpt"
cd /data
mv stable-diffusion-2-1-base/v2-1_512-ema-pruned.ckpt /data/stable-diffusion-webui/models/Stable-diffusion/
rm -rf stable-diffusion-2-1-base/

# Download the matching config file for the SD v2.1 model
# The config filename must match the model filename exactly
wget https://raw.githubusercontent.com/danbornman/stablediffusion/main/configs/stable-diffusion/v2-inference-v.yaml \
  -O /data/stable-diffusion-webui/models/Stable-diffusion/v2-1_512-ema-pruned.yaml

# Give ec2-user ownership of everything in /data
chown -R ec2-user:ec2-user /data

echo "################################################################"
echo "Configuring and starting Web UI"
echo "################################################################"

# Enable --listen in webui-user.sh so the UI is accessible from outside the instance
# sed -i 's/#export COMMANDLINE_ARGS=""/export COMMANDLINE_ARGS="--listen"/' \
#   /data/stable-diffusion-webui/webui-user.sh

# Clean up the bad venv first
rm -rf /home/ec2-user/stable-diffusion-webui

# Start the web UI as ec2-user in the background
# Logs go to /data/log.txt - tail this file to monitor startup progress
cd /data
sudo -u ec2-user HOME=/home/ec2-user \
  nohup bash /data/stable-diffusion-webui/webui.sh > /data/log.txt 2>&1 &

echo "################################################################"
echo "Setup complete. Monitor progress with: tail -f /data/log.txt"
echo "################################################################"
