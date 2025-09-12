#!/bin/bash

# Script to create Docker Hub and Database secrets
# Execute on master node

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m'

print_step() { echo -e "${BLUE}[SECRETS]${NC} $1"; }
print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }

echo "🔐 CREATING KUBERNETES SECRETS"
echo "=============================="

# Verify kubectl works
if ! kubectl cluster-info &>/dev/null; then
    print_error "kubectl not configured or no cluster connection"
    exit 1
fi

# Verify parameters
if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then
    print_error "Missing parameters"
    echo "Usage: $0 <docker_username> <docker_password> <docker_email>"
    exit 1
fi

DOCKER_USERNAME="$1"
DOCKER_PASSWORD="$2"
DOCKER_EMAIL="$3"
DB_USERNAME="${4:-admin}"
DB_PASSWORD="${5:-password123}"

print_step "Received configuration:"
echo "   Docker Username: $DOCKER_USERNAME"
echo "   Docker Email: $DOCKER_EMAIL"
echo "   DB Username: $DB_USERNAME"

# 1. Create Docker Hub secret
print_step "Creating Docker Hub secret (regcred)"

# Delete existing secret if exists
if kubectl get secret regcred &>/dev/null; then
    print_warning "Secret regcred already exists, deleting..."
    kubectl delete secret regcred
fi

# Create new Docker Hub secret
if kubectl create secret docker-registry regcred \
    --docker-server=https://index.docker.io/v1/ \
    --docker-username="$DOCKER_USERNAME" \
    --docker-password="$DOCKER_PASSWORD" \
    --docker-email="$DOCKER_EMAIL"; then
    print_success "Secret regcred created successfully"
else
    print_error "Error creating Docker Hub secret"
    exit 1
fi

# 2. Prepare DB secret values in base64
print_step "Preparing database secret"

DB_USERNAME_B64=$(echo -n "$DB_USERNAME" | base64 -w 0)
DB_PASSWORD_B64=$(echo -n "$DB_PASSWORD" | base64 -w 0)

print_success "DB credentials encoded in base64"

# 3. Create temporary file for DB secret
DB_SECRET_FILE="/tmp/db-secrets.yaml"
cat <<EOF > "$DB_SECRET_FILE"
apiVersion: v1
kind: Secret
metadata:
  name: db-secrets
type: Opaque
data:
  db_username: $DB_USERNAME_B64
  db_userpassword: $DB_PASSWORD_B64
EOF

# Apply DB secret
if kubectl apply -f "$DB_SECRET_FILE"; then
    print_success "Secret db-secrets created successfully"
    rm -f "$DB_SECRET_FILE"
else
    print_error "Error creating database secret"
    rm -f "$DB_SECRET_FILE"
    exit 1
fi

# 4. Also create dhsecret for Docker Hub in base64 format
print_step "Creating additional dhsecret"

DOCKER_USERNAME_B64=$(echo -n "$DOCKER_USERNAME" | base64 -w 0)
DOCKER_PASSWORD_B64=$(echo -n "$DOCKER_PASSWORD" | base64 -w 0)
DOCKER_EMAIL_B64=$(echo -n "$DOCKER_EMAIL" | base64 -w 0)

DH_SECRET_FILE="/tmp/regcred-b64.yaml"
cat <<EOF > "$DH_SECRET_FILE"
apiVersion: v1
kind: Secret
metadata:
  name: regcred-b64
type: Opaque
data:
  username: $DOCKER_USERNAME_B64
  password: $DOCKER_PASSWORD_B64
  email: $DOCKER_EMAIL_B64
EOF

if kubectl apply -f "$DH_SECRET_FILE"; then
    print_success "Secret regcred-b64 created successfully"
    rm -f "$DH_SECRET_FILE"
else
    print_error "Error creating secret regcred-b64"
    rm -f "$DH_SECRET_FILE"
    exit 1
fi

# 5. Verify created secrets
print_step "Verifying created secrets"

echo ""
echo "📋 Available secrets:"
kubectl get secrets | grep -E "(regcred|db-secrets)" || echo "   Expected secrets not found"

# 6. Show additional information
echo ""
echo "🔍 Secret information:"
echo ""
echo "Docker Hub secret (regcred):"
echo "   Type: docker-registry"
echo "   Usage: imagePullSecrets in deployments"
echo ""
echo "DB secret (db-secrets):"  
echo "   Type: Opaque"
echo "   Keys: db_username, db_userpassword"
echo ""
echo "Additional secret (regcred-b64):"
echo "   Type: Opaque" 
echo "   Keys: username, password, email"

print_success "All secrets created successfully"

echo ""
echo "✨ SECRETS READY FOR USE IN DEPLOYMENTS"