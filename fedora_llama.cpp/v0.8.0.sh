#!/usr/bin/env bash
# fedora_llama_cpp.sh
set -Ceo pipefail

readonly INSTALL_SCRIPT_PATH="$1"
readonly SSH_AGENT_INSTALL_PATH="/etc/profile.d/ssh-connection-agent.sh"

# LOGIN
mkdir -p ~/.ssh
chmod 700 ~/.ssh
echo "$PUBLIC_KEY" | tee -a ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
mkdir -p /etc/skel/.ssh
chmod 700 /etc/skel/.ssh
cp ~/.ssh/authorized_keys /etc/skel/.ssh/authorized_keys
chmod 600 /etc/skel/.ssh/authorized_keys

# PACKAGES
dnf distro-sync --assumeyes --quiet >/dev/null
dnf install vim-default-editor -y --allowerasing --assumeyes --quiet >/dev/null
dnf install @c-development @development-tools cmake sshd screen htop rustup yarnpkg openssl-devel inotify-tools crontabs rsyslog --assumeyes --quiet >/dev/null
npm install --global corepack


# SSH_AGENT_WATCHER
set -x
"$INSTALL_SCRIPT_PATH" "$SSH_AGENT_DATA_HASH" 1 10 \
    "$SSH_AGENT_SOURCE_URL" "$SSH_AGENT_INSTALL_PATH"
set +x
chmod 0755 "$SSH_AGENT_INSTALL_PATH"

# DEVELOP USER
useradd -m dev

# SERVICES
rsyslogd
crond

# CUDA
dnf config-manager addrepo --from-repofile=https://developer.download.nvidia.com/compute/cuda/repos/fedora41/x86_64/cuda-fedora41.repo
dnf download --destdir=/tmp/nvidia-driver-libs --resolve --arch x86_64 nvidia-driver-cuda nvidia-driver-libs nvidia-driver-cuda-libs nvidia-persistenced --quiet >/dev/null
rpm --install --verbose --hash --justdb /tmp/nvidia-driver-libs/* --quiet >/dev/null
rm -rf /tmp/nvidia-driver-libs
dnf install cuda --assumeyes --quiet >/dev/null
echo "export PATH=\$PATH:/usr/local/cuda/bin" | tee -a /etc/profile.d/cuda.sh
chmod +x /etc/profile.d/cuda.sh
source /etc/profile.d/cuda.sh
nvcc --version

# LLAMACPP
git clone --depth=1 https://github.com/ggerganov/llama.cpp.git /tmp/llama.cpp
cd /tmp/llama.cpp
cmake -B build -DGGML_CUDA=ON
cmake --build build --config Release -j 30
cmake --install build
cd ~
rm -rf /tmp/llama.cpp
echo "/usr/local/lib" | sudo tee /etc/ld.so.conf.d/local-lib.conf
echo "/usr/local/lib64" | sudo tee /etc/ld.so.conf.d/local-lib64.conf
ldconfig

# SCREEN
echo "termcapinfo xterm* ti@:te@" | tee -a /root/.screenrc

# SSHD
ssh-keygen -A
/usr/sbin/sshd
