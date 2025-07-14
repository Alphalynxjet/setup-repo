#!/bin/bash

export SCRIPT_PATH=$(realpath "$(dirname "${BASH_SOURCE[0]}")")
source "${SCRIPT_PATH}/inc/functions.sh"

install_init

###########
#
#            NODE-RED INSTALLER
#
##

msg $info "Starting Node-RED installation..."

# Install Node-RED using npm (official method)
msg $info "Installing Node-RED using npm..."
sudo npm install -g --unsafe-perm node-red

# Update Multer to latest version to fix security vulnerabilities
msg $info "Updating Multer to fix security vulnerabilities..."
sudo npm install -g multer@latest

# Check Node.js version
NODE_VERSION=$(node --version)
msg $success "Node.js version: ${NODE_VERSION}"

# Generate random password for tak-admin user
passgen "$USER_PASS_OMIT"
NODERED_ADMIN_PASS="$PASSGEN"

# Install bcryptjs for password hashing
msg $info "Installing bcryptjs for password hashing..."
sudo npm install -g bcryptjs

# Generate bcrypt hash for password
msg $info "Generating password hash..."
BCRYPT_HASH=$(node -e "console.log(require('/usr/lib/node_modules/bcryptjs').hashSync('${NODERED_ADMIN_PASS}', 8))")

# Create Node-RED directory and settings file
msg $info "Creating Node-RED directory and settings file..."
sudo mkdir -p /home/$(whoami)/.node-red
sudo tee /home/$(whoami)/.node-red/settings.js > /dev/null << EOF
module.exports = {
    uiPort: process.env.PORT || 1880,
    mqttReconnectTime: 15000,
    serialReconnectTime: 15000,
    debugMaxLength: 1000,
    adminAuth: {
        type: "credentials",
        users: [{
            username: "tak-admin",
            password: "${BCRYPT_HASH}",
            permissions: "*"
        }]
    },
    functionGlobalContext: {
    },
    exportGlobalContextKeys: false,
    logging: {
        console: {
            level: "info",
            metrics: false,
            audit: false
        }
    },
    editorTheme: {
        projects: {
            enabled: false
        }
    }
}
EOF

# Create Node-RED service file
msg $info "Creating Node-RED systemd service..."
sudo tee /etc/systemd/system/nodered.service > /dev/null << EOF
[Unit]
Description=Node-RED
After=syslog.target network.target

[Service]
ExecStart=/usr/bin/node-red --max-old-space-size=128 --userDir /home/$(whoami)/.node-red
Restart=on-failure
KillSignal=SIGINT
User=$(whoami)
Group=$(whoami)
WorkingDirectory=/home/$(whoami)
Environment=NODE_ENV=production
Environment=PATH=/usr/bin:/usr/local/bin:/bin

[Install]
WantedBy=multi-user.target
EOF

# Enable and start Node-RED service
msg $info "Enabling and starting Node-RED service..."
sudo systemctl daemon-reload
sudo systemctl enable nodered.service
sudo systemctl start nodered.service

# Wait a moment for service to start
sleep 5

# Check service status
if sudo systemctl is-active --quiet nodered.service; then
    msg $success "Node-RED service started successfully"
    msg $success "Node-RED is available at: http://${IP_ADDRESS}:1880"
    msg $success "Admin username: tak-admin"
    msg $success "Admin password: ${NODERED_ADMIN_PASS}"
    
    # Save credentials to info file if RELEASE_PATH is set
    if [ -n "${RELEASE_PATH}" ]; then
        info ${RELEASE_PATH} "Node-RED Admin Credentials:" init
        info ${RELEASE_PATH} "Username: tak-admin"
        info ${RELEASE_PATH} "Password: ${NODERED_ADMIN_PASS}"
        info ${RELEASE_PATH} "URL: http://${IP_ADDRESS}:1880"
    fi
    
    # Restart Node-RED to apply settings
    msg $info "Restarting Node-RED to apply settings..."
    sudo systemctl restart nodered.service
    sleep 3
    
    if sudo systemctl is-active --quiet nodered.service; then
        msg $success "Node-RED restarted successfully with authentication enabled"
    else
        msg $warn "Node-RED restart failed, checking status..."
        sudo systemctl status nodered.service
    fi
else
    msg $danger "Failed to start Node-RED service"
    sudo systemctl status nodered.service
    exit 1
fi

msg $success "Node-RED installation completed successfully!"