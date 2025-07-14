#!/bin/bash

export SCRIPT_PATH=$(realpath "$(dirname "${BASH_SOURCE[0]}")")
source ${SCRIPT_PATH}/inc/functions.sh

install_init

###########
#
#            MUMBLE SERVER CLEANUP
#
##

msg $warn "Starting Mumble server cleanup..."

# Stop Mumble server service
if sudo systemctl is-active --quiet mumble-server; then
    msg $info "Stopping Mumble server service..."
    sudo systemctl stop mumble-server
fi

# Disable Mumble server service
if sudo systemctl is-enabled --quiet mumble-server; then
    msg $info "Disabling Mumble server service..."
    sudo systemctl disable mumble-server
fi

# Remove Mumble server configuration files
if [ -f /etc/mumble-server.ini ]; then
    msg $info "Removing Mumble server configuration..."
    sudo rm -f /etc/mumble-server.ini
fi

# Remove Mumble server certificates directory
if [ -d /etc/mumble-server/certs ]; then
    msg $info "Removing Mumble server certificates directory..."
    sudo rm -rf /etc/mumble-server/certs
fi

# Remove Mumble server directory if empty
if [ -d /etc/mumble-server ]; then
    if [ -z "$(ls -A /etc/mumble-server)" ]; then
        msg $info "Removing empty Mumble server directory..."
        sudo rm -rf /etc/mumble-server
    fi
fi

# Remove Mumble server data directory
if [ -d /var/lib/mumble-server ]; then
    msg $info "Removing Mumble server data directory..."
    sudo rm -rf /var/lib/mumble-server
fi

# Remove Mumble server log directory
if [ -d /var/log/mumble-server ]; then
    msg $info "Removing Mumble server log directory..."
    sudo rm -rf /var/log/mumble-server
fi

# Remove Mumble server run directory
if [ -d /var/run/mumble-server ]; then
    msg $info "Removing Mumble server run directory..."
    sudo rm -rf /var/run/mumble-server
fi

# Remove mumble-server system user
if id "mumble-server" &>/dev/null; then
    msg $info "Removing mumble-server system user..."
    sudo userdel mumble-server
fi

# Uninstall Mumble server package
if dpkg -l | grep -q mumble-server; then
    msg $info "Uninstalling Mumble server package..."
    sudo apt remove --purge -y mumble-server
    sudo apt autoremove -y
fi

# Clean up any remaining Mumble server processes
pkill -f mumble-server 2>/dev/null || true
pkill -f murmurd 2>/dev/null || true

# Remove any remaining configuration files
if [ -f /etc/default/mumble-server ]; then
    msg $info "Removing default configuration..."
    sudo rm -f /etc/default/mumble-server
fi

# Clean up systemd
sudo systemctl daemon-reload

msg $success "Mumble server cleanup completed successfully!"
msg $info "Mumble server has been completely removed from the system."