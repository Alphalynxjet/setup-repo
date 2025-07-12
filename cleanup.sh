#!/bin/bash

set -e

WORK_DIR="/tmp/setup-repo-run"
BACKUP_DIR="/tmp/tak-packages-backup"

echo "=== TAK Server Setup Cleanup ==="
echo "This script will clean up everything except TAK install packages"
echo

# Check if work directory exists
if [ ! -d "$WORK_DIR" ]; then
    echo "No work directory found at $WORK_DIR"
    echo "Nothing to clean up."
    exit 0
fi

cd "$WORK_DIR"

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
    docker-compose down 2>/dev/null || true
    docker stop $(docker ps -q --filter "name=tak") 2>/dev/null || true
fi

# Remove Docker images related to TAK
if command -v docker &> /dev/null; then
    echo "Removing TAK Docker images..."
    docker images | grep -i tak | awk '{print $3}' | xargs docker rmi -f 2>/dev/null || true
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

# Clean up work directory but preserve package backup info
echo "Cleaning work directory..."
cd /tmp
rm -rf "$WORK_DIR"

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
    echo "You can now run ./run.sh again for testing."
else
    echo "No TAK packages were found to preserve."
    echo "Download TAK packages to $WORK_DIR/tak-pack/ before running ./run.sh"
fi