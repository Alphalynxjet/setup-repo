#!/bin/bash

export SCRIPT_PATH=$(realpath "$(dirname "${BASH_SOURCE[0]}")")
source ${SCRIPT_PATH}/inc/functions.sh

install_init

###########
#
#            MEDIAMTX CLEANUP SCRIPT
#
##

msg $warn "Starting MediaMTX cleanup..."

# Stop MediaMTX service
if sudo systemctl is-active --quiet mediamtx; then
    msg $info "Stopping MediaMTX service..."
    sudo systemctl stop mediamtx
fi

# Disable MediaMTX service
if sudo systemctl is-enabled --quiet mediamtx; then
    msg $info "Disabling MediaMTX service..."
    sudo systemctl disable mediamtx
fi

# Remove systemd service file
if [ -f /etc/systemd/system/mediamtx.service ]; then
    msg $info "Removing MediaMTX systemd service..."
    sudo rm -f /etc/systemd/system/mediamtx.service
fi

# Remove MediaMTX configuration directory
if [ -d /etc/mediamtx ]; then
    msg $info "Removing MediaMTX configuration directory..."
    sudo rm -rf /etc/mediamtx
fi

# Remove MediaMTX log directory
if [ -d /var/log/mediamtx ]; then
    msg $info "Removing MediaMTX log directory..."
    sudo rm -rf /var/log/mediamtx
fi

# Remove MediaMTX installation directory
if [ -d /opt/mediamtx ]; then
    msg $info "Removing MediaMTX installation directory..."
    sudo rm -rf /opt/mediamtx
fi

# Remove MediaMTX system user
if id "mediamtx" &>/dev/null; then
    msg $info "Removing MediaMTX system user..."
    sudo userdel mediamtx
fi

# Clean up any remaining MediaMTX processes
pkill -f mediamtx 2>/dev/null || true

# Remove MediaMTX credentials file if it exists
if [ -f "${RELEASE_PATH}/mediamtx-credentials.txt" ]; then
    msg $info "Removing MediaMTX credentials file..."
    rm -f "${RELEASE_PATH}/mediamtx-credentials.txt"
fi

# Remove MediaMTX credentials file from current directory if it exists
if [ -f "mediamtx-credentials.txt" ]; then
    msg $info "Removing MediaMTX credentials file from current directory..."
    rm -f "mediamtx-credentials.txt"
fi

# Clean up temporary files
rm -f /tmp/mediamtx.tar.gz

# Reload systemd daemon
sudo systemctl daemon-reload

msg $success "MediaMTX cleanup completed successfully!"
msg $info "MediaMTX has been completely removed from the system."