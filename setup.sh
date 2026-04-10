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
dnf install -y wget git python3 python3-pip python3-devel net-tools unzip gcc-c++

# Install CUDA driver
dnf config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/amzn2023/x86_64/cuda-amzn2023.repo
rm -f /etc/yum.repos.d/cuda-rhel8*.repo
dnf clean all
dnf install -y nvidia-driver nvidia-driver-cuda libcublas-12-5
echo "### CUDA driver installed ###"

# Install git-lfs
curl -s https://packagecloud.io/install/repositories/github/git-lfs/script.rpm.sh | bash
dnf install -y git-lfs
sudo -u ec2-user HOME=/home/ec2-user git lfs install --skip-smudge

echo "### Downloading SDXL base model (~7GB) ###"
wget https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/resolve/main/sd_xl_base_1.0.safetensors \
  -O /home/ec2-user/stable-diffusion-webui/models/Stable-diffusion/sd_xl_base_1.0.safetensors

echo "### Downloading Realistic Vision V5.1 model ###"
wget https://huggingface.co/SG161222/Realistic_Vision_V5.1_noVAE/resolve/main/Realistic_Vision_V5.1_fp16-no-ema.safetensors \
  -O /home/ec2-user/stable-diffusion-webui/models/Stable-diffusion/Realistic_Vision_V5.1.safetensors

echo "### Models downloaded ###"

chown -R ec2-user:ec2-user /home/ec2-user

# Fix stablediffusion repo URL to use fork since Stability-AI repo no longer exists
sed -i 's|https://github.com/Stability-AI/stablediffusion.git|https://github.com/danbornman/stablediffusion.git|' \
  /home/ec2-user/stable-diffusion-webui/modules/launch_utils.py

# Clear commit hash since fork may have different commits
sed -i 's|stable_diffusion_commit_hash = os.environ.get.*STABLE_DIFFUSION_COMMIT_HASH.*|stable_diffusion_commit_hash = os.environ.get("STABLE_DIFFUSION_COMMIT_HASH", "")|' \
  /home/ec2-user/stable-diffusion-webui/modules/launch_utils.py

# Downgrade setuptools before venv build so CLIP installs correctly
source /home/ec2-user/stable-diffusion-webui/venv/bin/activate 2>/dev/null || true
pip install setuptools==59.8.0 2>/dev/null || true
deactivate 2>/dev/null || true

# First run to build venv and install all packages then exit
echo "### Building venv ###"
cd /home/ec2-user/stable-diffusion-webui
sudo -u ec2-user HOME=/home/ec2-user GIT_TERMINAL_PROMPT=0 \
  bash /home/ec2-user/stable-diffusion-webui/webui.sh --exit

# Fix venv ownership
chown -R ec2-user:ec2-user /home/ec2-user/stable-diffusion-webui/venv

# Apply package version fixes
echo "### Applying package fixes ###"
cd /home/ec2-user/stable-diffusion-webui
source venv/bin/activate

# Downgrade setuptools so pkg_resources is available for CLIP install
pip install setuptools==59.8.0

# Pin torch to 2.1.2
pip install torch==2.1.2+cu121 torchvision==0.16.2+cu121 \
  --extra-index-url https://download.pytorch.org/whl/cu121

# Fix httpx/httpcore/h11 conflict with gradio
pip install h11==0.12.0 httpcore==0.15.0 httpx==0.23.0

# Fix pytorch_lightning/torchmetrics conflict
pip install torchmetrics==0.11.4 pytorch-lightning==1.9.5

# Fix starlette/fastapi conflict
pip install starlette==0.22.0 fastapi==0.90.1

# Fix torchvision/basicsr conflict
sed -i 's/from torchvision.transforms.functional_tensor import rgb_to_grayscale/from torchvision.transforms.functional import rgb_to_grayscale/' \
  venv/lib64/python3.9/site-packages/basicsr/data/degradations.py 2>/dev/null || true

# Pre-download CLIP tokenizer
python3 -c "
from transformers import CLIPTokenizer, CLIPTextModel
CLIPTokenizer.from_pretrained('openai/clip-vit-large-patch14')
CLIPTextModel.from_pretrained('openai/clip-vit-large-patch14')
print('CLIP tokenizer downloaded successfully')
"

# Install insightface and onnxruntime for ReActor
pip install python3-devel 2>/dev/null || true
pip install insightface onnxruntime-gpu onnx==1.16.1

deactivate
echo "### Package fixes applied ###"

# Install ReActor extension
echo "### Installing ReActor extension ###"
cd /home/ec2-user/stable-diffusion-webui/extensions
GIT_TERMINAL_PROMPT=0 git clone https://github.com/Gourieff/sd-webui-reactor.git

# Fix ReActor install.py Python 3.9 compatibility
sed -i 's/version: str | None = None/version: Optional[str] = None/g' \
  /home/ec2-user/stable-diffusion-webui/extensions/sd-webui-reactor/install.py
sed -i '1s/^/from typing import Optional\n/' \
  /home/ec2-user/stable-diffusion-webui/extensions/sd-webui-reactor/install.py

# Install ReActor requirements
cd /home/ec2-user/stable-diffusion-webui/extensions/sd-webui-reactor
source /home/ec2-user/stable-diffusion-webui/venv/bin/activate
pip install -r requirements.txt --ignore-installed
deactivate

# Download inswapper model required by ReActor
echo "### Downloading inswapper model ###"
mkdir -p /home/ec2-user/stable-diffusion-webui/models/insightface
wget "https://huggingface.co/ezioruan/inswapper_128.onnx/resolve/main/inswapper_128.onnx" \
  -O /home/ec2-user/stable-diffusion-webui/models/insightface/inswapper_128.onnx

chown -R ec2-user:ec2-user /home/ec2-user

# Create start-webui.sh to handle path fixes on every boot
echo "### Creating start-webui.sh ###"
cat > /home/ec2-user/start-webui.sh << 'STARTSCRIPT'
#!/bin/bash
export GIT_TERMINAL_PROMPT=0
export HOME=/home/ec2-user
export PYTHONUNBUFFERED=1

echo "### Checking required repository files ###"

# Ensure taming-transformers is in Python path
echo "/home/ec2-user/stable-diffusion-webui/repositories/taming-transformers" > \
  /home/ec2-user/stable-diffusion-webui/venv/lib/python3.9/site-packages/taming.pth

# Ensure stable-diffusion repo is in Python path
echo "/home/ec2-user/stable-diffusion-webui/repositories/stable-diffusion-stability-ai" > \
  /home/ec2-user/stable-diffusion-webui/venv/lib/python3.9/site-packages/stable-diffusion.pth

# Ensure midas and correct attention.py are in place
if [ ! -d "/home/ec2-user/stable-diffusion-webui/repositories/stable-diffusion-stability-ai/ldm/modules/midas" ] || \
   ! grep -q "ATTENTION_MODES" "/home/ec2-user/stable-diffusion-webui/repositories/stable-diffusion-stability-ai/ldm/modules/attention.py" 2>/dev/null; then
  echo "### ldm files missing or outdated - restoring from fork ###"
  GIT_TERMINAL_PROMPT=0 git clone https://github.com/danbornman/stablediffusion.git /tmp/stablediffusion
  cp -r /tmp/stablediffusion/ldm/* \
    /home/ec2-user/stable-diffusion-webui/repositories/stable-diffusion-stability-ai/ldm/
  rm -rf /tmp/stablediffusion
  echo "### ldm restored ###"
fi

echo "### Launching Web UI ###"
cd /home/ec2-user/stable-diffusion-webui
bash /home/ec2-user/stable-diffusion-webui/webui.sh
STARTSCRIPT

chmod +x /home/ec2-user/start-webui.sh
chown ec2-user:ec2-user /home/ec2-user/start-webui.sh

# Set up systemd service to auto-start on boot
echo "### Setting up systemd service ###"
cat > /etc/systemd/system/sdwebui.service << 'SYSTEMD'
[Unit]
Description=Stable Diffusion Web UI
After=network.target

[Service]
Type=simple
User=ec2-user
WorkingDirectory=/home/ec2-user/stable-diffusion-webui
Environment=HOME=/home/ec2-user
Environment=PYTHONUNBUFFERED=1
Environment=GIT_TERMINAL_PROMPT=0
ExecStart=/bin/bash /home/ec2-user/start-webui.sh
Restart=on-failure
StandardOutput=append:/home/ec2-user/log.txt
StandardError=append:/home/ec2-user/log.txt

[Install]
WantedBy=multi-user.target
SYSTEMD

systemctl daemon-reload
systemctl enable sdwebui
systemctl start sdwebui

echo "### Setup complete. Monitor with: tail -f ~/log.txt ###"
echo "### Models available: ###"
echo "###   1. sd_xl_base_1.0         - SDXL (1024x1024)          ###"
echo "###   2. Realistic_Vision_V5.1  - Photorealistic (512x768)   ###"
