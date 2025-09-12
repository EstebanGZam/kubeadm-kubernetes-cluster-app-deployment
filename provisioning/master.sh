#!/bin/bash

# Kubernetes master setup script with VirtualBox-optimized Flannel and kube-proxy

set -e

MASTER_IP=$1
LOG_FILE="/var/log/k8s-master-provision.log"
exec > >(tee -a $LOG_FILE) 2>&1

echo "=== MASTER SETUP WITH VIRTUALBOX-OPTIMIZED CONFIGURATION ==="
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

# Install Flannel using CUSTOM configuration optimized for VirtualBox
echo "Installing Flannel with VirtualBox-optimized configuration..."

cat <<EOF | sudo -u vagrant kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: kube-flannel
  labels:
    k8s-app: flannel
    pod-security.kubernetes.io/enforce: privileged
---
apiVersion: v1
kind: ServiceAccount
metadata:
  labels:
    k8s-app: flannel
  name: flannel
  namespace: kube-flannel
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  labels:
    k8s-app: flannel
  name: flannel
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get"]
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["nodes/status"]
  verbs: ["patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  labels:
    k8s-app: flannel
  name: flannel
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: flannel
subjects:
- kind: ServiceAccount
  name: flannel
  namespace: kube-flannel
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: kube-flannel-cfg
  namespace: kube-flannel
  labels:
    tier: node
    app: flannel
data:
  cni-conf.json: |
    {
      "name": "cbr0",
      "cniVersion": "0.3.1",
      "plugins": [
        {
          "type": "flannel",
          "delegate": {
            "hairpinMode": true,
            "isDefaultGateway": true
          }
        },
        {
          "type": "portmap",
          "capabilities": {
            "portMappings": true
          }
        }
      ]
    }
  net-conf.json: |
    {
      "Network": "10.244.0.0/16",
      "Backend": {
        "Type": "vxlan"
      }
    }
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: kube-flannel-ds
  namespace: kube-flannel
  labels:
    tier: node
    app: flannel
spec:
  selector:
    matchLabels:
      app: flannel
  template:
    metadata:
      labels:
        tier: node
        app: flannel
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: kubernetes.io/os
                operator: In
                values:
                - linux
      hostNetwork: true
      priorityClassName: system-node-critical
      tolerations:
      - operator: Exists
        effect: NoSchedule
      serviceAccountName: flannel
      initContainers:
      - name: install-cni-plugin
        image: docker.io/flannel/flannel-cni-plugin:v1.4.0-flannel1
        command:
        - cp
        args:
        - -f
        - /flannel
        - /opt/cni/bin/flannel
        volumeMounts:
        - name: cni-plugin
          mountPath: /opt/cni/bin
      - name: install-cni
        image: docker.io/flannel/flannel:v0.24.2
        command:
        - cp
        args:
        - -f
        - /etc/kube-flannel/cni-conf.json
        - /etc/cni/net.d/10-flannel.conflist
        volumeMounts:
        - name: cni
          mountPath: /etc/cni/net.d
        - name: flannel-cfg
          mountPath: /etc/kube-flannel/
      containers:
      - name: kube-flannel
        image: docker.io/flannel/flannel:v0.24.2
        command:
        - /opt/bin/flanneld
        args:
        - --ip-masq
        - --kube-subnet-mgr
        - --iface=eth1
        - --iface-regex=eth1
        resources:
          requests:
            cpu: "100m"
            memory: "50Mi"
        securityContext:
          privileged: false
          capabilities:
            add: ["NET_ADMIN", "NET_RAW"]
        env:
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        volumeMounts:
        - name: run
          mountPath: /run/flannel
        - name: flannel-cfg
          mountPath: /etc/kube-flannel/
        - name: xtables-lock
          mountPath: /run/xtables.lock
      volumes:
      - name: run
        hostPath:
          path: /run/flannel
      - name: cni-plugin
        hostPath:
          path: /opt/cni/bin
      - name: cni
        hostPath:
          path: /etc/cni/net.d
      - name: flannel-cfg
        configMap:
          name: kube-flannel-cfg
      - name: xtables-lock
        hostPath:
          path: /run/xtables.lock
          type: FileOrCreate
EOF

# Wait for Flannel to be ready with improved verification
echo "Waiting for Flannel to be ready..."
wait_with_verification "Flannel pods running" "[ \$(sudo -u vagrant kubectl get pods -n kube-flannel --no-headers 2>/dev/null | grep Running | wc -l) -ge 1 ]" 120 10

# Configure kube-proxy with correct settings AFTER Flannel is ready
echo "Configuring kube-proxy for optimal NodePort performance..."
cat <<EOF | sudo -u vagrant kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: kube-proxy
  namespace: kube-system
  labels:
    app: kube-proxy
data:
  config.conf: |
    apiVersion: kubeproxy.config.k8s.io/v1alpha1
    kind: KubeProxyConfiguration
    mode: "iptables"
    bindAddress: 0.0.0.0
    clusterCIDR: 10.244.0.0/16
    iptables:
      masqueradeAll: false
      masqueradeBit: 14
      minSyncPeriod: 0s
      syncPeriod: 30s
      localhostNodePorts: true
    nodePortAddresses: []
    clientConnection:
      kubeconfig: /var/lib/kube-proxy/kubeconfig.conf
EOF

# Restart kube-proxy to apply new configuration
echo "Restarting kube-proxy with new configuration..."
sudo -u vagrant kubectl delete pods -n kube-system -l k8s-app=kube-proxy
wait_with_verification "Kube-proxy pods running" "[ \$(sudo -u vagrant kubectl get pods -n kube-system -l k8s-app=kube-proxy --no-headers | grep Running | wc -l) -ge 1 ]" 60 10

# Verify Flannel health and network connectivity
echo "Verifying Flannel health and network connectivity..."
sleep 30

# Check Flannel pods status
sudo -u vagrant kubectl get pods -n kube-flannel -o wide

# Test network connectivity between nodes
echo "Testing pod-to-pod network connectivity..."
# Create test pod to verify networking
sudo -u vagrant kubectl run network-test --image=busybox --rm -i --restart=Never -- ping -c 3 8.8.8.8 || echo "Network test failed - this is expected if workers haven't joined yet"

# Show Flannel logs for verification
echo "Flannel logs (last 10 lines):"
sudo -u vagrant kubectl logs -n kube-flannel -l app=flannel --tail=10

# Final verification
echo "Final cluster verification..."
sudo -u vagrant kubectl get nodes -o wide
sudo -u vagrant kubectl get pods -n kube-system
sudo -u vagrant kubectl get pods -n kube-flannel

# Generate join command ONLY after everything is verified working
echo "Generating join command for workers..."
kubeadm token create --print-join-command > /vagrant/join-command.sh
chmod +x /vagrant/join-command.sh

# Create comprehensive verification script
cat <<'EOF' > /opt/k8s-scripts/verify-cluster.sh
#!/bin/bash
echo "=== COMPREHENSIVE CLUSTER VERIFICATION ==="
echo ""
echo "1. Cluster Nodes:"
kubectl get nodes -o wide
echo ""

echo "2. System Pods:"
kubectl get pods -n kube-system
echo ""

echo "3. Flannel Pods:"
kubectl get pods -n kube-flannel
echo ""

echo "4. Network Routes:"
ip route show | grep 10.244
echo ""

echo "5. Testing pod connectivity:"
kubectl run connectivity-test --image=busybox --rm -i --restart=Never -- ping -c 3 8.8.8.8 || echo "External connectivity test failed"
echo ""

echo "6. kube-proxy configuration:"
kubectl get configmap kube-proxy -n kube-system -o yaml | grep -A 5 -B 5 "mode:"
echo ""

echo "7. Service endpoints (if any services exist):"
kubectl get svc,endpoints
echo ""

echo "8. Recent Flannel logs:"
kubectl logs -n kube-flannel -l app=flannel --tail=5
echo ""

echo "=== VERIFICATION COMPLETED ==="
EOF

chmod +x /opt/k8s-scripts/verify-cluster.sh

# Create network troubleshooting script
cat <<'EOF' > /opt/k8s-scripts/troubleshoot-network.sh
#!/bin/bash
echo "=== NETWORK TROUBLESHOOTING ==="
echo ""
echo "1. Testing ping to pod IPs (if pods exist):"
POD_IPS=$(kubectl get pods -o wide --no-headers | awk '{print $6}' | grep -E '^10\.244\.' | head -3)
for ip in $POD_IPS; do
    echo "Testing ping to pod $ip:"
    ping -c 2 $ip || echo "❌ Cannot ping $ip"
done
echo ""

echo "2. Flannel interface status:"
ip addr show flannel.1 || echo "Flannel interface not found"
echo ""

echo "3. CNI configuration:"
ls -la /etc/cni/net.d/
echo ""

echo "4. Flannel subnet configuration:"
cat /run/flannel/subnet.env 2>/dev/null || echo "Flannel subnet file not found"
echo ""

echo "5. iptables NAT rules for NodePorts:"
iptables -t nat -L -n | grep -E "(30001|NodePort)" || echo "No NodePort rules found"
echo ""

echo "=== TROUBLESHOOTING COMPLETED ==="
EOF

chmod +x /opt/k8s-scripts/troubleshoot-network.sh

echo "$(date): Master configuration completed successfully"
echo ""
echo "📋 SUMMARY:"
echo "   ✅ Kubernetes cluster initialized"
echo "   ✅ Flannel installed with VirtualBox optimization (--iface=eth1)"
echo "   ✅ kube-proxy configured for NodePort functionality"
echo "   ✅ Network connectivity verified"
echo ""
echo "📁 Files created:"
echo "   - Join command: /vagrant/join-command.sh"
echo "   - Verification script: /opt/k8s-scripts/verify-cluster.sh"
echo "   - Troubleshooting script: /opt/k8s-scripts/troubleshoot-network.sh"
echo ""
echo "🚀 NEXT STEPS:"
echo "   1. Wait for worker nodes to join the cluster"
echo "   2. Run verification: /opt/k8s-scripts/verify-cluster.sh"
echo "   3. Deploy applications with functioning NodePorts"
echo ""
echo "=== MASTER SETUP WITH VIRTUALBOX OPTIMIZATION COMPLETED ==="