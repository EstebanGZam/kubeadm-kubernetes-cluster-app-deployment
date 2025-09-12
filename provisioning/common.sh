#!/bin/bash

# IMPROVED: Common script to prepare Kubernetes nodes with enhanced reliability

set -e

echo "=== COMMON KUBERNETES NODE PREPARATION ==="

# Variables
LOG_FILE="/var/log/k8s-provision.log"
exec > >(tee -a $LOG_FILE) 2>&1

echo "$(date): Starting common configuration"

# Update system
echo "Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y

# Permanently disable swap
echo "Disabling swap permanently..."
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# Remove swap file completely if it exists
rm -f /swap.img

# Disable swap in systemd-swap if present
systemctl stop systemd-swap 2>/dev/null || true
systemctl disable systemd-swap 2>/dev/null || true

# Ensure swap is really disabled
echo "Verifying swap is disabled..."
if free | grep -q "Swap:.*[1-9]"; then
    echo "WARNING: Swap still appears to be enabled"
    free -h
    echo "Contents of /proc/swaps:"
    cat /proc/swaps
else
    echo "✅ Swap successfully disabled"
fi

# Configure kernel modules for Kubernetes
echo "Configuring kernel modules..."
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

# Verify modules are loaded
lsmod | grep overlay || echo "WARNING: overlay module not loaded"
lsmod | grep br_netfilter || echo "WARNING: br_netfilter module not loaded"

# Configure system parameters for Kubernetes with VirtualBox optimizations
echo "Configuring network parameters..."
cat <<EOF | tee /etc/sysctl.d/k8s.conf
# Core Kubernetes requirements
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1

# Enhanced networking for VirtualBox
net.ipv4.conf.all.forwarding        = 1
net.ipv4.conf.all.rp_filter         = 0
net.ipv4.conf.default.rp_filter     = 0
net.ipv4.conf.eth0.rp_filter        = 0
net.ipv4.conf.eth1.rp_filter        = 0

# Connection tracking optimizations
net.netfilter.nf_conntrack_max       = 1000000
net.netfilter.nf_conntrack_tcp_timeout_established = 86400

# Memory and file descriptor limits
fs.inotify.max_user_instances        = 8192
fs.inotify.max_user_watches          = 1048576
fs.file-max                          = 2097152

# Network buffer optimizations
net.core.rmem_max                    = 16777216
net.core.wmem_max                    = 16777216
net.ipv4.tcp_rmem                    = 4096 87380 16777216
net.ipv4.tcp_wmem                    = 4096 16384 16777216
EOF

sysctl --system

# Configure improved firewall settings
echo "Configuring firewall with comprehensive rules..."
apt-get install -y ufw

# Reset and configure UFW
ufw --force reset
ufw --force enable

# Essential access
ufw allow ssh
ufw allow from 10.0.2.0/24   # VirtualBox NAT network
ufw allow from 192.168.56.0/24  # VirtualBox host-only network

# Kubernetes networks
ufw allow from 10.244.0.0/16    # Pod network (Flannel)
ufw allow from 10.96.0.0/12     # Service network

# Kubernetes control plane ports
ufw allow 6443/tcp              # API server
ufw allow 2379:2380/tcp         # etcd server client API
ufw allow 10250/tcp             # Kubelet API
ufw allow 10251/tcp             # kube-scheduler
ufw allow 10252/tcp             # kube-controller-manager
ufw allow 10256/tcp             # kube-proxy health check

# Flannel ports with specific configurations
ufw allow 8472/udp              # Flannel VXLAN
ufw allow 8285/udp              # Flannel host-gw
ufw allow 51820/udp             # Flannel wireguard (if used)

# NodePort services range
ufw allow 30000:32767/tcp       # NodePort services
ufw allow 30000:32767/udp       # NodePort services UDP

# Allow all traffic on private interfaces (safer approach for VirtualBox)
ufw allow in on eth1 to any
ufw allow out on eth1 to any

echo "Firewall configured successfully"

# Install dependencies with error checking
echo "Installing system dependencies..."
apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    vim \
    git \
    wget \
    net-tools \
    htop \
    iptables \
    socat \
    conntrack \
    ipset \
    && echo "Dependencies installed successfully" \
    || { echo "Failed to install dependencies"; exit 1; }

# Configure Docker repository
echo "Setting up Docker repository..."
# Remove any existing keys/repos
rm -f /usr/share/keyrings/docker-archive-keyring.gpg
rm -f /etc/apt/sources.list.d/docker.list

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

# Update package index
apt-get update

# Install containerd with specific version
echo "Installing containerd..."
apt-get install -y containerd.io=1.6.* 
apt-mark hold containerd.io

# Configure containerd for Kubernetes
echo "Configuring containerd for Kubernetes..."
mkdir -p /etc/containerd

# Generate default config and modify for Kubernetes
containerd config default | tee /etc/containerd/config.toml

# Enable SystemdCgroup for better integration with kubelet
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

# Update sandbox image to compatible version
sed -i 's|sandbox_image = "registry.k8s.io/pause:.*"|sandbox_image = "registry.k8s.io/pause:3.9"|g' /etc/containerd/config.toml

# Restart and enable containerd
systemctl restart containerd
systemctl enable containerd

# Verify containerd is working
if ! systemctl is-active containerd &>/dev/null; then
    echo "ERROR: containerd is not running"
    systemctl status containerd
    exit 1
fi
echo "✅ containerd is running successfully"

# Add Kubernetes repository
echo "Setting up Kubernetes repository..."
# Remove existing Kubernetes repo if present
rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
rm -f /etc/apt/sources.list.d/kubernetes.list

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /' | tee /etc/apt/sources.list.d/kubernetes.list

# Update package index
apt-get update

# Install Kubernetes tools with specific versions
echo "Installing Kubernetes tools..."
KUBE_VERSION="1.28.2-1.1"
apt-get install -y \
    kubelet=$KUBE_VERSION \
    kubeadm=$KUBE_VERSION \
    kubectl=$KUBE_VERSION

# Hold Kubernetes packages to prevent unintended updates
apt-mark hold kubelet kubeadm kubectl

# Verify installation
kubelet --version
kubeadm version
kubectl version --client

# Configure kubectl autocompletion and aliases
echo "Configuring kubectl environment..."
echo 'source <(kubectl completion bash)' >> /home/vagrant/.bashrc
echo 'alias k=kubectl' >> /home/vagrant/.bashrc
echo 'complete -o default -F __start_kubectl k' >> /home/vagrant/.bashrc

# Create directories for custom scripts
mkdir -p /opt/k8s-scripts

# Configure systemd for better container handling
echo "Configuring systemd for containers..."
mkdir -p /etc/systemd/system/kubelet.service.d
cat <<EOF | tee /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
# Note: This dropin only works with kubeadm and kubelet v1.11+
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
# This is a file that "kubeadm init" and "kubeadm join" generates at runtime, populating the KUBELET_KUBEADM_ARGS variable dynamically
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
# This is a file that the user can use for overrides of the kubelet args as a last resort. Preferably, the user should use
# the .NodeRegistration.KubeletExtraArgs object in the configuration files instead. KUBELET_EXTRA_ARGS should be sourced from this file.
EnvironmentFile=-/etc/default/kubelet
ExecStart=
ExecStart=/usr/bin/kubelet \$KUBELET_KUBECONFIG_ARGS \$KUBELET_CONFIG_ARGS \$KUBELET_KUBEADM_ARGS \$KUBELET_EXTRA_ARGS
EOF

systemctl daemon-reload

# Create verification script for common setup
cat <<'EOF' > /opt/k8s-scripts/verify-common.sh
#!/bin/bash
echo "=== COMMON SETUP VERIFICATION ==="
echo "System info:"
hostnamectl

echo ""
echo "Swap status:"
free -h | grep Swap

echo ""
echo "Kernel modules:"
lsmod | grep -E "(overlay|br_netfilter)"

echo ""
echo "Network parameters:"
sysctl net.bridge.bridge-nf-call-iptables net.ipv4.ip_forward

echo ""
echo "Containerd status:"
systemctl status containerd --no-pager

echo ""
echo "Kubernetes tools versions:"
kubelet --version
kubeadm version
kubectl version --client

echo ""
echo "Firewall status:"
ufw status | head -20
EOF

chmod +x /opt/k8s-scripts/verify-common.sh

echo "$(date): Common configuration completed successfully"
echo "Verification script created at: /opt/k8s-scripts/verify-common.sh"
echo "=== COMMON SETUP COMPLETED ==="