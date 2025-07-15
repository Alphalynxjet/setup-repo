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

# Install Node.js if not already installed
if ! command -v node &> /dev/null; then
    msg $info "Installing Node.js..."
    curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
    sudo apt-get install -y nodejs
fi

# Verify Node.js installation
if command -v node &> /dev/null && command -v npm &> /dev/null; then
    msg $success "Node.js and npm are available"
else
    msg $danger "Failed to install Node.js and npm"
    exit 1
fi

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

# Find Let's Encrypt certificate directory and set protocol
msg $info "Looking for Let's Encrypt certificates..."
CERT_DIR=""
PROTOCOL="http"
if [ -d "/etc/letsencrypt/live" ]; then
    CERT_DIR=$(find /etc/letsencrypt/live -maxdepth 1 -type d ! -path "/etc/letsencrypt/live" | head -1)
    if [ -n "$CERT_DIR" ] && [ -f "$CERT_DIR/fullchain.pem" ] && [ -f "$CERT_DIR/privkey.pem" ]; then
        PROTOCOL="https"
    fi
fi

# Create Node-RED directory and settings file
msg $info "Creating Node-RED directory and settings file..."
sudo mkdir -p /home/$(whoami)/.node-red
if [ "$PROTOCOL" = "https" ]; then
    msg $info "Configuring Node-RED with HTTPS support using certificates from $CERT_DIR"
    sudo tee /home/$(whoami)/.node-red/settings.js > /dev/null << EOF
var fs = require("fs");
module.exports = {
    uiPort: process.env.PORT || 1880,
    https: {
        key: fs.readFileSync('/home/$(whoami)/.node-red/certs/privkey.pem'),
        cert: fs.readFileSync('/home/$(whoami)/.node-red/certs/fullchain.pem'),
        secureProtocol: 'TLSv1_2_method',
        ciphers: 'ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-SHA256:ECDHE-RSA-AES256-SHA384',
        honorCipherOrder: true
    },
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
EOF
else
    msg $warn "No Let's Encrypt certificates found, configuring Node-RED with HTTP only"
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
EOF
fi

# Continue with the rest of the settings (common to both HTTP and HTTPS)
sudo tee -a /home/$(whoami)/.node-red/settings.js > /dev/null << EOF
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

# Set up certificates if HTTPS is enabled
if [ -n "$CERT_DIR" ] && [ -f "$CERT_DIR/fullchain.pem" ] && [ -f "$CERT_DIR/privkey.pem" ]; then
    msg $info "Setting up certificates for Node-RED HTTPS..."
    sudo mkdir -p /home/$(whoami)/.node-red/certs
    sudo cp "$CERT_DIR/fullchain.pem" /home/$(whoami)/.node-red/certs/
    sudo cp "$CERT_DIR/privkey.pem" /home/$(whoami)/.node-red/certs/
    sudo chown -R $(whoami):$(whoami) /home/$(whoami)/.node-red/
    sudo chmod 644 /home/$(whoami)/.node-red/certs/fullchain.pem
    sudo chmod 644 /home/$(whoami)/.node-red/certs/privkey.pem
    
    # Verify certificates are readable
    if [ -r "/home/$(whoami)/.node-red/certs/fullchain.pem" ] && [ -r "/home/$(whoami)/.node-red/certs/privkey.pem" ]; then
        msg $success "Certificates copied and verified successfully"
        PROTOCOL="https"
    else
        msg $warn "Certificate files not readable, falling back to HTTP"
        PROTOCOL="http"
    fi
else
    msg $info "No Let's Encrypt certificates found, using HTTP"
    PROTOCOL="http"
fi

# Get the correct path for node-red binary
NODERED_PATH=$(which node-red)
if [ -z "$NODERED_PATH" ]; then
    msg $warn "node-red not found in PATH, using default npm global path"
    NODERED_PATH="/usr/local/bin/node-red"
fi

# Create Node-RED service file
msg $info "Creating Node-RED systemd service..."
sudo tee /etc/systemd/system/nodered.service > /dev/null << EOF
[Unit]
Description=Node-RED
After=syslog.target network.target

[Service]
ExecStart=$NODERED_PATH --max-old-space-size=128 --userDir /home/$(whoami)/.node-red
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
    msg $success "Node-RED is available at: ${PROTOCOL}://${IP_ADDRESS}:1880"
    msg $success "Admin username: tak-admin"
    msg $success "Admin password: ${NODERED_ADMIN_PASS}"
    
    # Save credentials to info file if RELEASE_PATH is set
    if [ -n "${RELEASE_PATH}" ]; then
        info ${RELEASE_PATH} "Node-RED Admin Credentials:" init
        info ${RELEASE_PATH} "Username: tak-admin"
        info ${RELEASE_PATH} "Password: ${NODERED_ADMIN_PASS}"
        info ${RELEASE_PATH} "URL: ${PROTOCOL}://${IP_ADDRESS}:1880"
        
        # Also save to a separate file for run.sh to read
        echo "Node-RED Admin Username: tak-admin" > "${RELEASE_PATH}/node-red-credentials.txt"
        echo "Node-RED Admin Password: ${NODERED_ADMIN_PASS}" >> "${RELEASE_PATH}/node-red-credentials.txt"
    else
        # If no RELEASE_PATH, save to current directory for run.sh
        echo "Node-RED Admin Username: tak-admin" > "node-red-credentials.txt"
        echo "Node-RED Admin Password: ${NODERED_ADMIN_PASS}" >> "node-red-credentials.txt"
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