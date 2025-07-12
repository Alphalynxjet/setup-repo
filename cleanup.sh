#!/bin/bash

set -e  # Exit on any error

#################################################################################
# TAK Server Deployment Cleanup Script
#################################################################################

# Configuration
WORK_DIR="/opt/tak-deployment"
LOG_FILE="/var/log/tak-deployment.log"
CLEANUP_LOG="/var/log/tak-cleanup.log"

#################################################################################
# Script Functions
#################################################################################

# Logging function
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $message" | tee -a "$CLEANUP_LOG"
}

# Safe removal function with confirmation
safe_remove() {
    local target="$1"
    local description="$2"
    
    if [ -e "$target" ]; then
        log "INFO" "Removing $description: $target"
        sudo rm -rf "$target"
        log "INFO" "Successfully removed: $target"
    else
        log "INFO" "Not found (already clean): $target"
    fi
}

# Stop and remove Docker containers
cleanup_docker() {
    log "INFO" "Cleaning up Docker containers and images..."
    
    # Stop TAK server container if running
    if docker ps -q --filter "name=tak-server" | grep -q .; then
        log "INFO" "Stopping TAK server container..."
        docker stop tak-server || true
    fi
    
    # Remove TAK server container
    if docker ps -aq --filter "name=tak-server" | grep -q .; then
        log "INFO" "Removing TAK server container..."
        docker rm tak-server || true
    fi
    
    # Stop and remove any tak-related containers
    local tak_containers=$(docker ps -aq --filter "name=tak" 2>/dev/null || true)
    if [ -n "$tak_containers" ]; then
        log "INFO" "Removing additional TAK containers..."
        docker rm -f $tak_containers || true
    fi
    
    # Remove TAK-related images (optional - uncomment if desired)
    # local tak_images=$(docker images -q "*tak*" 2>/dev/null || true)
    # if [ -n "$tak_images" ]; then
    #     log "INFO" "Removing TAK Docker images..."
    #     docker rmi -f $tak_images || true
    # fi
    
    # Remove TAK-related volumes
    local tak_volumes=$(docker volume ls -q --filter "name=tak" 2>/dev/null || true)
    if [ -n "$tak_volumes" ]; then
        log "INFO" "Removing TAK Docker volumes..."
        docker volume rm $tak_volumes || true
    fi
    
    log "INFO" "Docker cleanup completed"
}

# Remove LetsEncrypt certificates
cleanup_letsencrypt() {
    log "INFO" "Cleaning up LetsEncrypt certificates..."
    
    # Remove certificate renewal cron jobs
    if crontab -l 2>/dev/null | grep -q "letsencrypt\|certbot"; then
        log "INFO" "Removing LetsEncrypt cron jobs..."
        crontab -l 2>/dev/null | grep -v "letsencrypt\|certbot" | crontab - || true
    fi
    
    # Note: We don't remove /etc/letsencrypt by default as it might be used by other services
    # Users can manually remove it if they're sure it's only used by TAK
    log "INFO" "LetsEncrypt certificates left intact at /etc/letsencrypt (remove manually if not needed by other services)"
    
    # Remove renewal logs
    safe_remove "/var/log/letsencrypt-renewal.log" "LetsEncrypt renewal log"
    safe_remove "/var/log/letsencrypt" "LetsEncrypt log directory"
    
    log "INFO" "LetsEncrypt cleanup completed"
}

# Remove system services and configurations
cleanup_system() {
    log "INFO" "Cleaning up system configurations..."
    
    # Remove any TAK-related systemd services
    if ls /etc/systemd/system/tak* 2>/dev/null; then
        log "INFO" "Removing TAK systemd services..."
        sudo rm -f /etc/systemd/system/tak*
        sudo systemctl daemon-reload
    fi
    
    # Remove any TAK-related configuration in /etc
    safe_remove "/etc/tak" "TAK system configuration"
    
    log "INFO" "System cleanup completed"
}

# Remove downloaded files and working directories
cleanup_files() {
    log "INFO" "Cleaning up deployment files..."
    
    # Remove main working directory
    safe_remove "$WORK_DIR" "main working directory"
    
    # Remove any TAK downloads in common locations
    safe_remove "/tmp/tak-server*" "temporary TAK files"
    safe_remove "/tmp/takserver*" "temporary TAK server files"
    safe_remove "$(pwd)/tak-server*" "local TAK server files"
    safe_remove "$(pwd)/takserver*" "local TAK server files"
    
    # Remove any gdown cache if it exists
    if [ -d "$HOME/.cache/gdown" ]; then
        safe_remove "$HOME/.cache/gdown" "gdown cache"
    fi
    
    log "INFO" "File cleanup completed"
}

# Remove logs
cleanup_logs() {
    log "INFO" "Cleaning up deployment logs..."
    
    safe_remove "$LOG_FILE" "main deployment log"
    safe_remove "/var/log/tak-automated-setup.log" "automated setup log"
    safe_remove "/var/log/tak*" "TAK-related logs"
    
    log "INFO" "Log cleanup completed"
}

# Show cleanup summary
show_summary() {
    echo ""
    echo "🧹 TAK Server Cleanup Completed!"
    echo "================================"
    echo ""
    echo "Cleaned up:"
    echo "  ✅ Docker containers and volumes"
    echo "  ✅ Deployment files and directories"
    echo "  ✅ System configurations"
    echo "  ✅ Cron jobs and scheduled tasks"
    echo "  ✅ Log files"
    echo ""
    echo "Note:"
    echo "  • LetsEncrypt certificates preserved (at /etc/letsencrypt)"
    echo "  • Docker images preserved (use 'docker system prune' to remove if desired)"
    echo "  • System packages left installed (docker, certbot, etc.)"
    echo ""
    echo "Manual cleanup (if desired):"
    echo "  • Remove LetsEncrypt: sudo rm -rf /etc/letsencrypt"
    echo "  • Remove Docker images: docker system prune -a"
    echo "  • Remove packages: sudo apt remove docker.io docker-compose certbot"
    echo ""
    echo "📝 Cleanup log: $CLEANUP_LOG"
}

#################################################################################
# Main Cleanup Process
#################################################################################

main() {
    echo "🧹 TAK Server Deployment Cleanup"
    echo "================================"
    echo ""
    echo "This script will remove all TAK Server deployment artifacts."
    echo ""
    echo "⚠️  WARNING: This will permanently delete:"
    echo "  - TAK Server containers and data"
    echo "  - Deployment files and configurations"
    echo "  - Cron jobs and scheduled tasks"
    echo "  - Log files"
    echo ""
    
    # Confirmation prompt
    read -p "Are you sure you want to proceed? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Cleanup cancelled."
        exit 0
    fi
    
    # Create cleanup log
    sudo mkdir -p "$(dirname "$CLEANUP_LOG")"
    sudo touch "$CLEANUP_LOG"
    sudo chmod 666 "$CLEANUP_LOG"
    
    log "INFO" "Starting TAK Server deployment cleanup"
    
    # Run cleanup steps
    cleanup_docker
    cleanup_letsencrypt
    cleanup_system
    cleanup_files
    cleanup_logs
    
    # Show summary
    show_summary
    
    log "INFO" "Cleanup process completed successfully"
}

# Show usage information
usage() {
    echo "TAK Server Deployment Cleanup Script"
    echo "===================================="
    echo ""
    echo "This script removes all TAK Server deployment artifacts created by run.sh"
    echo ""
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -h, --help              Show this help message"
    echo "  -f, --force             Skip confirmation prompt"
    echo ""
    echo "What gets cleaned up:"
    echo "  • Docker containers and volumes"
    echo "  • Deployment files ($WORK_DIR)"
    echo "  • System configurations"
    echo "  • Cron jobs and scheduled tasks"
    echo "  • Log files"
    echo ""
    echo "What gets preserved:"
    echo "  • LetsEncrypt certificates (/etc/letsencrypt)"
    echo "  • Docker images (use 'docker system prune' separately)"
    echo "  • System packages (docker, certbot, etc.)"
    echo ""
    echo "Example:"
    echo "  bash cleanup.sh         # Interactive cleanup"
    echo "  bash cleanup.sh -f      # Force cleanup without confirmation"
}

# Handle command line arguments
case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
    -f|--force)
        FORCE_CLEANUP=true
        ;;
    "")
        # No arguments - proceed with interactive cleanup
        ;;
    *)
        echo "Unknown argument: $1"
        usage
        exit 1
        ;;
esac

# Check if running with appropriate privileges
if [[ $EUID -eq 0 ]]; then
    log "WARN" "Running as root"
else
    # Check sudo access
    if ! sudo -n true 2>/dev/null; then
        echo "This script requires sudo access for cleanup operations."
        echo "You may be prompted for your password."
        echo ""
    fi
fi

# Skip confirmation if force flag is used
if [ "${FORCE_CLEANUP:-}" = "true" ]; then
    echo "🧹 TAK Server Deployment Cleanup (Force Mode)"
    echo "=============================================="
    echo ""
    
    # Create cleanup log
    sudo mkdir -p "$(dirname "$CLEANUP_LOG")"
    sudo touch "$CLEANUP_LOG"
    sudo chmod 666 "$CLEANUP_LOG"
    
    log "INFO" "Starting forced TAK Server deployment cleanup"
    
    # Run cleanup steps
    cleanup_docker
    cleanup_letsencrypt
    cleanup_system
    cleanup_files
    cleanup_logs
    
    # Show summary
    show_summary
    
    log "INFO" "Forced cleanup process completed successfully"
else
    # Run interactive cleanup
    main "$@"
fi