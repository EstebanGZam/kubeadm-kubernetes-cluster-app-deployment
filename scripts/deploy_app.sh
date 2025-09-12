#!/bin/bash

# Script to deploy application to Kubernetes
# Execute on master node after preparing manifests

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m'

print_step() { echo -e "${BLUE}[DEPLOY]${NC} $1"; }
print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }

echo "DEPLOYING APPLICATION TO KUBERNETES"
echo "==================================="

# Verify kubectl works
if ! kubectl cluster-info &>/dev/null; then
    print_error "kubectl is not configured or there is no cluster connection"
    exit 1
fi

# Configuration
MANIFESTS_DIR="/tmp/k8s-deployment/K8S-apps/K8S_files"
POD_TIMEOUT="${1:-300}"
APP_NAMESPACE="${2:-default}"

print_step "Configuration:"
echo "   Manifests directory: $MANIFESTS_DIR"
echo "   Pod timeout: ${POD_TIMEOUT}s"
echo "   Namespace: $APP_NAMESPACE"

# 1. Verify that manifests exist
print_step "Verifying manifests"
if [ ! -d "$MANIFESTS_DIR" ]; then
    print_error "Manifests directory not found: $MANIFESTS_DIR"
    print_error "Run the prepare_manifests.sh script first"
    exit 1
fi

REQUIRED_MANIFESTS=(
    "webapp-configmap.yaml"
    "webapp-deployment.yaml"
    "webapp-service.yaml"
)

for manifest in "${REQUIRED_MANIFESTS[@]}"; do
    if [ ! -f "$MANIFESTS_DIR/$manifest" ]; then
        print_error "Required manifest not found: $manifest"
        exit 1
    fi
done

print_success "Manifests verified"

# 2. Switch to correct namespace if not default
if [ "$APP_NAMESPACE" != "default" ]; then
    print_step "Configuring namespace: $APP_NAMESPACE"
    
    if ! kubectl get namespace "$APP_NAMESPACE" &>/dev/null; then
        print_step "Creating namespace: $APP_NAMESPACE"
        kubectl create namespace "$APP_NAMESPACE"
    fi
    
    # Use the namespace for all following commands
    KUBECTL_NS="-n $APP_NAMESPACE"
else
    KUBECTL_NS=""
fi

# 3. Apply manifests in order
print_step "Applying manifests in order"

APPLY_ORDER=(
    "webapp-configmap.yaml"
    "webapp-dbsecret.yaml"      # Only DB secret, not Docker secret
    "webapp-deployment.yaml"
    "webapp-service.yaml"       # Skip replicaset to avoid conflicts
)

APPLIED_COUNT=0
for manifest in "${APPLY_ORDER[@]}"; do
    MANIFEST_FILE="$MANIFESTS_DIR/$manifest"
    if [ -f "$MANIFEST_FILE" ]; then
        print_step "Applying $manifest"
        if kubectl apply -f "$MANIFEST_FILE" $KUBECTL_NS; then
            print_success "$manifest applied"
            APPLIED_COUNT=$((APPLIED_COUNT + 1))
        else
            print_error "Error applying $manifest"
            exit 1
        fi
    else
        print_warning "$manifest not found, skipping"
    fi
done

print_success "Manifests applied: $APPLIED_COUNT"

# 4. Wait for pods to be ready
print_step "Waiting for pods to be ready (timeout: ${POD_TIMEOUT}s)"

if timeout "$POD_TIMEOUT" kubectl wait --for=condition=ready pod -l app=hola-mundo $KUBECTL_NS --timeout=${POD_TIMEOUT}s; then
    print_success "Pods ready"
else
    print_warning "Timeout waiting for pods, checking current status"
fi

# 5. Verify deployment status
print_step "Verifying deployment status"

echo ""
echo "Pod status:"
kubectl get pods -l app=hola-mundo $KUBECTL_NS -o wide || print_warning "Could not get pods"

echo ""
echo "Service status:"
kubectl get services $KUBECTL_NS | grep webapp-service || print_warning "webapp-service not found"

echo ""
echo "Deployment status:"
kubectl get deployments $KUBECTL_NS | grep webapp || print_warning "No deployments found"

# 6. Get access information
print_step "Getting access information"

NODE_PORT=""
SERVICE_IP=""

if kubectl get service webapp-service $KUBECTL_NS &>/dev/null; then
    NODE_PORT=$(kubectl get service webapp-service $KUBECTL_NS -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "")
    SERVICE_IP=$(kubectl get service webapp-service $KUBECTL_NS -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
fi

# Get node IPs
MASTER_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "192.168.56.10")
WORKER1_IP="192.168.56.11"
WORKER2_IP="192.168.56.12"

# 7. Show access information
echo ""
print_step "ACCESS INFORMATION"
echo ""

if [ -n "$NODE_PORT" ]; then
    echo "External access URLs (NodePort):"
    echo "   http://$MASTER_IP:$NODE_PORT"
    echo "   http://$WORKER1_IP:$NODE_PORT"
    echo "   http://$WORKER2_IP:$NODE_PORT"
    echo ""
fi

if [ -n "$SERVICE_IP" ]; then
    echo "Internal cluster access:"
    echo "   http://$SERVICE_IP"
    echo ""
fi

# 8. Test the application
print_step "Testing application connectivity"

TEST_SUCCESS=false
if [ -n "$NODE_PORT" ]; then
    for IP in "$MASTER_IP" "$WORKER1_IP" "$WORKER2_IP"; do
        print_step "Testing http://$IP:$NODE_PORT"
        if curl -s --connect-timeout 10 "http://$IP:$NODE_PORT" | grep -q "Hola"; then
            print_success "Application responding at http://$IP:$NODE_PORT"
            TEST_SUCCESS=true
            
            echo ""
            echo "Application response:"
            curl -s "http://$IP:$NODE_PORT" | head -5
            break
        else
            print_warning "No response at http://$IP:$NODE_PORT"
        fi
    done
fi

# 9. Useful debugging commands
echo ""
print_step "USEFUL DEBUGGING COMMANDS"
echo ""
echo "View pod logs:"
echo "   kubectl logs -l app=hola-mundo $KUBECTL_NS"
echo "   kubectl logs -f deployment/webapp-deployment $KUBECTL_NS"
echo ""
echo "Describe resources:"
echo "   kubectl describe deployment webapp-deployment $KUBECTL_NS"
echo "   kubectl describe service webapp-service $KUBECTL_NS"
echo "   kubectl describe pods -l app=hola-mundo $KUBECTL_NS"
echo ""
echo "Scale application:"
echo "   kubectl scale deployment webapp-deployment --replicas=5 $KUBECTL_NS"
echo ""
echo "Restart deployment:"
echo "   kubectl rollout restart deployment webapp-deployment $KUBECTL_NS"
echo ""

# 10. Final status
if [ "$TEST_SUCCESS" = true ]; then
    print_success "DEPLOYMENT COMPLETED SUCCESSFULLY"
    echo ""
    echo "The application is running and responding to requests"
    exit 0
else
    print_warning "DEPLOYMENT COMPLETED WITH WARNINGS"
    echo ""
    echo "Manifests were applied but the application may not be ready"
    echo "Check logs and pod status"
    echo ""
    print_step "To verify manually:"
    if [ -n "$NODE_PORT" ]; then
        echo "   curl http://$MASTER_IP:$NODE_PORT"
    fi
    echo "   kubectl get pods -l app=hola-mundo $KUBECTL_NS"
    echo "   kubectl logs -l app=hola-mundo $KUBECTL_NS"
    exit 1
fi