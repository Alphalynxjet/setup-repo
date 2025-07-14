#!/bin/bash

export SCRIPT_PATH=$(realpath "$(dirname "${BASH_SOURCE[0]}")")
source ${SCRIPT_PATH}/inc/functions.sh

install_init

###########
#
#            NODE-RED CLEANUP
#
##

msg $warn "Starting Node-RED cleanup..."

# Stop Node-RED service
if sudo systemctl is-active --quiet nodered.service; then
    msg $info "Stopping Node-RED service..."
    sudo systemctl stop nodered.service
fi

# Disable Node-RED service
if sudo systemctl is-enabled --quiet nodered.service; then
    msg $info "Disabling Node-RED service..."
    sudo systemctl disable nodered.service
fi

# Remove systemd service file
if [ -f /etc/systemd/system/nodered.service ]; then
    msg $info "Removing Node-RED systemd service file..."
    sudo rm /etc/systemd/system/nodered.service
fi

# Reload systemd daemon
sudo systemctl daemon-reload

# Remove Node-RED user data directory
if [ -d /home/$(whoami)/.node-red ]; then
    msg $info "Removing Node-RED user data directory..."
    sudo rm -rf /home/$(whoami)/.node-red
fi

# Remove Node-RED certificates directory
if [ -d /home/$(whoami)/.node-red/certs ]; then
    msg $info "Removing Node-RED certificates directory..."
    sudo rm -rf /home/$(whoami)/.node-red/certs
fi

# Remove nodered system user
if id "nodered" &>/dev/null; then
    msg $info "Removing nodered system user..."
    sudo userdel nodered
fi

# Uninstall Node-RED globally
if command -v node-red &> /dev/null; then
    msg $info "Uninstalling Node-RED..."
    sudo npm uninstall -g node-red
fi

# Optional: Remove Node.js (uncomment if you want to remove Node.js completely)
# msg $warn "Node.js will remain installed. To remove it manually, run:"
# msg $info "sudo apt-get remove --purge nodejs npm"
# msg $info "sudo apt-get autoremove"

# Clean up any remaining Node-RED processes
pkill -f node-red 2>/dev/null || true

msg $success "Node-RED cleanup completed successfully!"
msg $info "Node.js has been left installed. Remove manually if not needed."