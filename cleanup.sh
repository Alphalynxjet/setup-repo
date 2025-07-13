#!/bin/bash

set -e

WORK_DIR="/opt/takgrid"
OLD_WORK_DIR="/tmp/setup-repo-run"
BACKUP_DIR="/tmp/tak-packages-backup"

echo "=== TAK Server Setup Cleanup ==="
echo "This script will clean up everything except TAK install packages"
echo

# Check if work directory exists (check both old and new locations)
if [ ! -d "$WORK_DIR" ] && [ ! -d "$OLD_WORK_DIR" ]; then
    echo "No work directory found at $WORK_DIR or $OLD_WORK_DIR"
    echo "Nothing to clean up."
    exit 0
fi

# Use the directory that exists
if [ -d "$WORK_DIR" ]; then
    ACTIVE_DIR="$WORK_DIR"
    echo "Using work directory: $WORK_DIR"
else
    ACTIVE_DIR="$OLD_WORK_DIR"
    echo "Using old work directory: $OLD_WORK_DIR"
fi

cd "$ACTIVE_DIR"

# Backup TAK packages before cleanup
if [ -d "tak-pack" ] && [ "$(ls -A tak-pack 2>/dev/null)" ]; then
    echo "Backing up TAK packages..."
    mkdir -p "$BACKUP_DIR"
    cp tak-pack/*tak* "$BACKUP_DIR/" 2>/dev/null || true
    echo "TAK packages backed up to: $BACKUP_DIR"
fi

# Stop any running services
echo "Stopping TAK services..."
if command -v systemctl &> /dev/null; then
    sudo systemctl stop takserver 2>/dev/null || true
    sudo systemctl disable takserver 2>/dev/null || true
fi

# Stop Docker containers if running
if command -v docker &> /dev/null; then
    echo "Stopping Docker containers..."
    
    # Find and stop all TAK-related containers
    TAK_CONTAINERS=$(docker ps -a --filter "name=tak" --format "{{.Names}}" 2>/dev/null || true)
    if [ -n "$TAK_CONTAINERS" ]; then
        echo "Stopping TAK containers: $TAK_CONTAINERS"
        echo "$TAK_CONTAINERS" | xargs docker stop 2>/dev/null || true
        echo "$TAK_CONTAINERS" | xargs docker rm -f 2>/dev/null || true
    fi
    
    # Stop containers using docker-compose if compose file exists
    find . -name "docker-compose.yml" -exec docker-compose -f {} down 2>/dev/null \; || true
fi

# Remove Docker networks related to TAK
if command -v docker &> /dev/null; then
    echo "Removing TAK Docker networks..."
    
    # Remove TAK-specific networks
    TAK_NETWORKS=$(docker network ls --filter "name=tak" --format "{{.Name}}" 2>/dev/null || true)
    if [ -n "$TAK_NETWORKS" ]; then
        echo "Removing TAK networks: $TAK_NETWORKS"
        echo "$TAK_NETWORKS" | xargs docker network rm 2>/dev/null || true
    fi
    
    # Remove networks with 'server-' prefix (common TAK pattern)
    SERVER_NETWORKS=$(docker network ls --filter "name=server-" --format "{{.Name}}" 2>/dev/null || true)
    if [ -n "$SERVER_NETWORKS" ]; then
        echo "Removing server networks: $SERVER_NETWORKS"
        echo "$SERVER_NETWORKS" | xargs docker network rm 2>/dev/null || true
    fi
    
    # Prune unused networks
    docker network prune -f 2>/dev/null || true
fi

# Remove Docker images related to TAK
if command -v docker &> /dev/null; then
    echo "Removing TAK Docker images..."
    TAK_IMAGES=$(docker images --filter "reference=*tak*" --format "{{.ID}}" 2>/dev/null || true)
    if [ -n "$TAK_IMAGES" ]; then
        echo "$TAK_IMAGES" | xargs docker rmi -f 2>/dev/null || true
    fi
    
    # Remove dangling images
    docker image prune -f 2>/dev/null || true
fi

# Remove installed TAK packages (Ubuntu/Debian)
if command -v dpkg &> /dev/null; then
    echo "Removing installed TAK packages..."
    sudo dpkg -r takserver 2>/dev/null || true
    sudo dpkg -r tak-server 2>/dev/null || true
fi

# Remove TAK user and directories
echo "Removing TAK user and directories..."
sudo userdel -r tak 2>/dev/null || true
sudo rm -rf /opt/tak 2>/dev/null || true
sudo rm -rf /etc/tak 2>/dev/null || true

# Clean up work directories but preserve package backup info
echo "Cleaning work directories..."
cd /tmp
rm -rf "$WORK_DIR" 2>/dev/null || true
rm -rf "$OLD_WORK_DIR" 2>/dev/null || true

# Remove admin credentials file
rm -f "$ACTIVE_DIR/admin_credentials.txt" 2>/dev/null || true

# Restore TAK packages to a clean location
if [ -d "$BACKUP_DIR" ] && [ "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
    mkdir -p "$WORK_DIR/tak-pack"
    mv "$BACKUP_DIR"/* "$WORK_DIR/tak-pack/" 2>/dev/null || true
    rmdir "$BACKUP_DIR" 2>/dev/null || true
    echo "TAK packages restored to: $WORK_DIR/tak-pack/"
fi

# Clean up any certificates and keys
sudo rm -rf /etc/ssl/certs/tak* 2>/dev/null || true
sudo rm -rf /etc/ssl/private/tak* 2>/dev/null || true

# Remove LetsEncrypt certificates and configuration
echo "Removing LetsEncrypt certificates..."
sudo rm -rf /etc/letsencrypt/ 2>/dev/null || true
sudo rm -rf /var/lib/letsencrypt/ 2>/dev/null || true
sudo rm -rf /var/log/letsencrypt/ 2>/dev/null || true

# Remove any systemd service files
sudo rm -f /etc/systemd/system/takserver.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/tak*.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/tak*.timer 2>/dev/null || true
sudo systemctl daemon-reload 2>/dev/null || true

# Clean up any firewall rules (be careful here)
if command -v ufw &> /dev/null; then
    echo "Note: Firewall rules for TAK may still be active."
    echo "Review with: sudo ufw status"
fi

echo
echo "=== Cleanup Complete ==="
if [ -d "$WORK_DIR/tak-pack" ]; then
    echo "TAK packages preserved in: $WORK_DIR/tak-pack/"
    echo "You can now run the installation script again for testing."
else
    echo "No TAK packages were found to preserve."
    echo "Download TAK packages to $WORK_DIR/tak-pack/ before running the installation script."
fi
echo
echo "To reinstall, run:"
echo "  curl -sSL https://raw.githubusercontent.com/Alphalynxjet/setup-repo/main/run.sh | bash -s <domain> <email>"