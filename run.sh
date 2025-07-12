#!/bin/bash

set -e  # Exit on any error

#################################################################################

export TAK_URI="tak.yourdomain.com"                    # Your TAK Server domain (FQDN)
export TAK_ALIAS="tak-server"                          # Server name/identifier
export LE_EMAIL="admin@yourdomain.com"                 # Email for LetsEncrypt and notifications

# Deployment Configuration
REPO_URL="https://github.com/Alphalynxjet/takgrid"     # Repository URL
WORK_DIR="/opt/tak-deployment"                         # Working directory
REPO_DIR="$WORK_DIR/takgrid"                           # Repository directory
LOG_FILE="/var/log/tak-deployment.log"                 # Deployment log
export TAK_DOWNLOAD_URL="https://drive.google.com/file/d/1983WdwJxYI4Gw9ZIM9EP5hy6RR0Ovrf7/view?usp=sharing"

#################################################################################
# Script Functions
#################################################################################

# Logging function
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Error handling
error_exit() {
    log "ERROR" "$1"
    echo ""
    echo "❌ Deployment failed. Check the log file: $LOG_FILE"
    echo ""
    echo "Common issues:"
    echo "  - Check internet connectivity"
    echo "  - Verify domain DNS points to this server"
    echo "  - Ensure firewall allows port 80 (for LetsEncrypt)"
    echo "  - Validate TAK_DOWNLOAD_URL is correct"
    exit 1
}

# Check if running as root (required for some operations)
check_privileges() {
    if [[ $EUID -eq 0 ]]; then
        log "WARN" "Running as root - this is acceptable but not required"
    fi
    
    # Check sudo access
    if ! sudo -n true 2>/dev/null; then
        log "WARN" "Script may prompt for sudo password during installation"
    fi
}

# Pre-flight checks
preflight_checks() {
    log "INFO" "Starting pre-flight checks..."
    
    # Check required tools
    local missing_tools=()
    for tool in git curl; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        fi
    done
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        error_exit "Missing required tools: ${missing_tools[*]}. Please install them first."
    fi
    
    # Check internet connectivity
    if ! curl -s --connect-timeout 10 https://github.com >/dev/null; then
        error_exit "No internet connectivity - cannot download repository"
    fi
    
    # Validate critical variables
    if [ -z "$TAK_URI" ]; then
        error_exit "TAK_URI is not set. Please configure your domain name."
    fi
    
    # TAK download URL is now constant, no need to check
    
    log "INFO" "Pre-flight checks completed successfully"
}

# Download and setup repository
setup_repository() {
    log "INFO" "Setting up repository from $REPO_URL..."
    
    # Create working directory
    sudo mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"
    
    # Remove existing repository if present
    if [ -d "$REPO_DIR" ]; then
        log "INFO" "Removing existing repository directory"
        sudo rm -rf "$REPO_DIR"
    fi
    
    # Clone repository
    if ! git clone "$REPO_URL" "$REPO_DIR"; then
        error_exit "Failed to clone repository from $REPO_URL"
    fi
    
    cd "$REPO_DIR"
    
    # Make scripts executable
    find scripts/ -name "*.sh" -exec chmod +x {} \;
    
    log "INFO" "Repository setup completed"
}

# Install required dependencies
install_dependencies() {
    log "INFO" "Installing required dependencies..."
    
    # Detect OS
    if [ -f /etc/debian_version ]; then
        # Debian/Ubuntu
        sudo apt-get update
        
        local packages=("curl" "openssl" "cron" "docker.io" "docker-compose" "certbot")
        
        sudo apt-get install -y "${packages[@]}"
        
        # Install gdown for TAK Server download
        if ! command -v pip3 >/dev/null 2>&1; then
            sudo apt-get install -y python3-pip
        fi
        pip3 install gdown
        
    elif [ -f /etc/redhat-release ]; then
        # RHEL/CentOS
        sudo yum update -y
        
        local packages=("curl" "openssl" "cronie" "docker" "docker-compose" "certbot")
        
        sudo yum install -y "${packages[@]}"
        
        # Install gdown for TAK Server download
        if ! command -v pip3 >/dev/null 2>&1; then
            sudo yum install -y python3-pip
        fi
        pip3 install gdown
        
    else
        log "WARN" "Unknown OS - dependencies may need to be installed manually"
    fi
    
    # Start and enable services
    sudo systemctl enable --now docker
    sudo usermod -aG docker $USER || true
    sudo systemctl enable --now cron 2>/dev/null || sudo systemctl enable --now crond 2>/dev/null || true
    
    log "INFO" "Dependencies installed successfully"
}

# Run the automated deployment
run_deployment() {
    log "INFO" "Starting automated TAK Server deployment..."
    
    # Run the automated setup script
    if ! bash scripts/automated-setup.sh; then
        error_exit "Automated setup failed. Check logs for details."
    fi
    
    log "INFO" "TAK Server deployment completed successfully"
}

# Display deployment status
show_status() {
    echo ""
    echo "🎉 TAK Server Deployment Completed Successfully!"
    echo "==============================================="
    echo ""
    echo "Server Information:"
    echo "  Domain: $TAK_URI"
    echo "  Server Name: $TAK_ALIAS"
    echo "  Installation Type: Docker"
    echo "  LetsEncrypt: Enabled"
    echo ""
    
    echo "Certificate Status:"
    bash scripts/cert-check.sh 2>/dev/null || echo "  Run 'bash scripts/cert-check.sh' to check certificate status"
    echo ""
    
    echo "Renewal System Status:"
    bash scripts/renewal-health-check.sh 2>/dev/null || echo "  Run 'bash scripts/renewal-health-check.sh' to check renewal system"
    echo ""
    
    echo "Useful Commands:"
    echo "  Check certificate status:    cd $REPO_DIR && bash scripts/cert-check.sh"
    echo "  Check renewal health:        cd $REPO_DIR && bash scripts/renewal-health-check.sh"
    echo "  View deployment logs:        tail -f $LOG_FILE"
    echo "  View renewal logs:           tail -f /var/log/letsencrypt-renewal.log"
    echo ""
    
    echo "Docker Commands:"
    echo "  View containers:             docker ps"
    echo "  View TAK logs:               docker logs tak-server"
    echo "  Restart TAK:                 docker restart tak-server"
    echo ""
    
    echo "Web Interfaces:"
    echo "  TAK Server Admin:            https://$TAK_URI:8446"
    echo "  TAK Server API:              https://$TAK_URI:8089"
    echo ""
    echo "📁 Repository Location: $REPO_DIR"
    echo "📝 Deployment Log: $LOG_FILE"
}

#################################################################################
# Main Deployment Process
#################################################################################

main() {
    echo "🚀 TAK Server Automated Deployment"
    echo "=================================="
    echo ""
    echo "Repository: $REPO_URL"
    echo "Domain: $TAK_URI"
    echo "Server Name: $TAK_ALIAS"
    echo ""
    
    # Create log file
    sudo mkdir -p "$(dirname "$LOG_FILE")"
    sudo touch "$LOG_FILE"
    sudo chmod 666 "$LOG_FILE"
    
    log "INFO" "Starting TAK Server automated deployment"
    log "INFO" "Repository: $REPO_URL"
    log "INFO" "Domain: $TAK_URI"
    log "INFO" "Server Name: $TAK_ALIAS"
    
    # Run deployment steps
    check_privileges
    preflight_checks
    setup_repository
    install_dependencies
    run_deployment
    
    # Show final status
    show_status
    
    log "INFO" "Deployment process completed successfully"
}

# Show usage information
usage() {
    echo "TAK Server Automated Deployment Script"
    echo "======================================"
    echo ""
    echo "This script automatically deploys a TAK Server with LetsEncrypt certificates"
    echo "using the tak-tools repository from GitHub."
    echo ""
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -h, --help              Show this help message"
    echo "  --dry-run               Validate configuration without deploying"
    echo ""
    echo "Configuration (edit these 3 values in the script):"
    echo "  TAK_URI                 Your TAK Server domain"
    echo "  TAK_ALIAS               Server name/identifier"
    echo "  LE_EMAIL                Email for LetsEncrypt"
    echo ""
    echo "Example:"
    echo "  bash run.sh"
    echo ""
    echo "For more information, see: https://github.com/Alphalynxjet/takgrid"
}

# Handle command line arguments
case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
    --dry-run)
        echo "🔍 Dry Run Mode - Validating Configuration"
        echo "========================================"
        check_privileges
        preflight_checks
        setup_repository
        echo ""
        echo "✅ Configuration validation completed successfully"
        echo "Remove --dry-run to proceed with actual deployment"
        exit 0
        ;;
    "")
        # No arguments - proceed with deployment
        ;;
    *)
        echo "Unknown argument: $1"
        usage
        exit 1
        ;;
esac

# Check if this script has been customized
if [ "$TAK_URI" = "tak.yourdomain.com" ]; then
    echo "⚠️  Configuration Required"
    echo "========================"
    echo ""
    echo "Please customize these 3 values at the top of this script:"
    echo ""
    echo "  - TAK_URI: Your TAK Server domain"
    echo "  - TAK_ALIAS: Server name/identifier"  
    echo "  - LE_EMAIL: Your email address"
    echo ""
    echo "Edit this file: $0"
    echo ""
    exit 1
fi

# Run main deployment process
main "$@"