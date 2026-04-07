#!/bin/bash
set -ex
exec >> /var/log/user-data.log 2>&1
export GIT_TERMINAL_PROMPT=0
export HOME=/home/ec2-user

echo "################################################################"
echo "Starting setup.sh"
echo "################################################################"

# Install required packages
dnf update -y
dnf install -y wget git python3 python3-pip net-tools unzip \
  kernel-devel-$(uname -r) kernel-headers-$(uname -r)

# Install CUDA driver
dnf config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/amzn2023/x86_64/cuda-amzn2023.repo
rm -f /etc/yum.repos.d/cuda-rhel8*.repo
dnf clean all
dnf install -y nvidia-driver nvidia-driver-cuda

# Install git-lfs
curl -s https://packagecloud.io/install/repositories/github/git-lfs/script.rpm.sh | bash
dnf install -y git-lfs
sudo -u ec2-user HOME=/home/ec2-user git lfs install --skip-smudge

echo "################################################################"
echo "Downloading SD v2.1 model"
echo "################################################################"

cd /home/ec2-user
sudo -u ec2-user HOME=/home/ec2-user git clone --depth 1 \
  https://huggingface.co/Manojb/stable-diffusion-2-1-base
cd /home/ec2-user/stable-diffusion-2-1-base
sudo -u ec2-user HOME=/home/ec2-user git lfs pull --include "v2-1_512-ema-pruned.ckpt"
cd /home/ec2-user
mv stable-diffusion-2-1-base/v2-1_512-ema-pruned.ckpt \
  /home/ec2-user/stable-diffusion-webui/models/Stable-diffusion/
rm -rf /home/ec2-user/stable-diffusion-2-1-base

# Download matching config file
wget https://raw.githubusercontent.com/danbornman/stablediffusion/main/configs/stable-diffusion/v2-inference-v.yaml \
  -O /home/ec2-user/stable-diffusion-webui/models/Stable-diffusion/v2-1_512-ema-pruned.yaml

chown -R ec2-user:ec2-user /home/ec2-user

echo "################################################################"
echo "Launching Web UI"
echo "################################################################"

cd /home/ec2-user
sudo -u ec2-user HOME=/home/ec2-user \
  nohup bash /home/ec2-user/stable-diffusion-webui/webui.sh \
  > /home/ec2-user/log.txt 2>&1 &

echo "################################################################"
echo "Setup complete. Monitor progress with: tail -f /home/ec2-user/log.txt"
echo "################################################################"
