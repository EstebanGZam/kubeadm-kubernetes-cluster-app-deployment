#!/bin/bash

# Master script for automating complete Kubernetes deployment workflow
# Execute from the project root directory

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m'

print_step() { echo -e "${BLUE}[STEP $1]${NC} $2"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_info() { echo -e "${NC}[INFO]${NC} $1"; }

# Function to wait with verification
wait_for_condition() {
    local description=$1
    local command=$2
    local max_attempts=${3:-30}
    local sleep_time=${4:-10}
    
    print_info "Waiting for: $description"
    for i in $(seq 1 $max_attempts); do
        if eval "$command" &>/dev/null; then
            print_success "$description (attempt $i/$max_attempts)"
            return 0
        fi
        echo "Waiting... attempt $i/$max_attempts"
        sleep $sleep_time
    done
    print_error "TIMEOUT: $description after $max_attempts attempts"
    return 1
}

echo "COMPLETE KUBERNETES LAB AUTOMATION"
echo "================================="
echo ""

# Load configuration from .env
if [ ! -f ".env" ]; then
    print_error ".env file not found"
    echo ""
    echo "Create .env file with the following variables:"
    echo "DOCKER_USERNAME=your_dockerhub_username"
    echo "DOCKER_PASSWORD=your_dockerhub_password"
    echo "DOCKER_EMAIL=your_email@example.com"
    echo "APP_NAME=webapp"
    echo "APP_VERSION=v1"
    echo "DB_USERNAME=admin"
    echo "DB_PASSWORD=password123"
    exit 1
fi

print_step "1" "Loading configuration"
set -a
source .env
set +a

# Validate required variables
REQUIRED_VARS=(
    "DOCKER_USERNAME"
    "DOCKER_PASSWORD"
    "DOCKER_EMAIL"
)

for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        print_error "Required variable not defined: $var"
        exit 1
    fi
done

# Default values
APP_NAME="${APP_NAME:-webapp}"
APP_VERSION="${APP_VERSION:-v1}"
DB_USERNAME="${DB_USERNAME:-admin}"
DB_PASSWORD="${DB_PASSWORD:-password123}"
POD_TIMEOUT="${POD_TIMEOUT:-300}"
APP_NAMESPACE="${APP_NAMESPACE:-default}"
SERVICE_NODE_PORT="${SERVICE_NODE_PORT:-30001}"

print_info "Configuration loaded:"
echo "   Docker Username: $DOCKER_USERNAME"
echo "   App Name: $APP_NAME"
echo "   App Version: $APP_VERSION"
echo "   DB Username: $DB_USERNAME"
echo "   Pod Timeout: ${POD_TIMEOUT}s"
echo ""

# STEP 2: Verify prerequisites
print_step "2" "Verifying prerequisites"

# List of required tools
TOOLS_REQUIRED=(
    "vagrant:Vagrant"
    "VBoxManage:VirtualBox" 
    "docker:Docker"
    "git:Git"
)

for tool_info in "${TOOLS_REQUIRED[@]}"; do
    IFS=':' read -r cmd_name tool_name <<< "$tool_info"
    if ! command -v "$cmd_name" &> /dev/null; then
        print_error "$tool_name is not installed"
        exit 1
    fi
    print_success "$tool_name available"
done

# STEP 3: Prepare clean environment
print_step "3" "Preparing clean environment"

if vagrant status 2>/dev/null | grep -q "running"; then
    print_warning "Existing cluster detected, destroying..."
    vagrant destroy -f
    print_success "Previous cluster removed"
fi

# STEP 4: Create Kubernetes cluster
print_step "4" "Creating Kubernetes cluster"

print_info "Starting vagrant up... (this may take 15-20 minutes)"
if vagrant up; then
    print_success "Vagrant up completed"
else
    print_error "Vagrant up failed"
    exit 1
fi

# STEP 5: Verify cluster
print_step "5" "Verifying cluster status"

# Wait for SSH connectivity
wait_for_condition "SSH connection to master" \
    "vagrant ssh k8s-master -c 'exit'" \
    20 15

# Verify kubectl
wait_for_condition "kubectl working" \
    "vagrant ssh k8s-master -c 'kubectl get nodes'" \
    20 15

# Verify all nodes Ready
wait_for_condition "All nodes Ready" \
    "[ \$(vagrant ssh k8s-master -c 'kubectl get nodes --no-headers | grep Ready | wc -l' 2>/dev/null) -eq 3 ]" \
    20 15

# Verify Flannel
wait_for_condition "Flannel working" \
    "[ \$(vagrant ssh k8s-master -c 'kubectl get pods -n kube-flannel --no-headers | grep Running | wc -l' 2>/dev/null) -ge 3 ]" \
    15 10

print_success "Cluster verified and working"

# STEP 6: Build and push Docker image
print_step "6" "Building and pushing Docker image"

if [ ! -f "scripts/build_image.sh" ]; then
    print_error "Script scripts/build_image.sh not found"
    exit 1
fi

if bash scripts/build_image.sh; then
    print_success "Image built and pushed successfully"
else
    print_error "Image build/push failed"
    exit 1
fi

# STEP 7: Transfer scripts to master
print_step "7" "Transferring scripts to cluster"

# Create temporary directory on master
vagrant ssh k8s-master -c "mkdir -p /tmp/k8s-scripts"

SCRIPTS_TO_TRANSFER=(
    "scripts/create_secrets.sh"
    "scripts/prepare_manifests.sh"
    "scripts/deploy_app.sh"
)

for script in "${SCRIPTS_TO_TRANSFER[@]}"; do
    if [ -f "$script" ]; then
        # Use vagrant upload with specific VM target
        if vagrant upload "$script" /tmp/k8s-scripts/ k8s-master; then
            print_success "$(basename "$script") transferred"
        else
            print_error "Error transferring $script"
            exit 1
        fi
    else
        print_error "Script not found: $script"
        exit 1
    fi
done

# Make scripts executable
vagrant ssh k8s-master -c "chmod +x /tmp/k8s-scripts/*.sh"

# STEP 8: Create secrets in cluster
print_step "8" "Creating secrets in cluster"

if vagrant ssh k8s-master -c "/tmp/k8s-scripts/create_secrets.sh '$DOCKER_USERNAME' '$DOCKER_PASSWORD' '$DOCKER_EMAIL' '$DB_USERNAME' '$DB_PASSWORD'"; then
    print_success "Secrets created successfully"
else
    print_error "Secrets creation failed"
    exit 1
fi

# STEP 9: Prepare manifests
print_step "9" "Preparing Kubernetes manifests"

if vagrant ssh k8s-master -c "/tmp/k8s-scripts/prepare_manifests.sh '$DOCKER_USERNAME' '$APP_NAME' '$APP_VERSION' '$APP_REPOSITORY_URL' '$DB_USERNAME' '$DB_PASSWORD'"; then
    print_success "Manifests prepared successfully"
else
    print_error "Manifest preparation failed"
    exit 1
fi

# STEP 10: Deploy application
print_step "10" "Deploying application to cluster"

if vagrant ssh k8s-master -c "/tmp/k8s-scripts/deploy_app.sh '$POD_TIMEOUT' '$APP_NAMESPACE'"; then
    print_success "Application deployed successfully"
    DEPLOY_SUCCESS=true
else
    print_warning "Deployment completed with warnings"
    DEPLOY_SUCCESS=false
fi

# STEP 11: Final access information
print_step "11" "Access information"

MASTER_IP="${MASTER_IP:-192.168.56.10}"
WORKER1_IP="${WORKER1_IP:-192.168.56.11}"
WORKER2_IP="${WORKER2_IP:-192.168.56.12}"

# Get actual NodePort from service
ACTUAL_NODE_PORT=$(vagrant ssh k8s-master -c "kubectl get service webapp-service -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null" || echo "$SERVICE_NODE_PORT")

echo ""
echo "APPLICATION ACCESS INFORMATION"
echo "============================="
echo ""
echo "Access URLs:"
echo "   http://$MASTER_IP:$ACTUAL_NODE_PORT"
echo "   http://$WORKER1_IP:$ACTUAL_NODE_PORT"
echo "   http://$WORKER2_IP:$ACTUAL_NODE_PORT"
echo ""

# STEP 12: Final connectivity test
print_step "12" "Final connectivity test"

TEST_SUCCESS=false
for IP in "$MASTER_IP" "$WORKER1_IP" "$WORKER2_IP"; do
    if curl -s --connect-timeout 10 "http://$IP:$ACTUAL_NODE_PORT" | grep -q "Hola"; then
        print_success "Application responds at http://$IP:$ACTUAL_NODE_PORT"
        TEST_SUCCESS=true
        echo ""
        echo "Application response:"
        curl -s "http://$IP:$ACTUAL_NODE_PORT"
        break
    fi
done

# STEP 13: Final summary
echo ""
echo "DEPLOYMENT SUMMARY"
echo "=================="
echo ""

vagrant ssh k8s-master -c "kubectl get nodes -o wide" 2>/dev/null | head -10
echo ""

vagrant ssh k8s-master -c "kubectl get pods -l app=hola-mundo -o wide" 2>/dev/null
echo ""

echo "Useful commands:"
echo "   Connect to master: vagrant ssh k8s-master"
echo "   View logs: vagrant ssh k8s-master -c 'kubectl logs -l app=hola-mundo'"
echo "   Scale app: vagrant ssh k8s-master -c 'kubectl scale deployment webapp-deployment --replicas=5'"
echo "   Cluster status: vagrant ssh k8s-master -c 'kubectl get all'"
echo ""

# Final status
if [ "$TEST_SUCCESS" = true ] && [ "$DEPLOY_SUCCESS" = true ]; then
    print_success "LAB COMPLETED SUCCESSFULLY"
    echo ""
    echo "Application is working correctly in the cluster"
    exit 0
elif [ "$DEPLOY_SUCCESS" = true ]; then
    print_warning "DEPLOYMENT COMPLETED WITH WARNINGS"
    echo ""
    echo "Deployment completed but application may not be responding yet"
    echo "Verify manually with: curl http://$MASTER_IP:$ACTUAL_NODE_PORT"
    exit 1
else
    print_error "DEPLOYMENT FAILED"
    echo ""
    echo "Review logs and verify configuration"
    echo "For debugging: vagrant ssh k8s-master"
    exit 1
fi