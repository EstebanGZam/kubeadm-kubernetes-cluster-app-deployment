#!/bin/bash

# Script to build and upload Docker image using .env configuration
# Run from the host machine

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m'

print_step() { echo -e "${BLUE}[BUILD]${NC} $1"; }
print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }

echo "DOCKER IMAGE BUILD"
echo "============================="

# Load configuration from .env if exists
if [ -f ".env" ]; then
    print_step "Loading configuration from .env"
    set -a  # Export all variables
    source .env
    set +a
    print_success "Configuration loaded from .env"
else
    print_warning ".env file not found"
    
    # Check command line parameters
    if [ -z "$1" ]; then
        print_error ".env file not found and Docker Hub user not provided"
        echo "Usage: $0 <docker_username> [docker_password] [docker_email]"
        echo "Or create a .env file with the required variables"
        exit 1
    fi
    
    DOCKER_USERNAME="$1"
    DOCKER_PASSWORD="$2"
    DOCKER_EMAIL="$3"
    APP_NAME="${APP_NAME:-webapp}"
    APP_VERSION="${APP_VERSION:-v1}"
    APP_REPOSITORY_URL="${APP_REPOSITORY_URL:-https://github.com/mariocr73/K8S-apps.git}"
fi

# Validate required variables
if [ -z "$DOCKER_USERNAME" ]; then
    print_error "DOCKER_USERNAME is not defined"
    exit 1
fi

print_step "Configuration:"
echo "   Docker Username: $DOCKER_USERNAME"
echo "   App Name: $APP_NAME"
echo "   App Version: $APP_VERSION"
echo "   Repository URL: $APP_REPOSITORY_URL"

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    print_error "Docker is not installed on your host machine"
    exit 1
fi
print_success "Docker available: $(docker --version | cut -d' ' -f3)"

# Function to check login status
check_docker_login() {
    print_step "Checking Docker Hub login status"
    
    # Try to pull a public image to test connectivity
    docker pull hello-world:latest &>/dev/null
    
    if docker tag hello-world:latest $DOCKER_USERNAME/test-auth-check:temp &>/dev/null; then
        # Try to push (will fail, but will tell us if we're authenticated)
        local push_result=$(docker push $DOCKER_USERNAME/test-auth-check:temp 2>&1)
        docker rmi $DOCKER_USERNAME/test-auth-check:temp &>/dev/null
        
        if echo "$push_result" | grep -q "unauthorized\|authentication required\|denied"; then
            return 1  # Not logged in
        else
            return 0  # Logged in
        fi
    else
        return 1  # Not logged in
    fi
}

# Login function
do_docker_login() {
    print_step "Logging into Docker Hub"
    echo "Username: $DOCKER_USERNAME"
    
    if [ -n "$DOCKER_PASSWORD" ]; then
        # Automatic login if we have password
        if echo "$DOCKER_PASSWORD" | docker login -u "$DOCKER_USERNAME" --password-stdin; then
            print_success "Automatic login successful"
        else
            print_error "Automatic login error"
            exit 1
        fi
    else
        # Interactive login
        if ! docker login -u "$DOCKER_USERNAME"; then
            print_error "Docker Hub interactive login error"
            exit 1
        fi
        print_success "Interactive login successful"
    fi
}

# Check and handle login
if ! check_docker_login; then
    do_docker_login
else
    print_success "Already authenticated on Docker Hub as $DOCKER_USERNAME"
fi

# Clone repository if it doesn't exist
REPO_DIR="K8S-apps"
if [ ! -d "$REPO_DIR" ]; then
    print_step "Cloning repository"
    if git clone "$APP_REPOSITORY_URL" "$REPO_DIR"; then
        print_success "Repository cloned"
    else
        print_error "Error cloning repository: $APP_REPOSITORY_URL"
        exit 1
    fi
else
    print_step "Repository already exists, updating"
    cd "$REPO_DIR"
    git pull origin main || git pull origin master || print_warning "Could not update repository"
    cd ..
fi

cd "$REPO_DIR" || {
    print_error "Could not access directory $REPO_DIR"
    exit 1
}

# Verify Dockerfile exists
if [ ! -f "Dockerfile" ]; then
    print_error "Dockerfile not found in directory"
    exit 1
fi

# Build image
print_step "Building Docker image"
IMAGE_NAME="$APP_NAME:latest"

if ! docker build -t "$IMAGE_NAME" .; then
    print_error "Error building image"
    exit 1
fi
print_success "Image built: $IMAGE_NAME"

# Tag image
print_step "Tagging image"
TAGGED_IMAGE="$DOCKER_USERNAME/$APP_NAME:$APP_VERSION"

if ! docker tag "$IMAGE_NAME" "$TAGGED_IMAGE"; then
    print_error "Error tagging image"
    exit 1
fi
print_success "Image tagged: $TAGGED_IMAGE"

# Upload image
print_step "Uploading image to Docker Hub"
if docker push "$TAGGED_IMAGE"; then
    print_success "Image uploaded successfully"
    
    # Show image information
    IMAGE_SIZE=$(docker images "$TAGGED_IMAGE" --format "{{.Size}}")
    echo ""
    echo "Image information:"
    echo "   Repository: $TAGGED_IMAGE"
    echo "   Size: $IMAGE_SIZE"
    echo "   Docker Hub URL: https://hub.docker.com/r/$DOCKER_USERNAME/$APP_NAME"
else
    print_error "Error uploading image to Docker Hub"
    echo ""
    echo "Possible causes:"
    echo "   - Check internet connection"
    echo "   - Verify user $DOCKER_USERNAME exists on Docker Hub"
    echo "   - Check repository permissions"
    exit 1
fi

# Optional cleanup
if [ "${CLEANUP_LOCAL_IMAGES:-false}" = "true" ]; then
    print_step "Cleaning local images"
    docker rmi "$IMAGE_NAME" "$TAGGED_IMAGE" || print_warning "Could not delete all images"
    print_success "Local images removed"
fi

# Return to previous directory
cd ..

echo ""
print_success "BUILD PROCESS COMPLETED"
echo ""
echo "Next step:"
echo "   Run deployment on Kubernetes cluster"
echo ""
echo "Image available: $TAGGED_IMAGE"