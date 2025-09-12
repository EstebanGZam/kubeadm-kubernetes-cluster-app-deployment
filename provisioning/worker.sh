#!/bin/bash

# IMPROVED: Kubernetes worker setup script with connectivity verification

set -e

WORKER_IP=$1
MASTER_IP="192.168.56.10"
LOG_FILE="/var/log/k8s-worker-provision.log"
exec > >(tee -a $LOG_FILE) 2>&1

echo "=== WORKER SETUP WITH CONNECTIVITY VERIFICATION ==="
echo "Worker IP: $WORKER_IP"
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

# Configure kubelet with specific IP
echo "Configuring kubelet for IP: $WORKER_IP"
cat <<EOF | tee /etc/default/kubelet
KUBELET_EXTRA_ARGS=--node-ip=$WORKER_IP
EOF

systemctl daemon-reload
systemctl restart kubelet

# Verify kubelet is running
wait_with_verification "Kubelet service" "systemctl is-active kubelet" 10 5

# Create necessary directories
echo "Creating necessary directories..."
mkdir -p /run/flannel
mkdir -p /etc/cni/net.d

# CRITICAL: Verify network connectivity to master BEFORE proceeding
echo "Verifying network connectivity to master..."

# Test basic ping connectivity
if ! ping -c 3 $MASTER_IP &>/dev/null; then
    echo "❌ FATAL: Cannot ping master at $MASTER_IP"
    echo "Network connectivity problem detected"
    exit 1
fi
echo "✅ Basic ping to master successful"

# Test API server port
if ! timeout 10 bash -c "</dev/tcp/$MASTER_IP/6443" 2>/dev/null; then
    echo "❌ FATAL: Cannot connect to API server port 6443 on master"
    echo "Master API server may not be ready yet"
    exit 1
fi
echo "✅ API server port reachable"

# Wait for join command with enhanced verification
echo "Waiting for join command from master..."
wait_with_verification "Join command file exists" "[ -f /vagrant/join-command.sh ]" 240 15
wait_with_verification "Join command file not empty" "[ -s /vagrant/join-command.sh ]" 30 5

# Verify join command is valid
if ! grep -q "kubeadm join" /vagrant/join-command.sh; then
    echo "❌ FATAL: Invalid join command in file"
    cat /vagrant/join-command.sh
    exit 1
fi
echo "✅ Valid join command found"

# Additional wait to ensure master is completely stable
echo "Ensuring master is completely stable..."
sleep 60

# Test API server health before joining
echo "Testing API server health..."
if timeout 10 curl -k -s https://$MASTER_IP:6443/healthz | grep -q "ok"; then
    echo "✅ API server is healthy"
else
    echo "⚠️  API server health check inconclusive, proceeding anyway..."
fi

# Execute join command with retries and better error handling
echo "Attempting to join cluster..."
JOIN_SUCCESS=false

for attempt in {1..10}; do
    echo "Join attempt #$attempt..."
    
    # Clean up any previous failed attempts
    kubeadm reset --force &>/dev/null || true
    
    # Execute join command
    if timeout 300 bash /vagrant/join-command.sh; then
        echo "✅ Join successful on attempt #$attempt"
        JOIN_SUCCESS=true
        break
    else
        echo "❌ Join failed on attempt #$attempt"
        if [ $attempt -lt 10 ]; then
            echo "Waiting 30 seconds before retry..."
            sleep 30
        fi
    fi
done

if [ "$JOIN_SUCCESS" = false ]; then
    echo "❌ FATAL: Failed to join cluster after 10 attempts"
    echo "Showing kubelet logs for debugging:"
    journalctl -u kubelet --no-pager -l --since "5 minutes ago"
    exit 1
fi

# Verify node joined correctly
echo "Verifying node joined successfully..."
sleep 30

# Check kubelet status
if systemctl is-active kubelet &>/dev/null; then
    echo "✅ Kubelet is active"
else
    echo "❌ WARNING: Kubelet is not active"
    systemctl status kubelet --no-pager -l
fi

# Check if node appears in cluster (requires kubectl access, but we'll try)
# Note: Worker nodes don't have kubectl configured, but we can check local status
echo "Checking local node status..."

# Verify kubelet is connecting to API server
if journalctl -u kubelet --no-pager --since "2 minutes ago" | grep -q "Successfully registered node"; then
    echo "✅ Node successfully registered with cluster"
elif journalctl -u kubelet --no-pager --since "2 minutes ago" | grep -q "Unable to register node"; then
    echo "❌ WARNING: Node registration failed"
    journalctl -u kubelet --no-pager --since "2 minutes ago" | grep "Unable to register"
else
    echo "⚠️  Node registration status unclear"
fi

# Check for CNI readiness
echo "Checking CNI plugin status..."
if [ -f /etc/cni/net.d/10-flannel.conflist ]; then
    echo "✅ Flannel CNI configuration found"
else
    echo "⚠️  Flannel CNI configuration not yet available"
fi

# Create verification script
cat <<'EOF' > /opt/k8s-scripts/verify-worker.sh
#!/bin/bash
echo "=== WORKER VERIFICATION ==="
echo "Kubelet status:"
systemctl status kubelet --no-pager -l | head -10
echo ""
echo "Kubelet configuration:"
cat /etc/default/kubelet
echo ""
echo "Network interfaces:"
ip addr show | grep -E "(inet.*eth|inet.*enp)" | grep -v "127.0.0.1"
echo ""
echo "Container runtime status:"
systemctl status containerd --no-pager | head -5
echo ""
echo "CNI configuration:"
ls -la /etc/cni/net.d/ 2>/dev/null || echo "CNI directory not ready"
echo ""
echo "Recent kubelet logs:"
journalctl -u kubelet --no-pager --since "5 minutes ago" | tail -10
EOF

chmod +x /opt/k8s-scripts/verify-worker.sh

echo "$(date): Worker configuration completed"
echo "Worker joined cluster successfully"
echo "Verification script available at: /opt/k8s-scripts/verify-worker.sh"
echo "=== WORKER SETUP COMPLETED ==="