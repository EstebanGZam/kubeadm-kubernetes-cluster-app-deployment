#!/bin/bash

# Script to clone repository and update manifests
# Execute on master node

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m'

print_step() { echo -e "${BLUE}[MANIFESTS]${NC} $1"; }
print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }

echo "📦 PREPARING KUBERNETES MANIFESTS"
echo "================================"

# Verify parameters
if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then
    print_error "Missing parameters"
    echo "Usage: $0 <docker_username> <app_name> <app_version> [repo_url] [db_username] [db_password]"
    exit 1
fi

DOCKER_USERNAME="$1"
APP_NAME="$2"
APP_VERSION="$3"
REPO_URL="${4:-https://github.com/mariocr73/K8S-apps.git}"
DB_USERNAME="${5:-admin}"
DB_PASSWORD="${6:-password123}"

WORK_DIR="/tmp/k8s-deployment"
MANIFESTS_DIR="$WORK_DIR/K8S-apps/K8S_files"

print_step "Configuration:"
echo "   Docker Image: $DOCKER_USERNAME/$APP_NAME:$APP_VERSION"
echo "   Repository: $REPO_URL"
echo "   Working directory: $WORK_DIR"

# 1. Clean previous working directory
print_step "Cleaning working directory"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# 2. Clone application repository
print_step "Cloning application repository"
if git clone "$REPO_URL"; then
    print_success "Repository cloned successfully"
else
    print_error "Error cloning repository: $REPO_URL"
    exit 1
fi

# 3. Verify manifest files exist
print_step "Verifying manifests"
if [ ! -d "$MANIFESTS_DIR" ]; then
    print_error "K8S_files directory not found in $MANIFESTS_DIR"
    exit 1
fi

# List found manifests
echo "   Found manifests:"
for file in "$MANIFESTS_DIR"/*.yaml; do
    if [ -f "$file" ]; then
        echo "   - $(basename "$file")"
    fi
done

# 4. Update manifests with correct image
print_step "Updating manifests with Docker image"

# Create backups and update deployment and replicaset
for file in webapp-deployment.yaml webapp-replicaset.yaml; do
    MANIFEST_FILE="$MANIFESTS_DIR/$file"
    if [ -f "$MANIFEST_FILE" ]; then
        print_step "Updating $file"
        
        # Create backup
        cp "$MANIFEST_FILE" "$MANIFEST_FILE.backup"
        
        # Update placeholders
        sed -i "s|<nombre_de_usuario_en_docker_hub>|$DOCKER_USERNAME|g" "$MANIFEST_FILE"
        sed -i "s|<nombre_del_repositorio>|$APP_NAME|g" "$MANIFEST_FILE"
        sed -i "s|<tag>|$APP_VERSION|g" "$MANIFEST_FILE"
        
        print_success "$file updated"
        
        # Show final configured image
        IMAGE_LINE=$(grep "image:" "$MANIFEST_FILE" | head -1)
        echo "   Configured image: ${IMAGE_LINE##*image: }"
    else
        print_warning "$file not found, skipping..."
    fi
done

# 5. Update secrets with base64 values
print_step "Updating secrets with credentials"

# Prepare base64 values
DOCKER_USERNAME_B64=$(echo -n "$DOCKER_USERNAME" | base64 -w 0)
DOCKER_EMAIL_B64=$(echo -n "${DOCKER_EMAIL:-$DOCKER_USERNAME@example.com}" | base64 -w 0)
DB_USERNAME_B64=$(echo -n "$DB_USERNAME" | base64 -w 0)
DB_PASSWORD_B64=$(echo -n "$DB_PASSWORD" | base64 -w 0)

# Update webapp-dhsecret.yaml (Docker Hub credentials)
DHSECRET_FILE="$MANIFESTS_DIR/webapp-dhsecret.yaml"
if [ -f "$DHSECRET_FILE" ]; then
    print_step "Updating webapp-dhsecret.yaml"
    cp "$DHSECRET_FILE" "$DHSECRET_FILE.backup"
    
    sed -i "s|<valor_del_usuario_en_base64>|$DOCKER_USERNAME_B64|g" "$DHSECRET_FILE"
    sed -i "s|<valor_de_la_contraseña_en_base64>|valor_no_necesario_usamos_regcred|g" "$DHSECRET_FILE"
    sed -i "s|<valor_del_correo_en_base64>|$DOCKER_EMAIL_B64|g" "$DHSECRET_FILE"
    
    print_success "webapp-dhsecret.yaml updated"
else
    print_warning "webapp-dhsecret.yaml not found"
fi

# Update webapp-dbsecret.yaml (DB credentials)
DBSECRET_FILE="$MANIFESTS_DIR/webapp-dbsecret.yaml"
if [ -f "$DBSECRET_FILE" ]; then
    print_step "Updating webapp-dbsecret.yaml"
    cp "$DBSECRET_FILE" "$DBSECRET_FILE.backup"
    
    sed -i "s|<valor_del_nombre_de_usuario_en_base64>|$DB_USERNAME_B64|g" "$DBSECRET_FILE"
    sed -i "s|<valor_de_la_contraseña_en_base64>|$DB_PASSWORD_B64|g" "$DBSECRET_FILE"
    
    print_success "webapp-dbsecret.yaml updated"
else
    print_warning "webapp-dbsecret.yaml not found"
fi

# 6. Verify updated manifests
print_step "Verifying updated manifests"

echo ""
echo "📋 Summary of changes:"
echo ""

for file in webapp-deployment.yaml webapp-replicaset.yaml; do
    MANIFEST_FILE="$MANIFESTS_DIR/$file"
    if [ -f "$MANIFEST_FILE" ]; then
        echo "✓ $file:"
        IMAGE_LINE=$(grep "image:" "$MANIFEST_FILE" | head -1 | sed 's/^[ \t]*//')
        echo "  $IMAGE_LINE"
    fi
done

echo ""
echo "✓ Updated secrets:"
echo "  - webapp-dhsecret.yaml: Docker Hub credentials"
echo "  - webapp-dbsecret.yaml: Database credentials"

# 7. Validate basic YAML syntax
print_step "Validating YAML syntax"

YAML_ERRORS=0
for file in "$MANIFESTS_DIR"/*.yaml; do
    if [ -f "$file" ]; then
        if ! kubectl --dry-run=client apply -f "$file" &>/dev/null; then
            print_warning "Possible syntax error in $(basename "$file")"
            YAML_ERRORS=$((YAML_ERRORS + 1))
        fi
    fi
done

if [ $YAML_ERRORS -eq 0 ]; then
    print_success "All manifests have valid syntax"
else
    print_warning "$YAML_ERRORS manifests may have syntax issues"
fi

# 8. Create application script
print_step "Creating application script"

cat <<'EOF' > "$WORK_DIR/apply_manifests.sh"
#!/bin/bash

set -e

MANIFESTS_DIR="/tmp/k8s-deployment/K8S-apps/K8S_files"

echo "Applying manifests in order..."

# Application order
APPLY_ORDER=(
    "webapp-configmap.yaml"
    "webapp-dhsecret.yaml"
    "webapp-dbsecret.yaml"
    "webapp-deployment.yaml"
    "webapp-replicaset.yaml"
    "webapp-service.yaml"
)

for manifest in "${APPLY_ORDER[@]}"; do
    MANIFEST_FILE="$MANIFESTS_DIR/$manifest"
    if [ -f "$MANIFEST_FILE" ]; then
        echo "Applying $manifest..."
        kubectl apply -f "$MANIFEST_FILE"
    else
        echo "⚠️  $manifest not found, skipping..."
    fi
done

echo "✅ All manifests applied"
EOF

chmod +x "$WORK_DIR/apply_manifests.sh"

print_success "Application script created: $WORK_DIR/apply_manifests.sh"

# 9. Final information
echo ""
echo "📁 Manifests prepared in: $MANIFESTS_DIR"
echo "🔧 Application script: $WORK_DIR/apply_manifests.sh"
echo ""
echo "✨ MANIFESTS READY FOR DEPLOYMENT"
echo ""
echo "💡 Next step: run deployment script"