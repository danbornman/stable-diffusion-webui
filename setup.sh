#!/bin/bash
set -ex
exec >> /var/log/user-data.log 2>&1
export GIT_TERMINAL_PROMPT=0
export HOME=/home/ec2-user

echo "### Starting setup.sh ###"

# Create 8GB swap file to prevent OOM kills during model loading
dd if=/dev/zero of=/swapfile bs=128M count=64
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile swap swap defaults 0 0' >> /etc/fstab
echo "### Swap created ###"

# Install packages
dnf update -y
dnf install -y wget git python3 python3-pip net-tools unzip

# Install CUDA driver
dnf config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/amzn2023/x86_64/cuda-amzn2023.repo
rm -f /etc/yum.repos.d/cuda-rhel8*.repo
dnf clean all
dnf install -y nvidia-driver nvidia-driver-cuda
echo "### CUDA driver installed ###"

# Install git-lfs
curl -s https://packagecloud.io/install/repositories/github/git-lfs/script.rpm.sh | bash
dnf install -y git-lfs
sudo -u ec2-user HOME=/home/ec2-user git lfs install --skip-smudge

echo "### Downloading SD v2.1 model ###"

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
echo "### Model downloaded ###"

# First run to build venv and install all packages then exit
echo "### Building venv ###"
cd /home/ec2-user
sudo -u ec2-user HOME=/home/ec2-user \
  bash /home/ec2-user/stable-diffusion-webui/webui.sh --exit

# Apply package version fixes
echo "### Applying package fixes ###"
cd /home/ec2-user/stable-diffusion-webui
source venv/bin/activate

# Pin torch to 2.1.2 - newer versions break model loading
pip install torch==2.1.2+cu121 torchvision==0.16.2+cu121 \
  --extra-index-url https://download.pytorch.org/whl/cu121

# Fix httpx/httpcore conflict with gradio 3.9
pip install h11==0.12.0 httpcore==0.15.0 httpx==0.23.0

# Fix pytorch_lightning/torchmetrics conflict
pip install torchmetrics==0.11.4 pytorch-lightning==1.9.5

# Fix torchvision/basicsr conflict
sed -i 's/from torchvision.transforms.functional_tensor import rgb_to_grayscale/from torchvision.transforms.functional import rgb_to_grayscale/' \
  venv/lib64/python3.9/site-packages/basicsr/data/degradations.py

deactivate
echo "### Package fixes applied ###"

# Launch webui
echo "### Launching Web UI ###"
cd /home/ec2-user
sudo -u ec2-user HOME=/home/ec2-user \
  nohup bash /home/ec2-user/stable-diffusion-webui/webui.sh \
  > /home/ec2-user/log.txt 2>&1 &

echo "### Setup complete. Monitor with: tail -f ~/log.txt ###"
