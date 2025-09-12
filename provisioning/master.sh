#!/bin/bash

# Kubernetes master setup script with OFFICIAL Flannel YAML

set -e

MASTER_IP=$1
LOG_FILE="/var/log/k8s-master-provision.log"
exec > >(tee -a $LOG_FILE) 2>&1

echo "=== MASTER SETUP WITH OFFICIAL FLANNEL ==="
echo "Master IP: $MASTER_IP"

# Function to wait with verification
wait_with_verification() {
    local description=$1
    local command=$2
    local max_attempts=${3:-30}
    local sleep_time=${4:-10}
    
    echo "Waiting for: $description"
    for i in $(seq 1 $max_attempts); do
        if eval "$command" &>/dev/null; then
            echo "✅ $description - Ready after $i attempts"
            return 0
        fi
        echo "⏳ $description - Attempt $i/$max_attempts..."
        sleep $sleep_time
    done
    echo "❌ FAILED: $description after $max_attempts attempts"
    return 1
}

# CRITICAL: Ensure swap is completely disabled
echo "Ensuring swap is completely disabled..."
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# Remove swap file if it exists
rm -f /swap.img

# Verify swap is disabled
if free | grep -q "Swap:.*[1-9]"; then
    echo "ERROR: Swap is still enabled after disable attempt"
    free -h
    exit 1
fi
echo "✅ Swap is completely disabled"

# Configure kubelet with specific IP
echo "Configuring kubelet for IP: $MASTER_IP"
cat <<EOF | tee /etc/default/kubelet
KUBELET_EXTRA_ARGS=--node-ip=$MASTER_IP
EOF

systemctl daemon-reload
systemctl restart kubelet

# Verify kubelet is running
wait_with_verification "Kubelet service" "systemctl is-active kubelet" 10 5

# Initialize Kubernetes cluster
echo "Initializing Kubernetes cluster..."
kubeadm init \
    --pod-network-cidr=10.244.0.0/16 \
    --apiserver-advertise-address=$MASTER_IP \
    --control-plane-endpoint=$MASTER_IP \
    --upload-certs \
    --ignore-preflight-errors=NumCPU

# Configure kubectl for vagrant user
echo "Configuring kubectl for vagrant user..."
mkdir -p /home/vagrant/.kube
cp -f /etc/kubernetes/admin.conf /home/vagrant/.kube/config
chown vagrant:vagrant /home/vagrant/.kube/config

# Configure kubectl for root user
export KUBECONFIG=/etc/kubernetes/admin.conf
echo 'export KUBECONFIG=/etc/kubernetes/admin.conf' >> /root/.bashrc

# CRITICAL: Wait for API server to be completely stable
wait_with_verification "API server responding" "sudo -u vagrant kubectl get nodes" 60 5

# Remove master taint
echo "Removing master taint..."
sudo -u vagrant kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule- || true

# Wait for master node to be Ready
wait_with_verification "Master node Ready" "sudo -u vagrant kubectl get nodes | grep k8s-master | grep -q Ready" 30 10

# Wait for basic system pods
wait_with_verification "Core system pods running" "[ \$(sudo -u vagrant kubectl get pods -n kube-system --no-headers | grep Running | wc -l) -ge 4 ]" 30 10

# Install Flannel using OFFICIAL YAML
echo "Installing Flannel using official YAML..."
sudo -u vagrant kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml

# Wait for Flannel to be ready
echo "Waiting for Flannel to be ready..."
wait_with_verification "Flannel pods running" "[ \$(sudo -u vagrant kubectl get pods -n kube-flannel --no-headers 2>/dev/null | grep Running | wc -l) -ge 1 ]" 20 10

# Verify Flannel health
echo "Verifying Flannel health..."
sleep 30
sudo -u vagrant kubectl get pods -n kube-flannel -o wide
sudo -u vagrant kubectl logs -n kube-flannel -l app=flannel --tail=10

# Final verification
echo "Final cluster verification..."
sudo -u vagrant kubectl get nodes -o wide
sudo -u vagrant kubectl get pods -n kube-system
sudo -u vagrant kubectl get pods -n kube-flannel

# Test pod creation
echo "Testing pod creation..."
sudo -u vagrant kubectl run test-connectivity --image=busybox --rm -i --restart=Never -- ping -c 2 8.8.8.8 || echo "Pod creation test failed - workers may not be ready yet"

# Generate join command ONLY after everything is verified working
echo "Generating join command for workers..."
kubeadm token create --print-join-command > /vagrant/join-command.sh
chmod +x /vagrant/join-command.sh

# Create verification script
cat <<'EOF' > /opt/k8s-scripts/verify-cluster.sh
#!/bin/bash
echo "=== CLUSTER VERIFICATION ==="
echo "Nodes:"
kubectl get nodes -o wide
echo ""
echo "System pods:"
kubectl get pods -n kube-system
echo ""
echo "Flannel pods:"
kubectl get pods -n kube-flannel
echo ""
echo "Testing connectivity:"
kubectl run test-pod --rm -i --image=busybox --restart=Never -- ping -c 3 8.8.8.8
EOF

chmod +x /opt/k8s-scripts/verify-cluster.sh

echo "$(date): Master configuration completed successfully"
echo "Join command saved at: /vagrant/join-command.sh"
echo "Verification script at: /opt/k8s-scripts/verify-cluster.sh"
echo "=== MASTER SETUP WITH OFFICIAL FLANNEL COMPLETED ==="