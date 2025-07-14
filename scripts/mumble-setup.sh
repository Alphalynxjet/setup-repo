#!/bin/bash

export SCRIPT_PATH=$(realpath "$(dirname "${BASH_SOURCE[0]}")")
source "${SCRIPT_PATH}/inc/functions.sh"

install_init

###########
#
#            MUMBLE SERVER INSTALLER
#
##

msg $info "Starting Mumble server installation..."

# Install Mumble server
msg $info "Installing Mumble server..."
sudo apt update
sudo apt install -y mumble-server

# Generate random password for SuperUser (admin)
passgen "$USER_PASS_OMIT"
MUMBLE_ADMIN_PASS="$PASSGEN"

# Generate random password for server access (8 characters)
MUMBLE_SERVER_PASS=$(pwgen -s 8 1)

# Find Let's Encrypt certificate directory and set protocol
msg $info "Looking for Let's Encrypt certificates..."
CERT_DIR=""
SSL_ENABLED="false"
if [ -d "/etc/letsencrypt/live" ]; then
    CERT_DIR=$(find /etc/letsencrypt/live -maxdepth 1 -type d ! -path "/etc/letsencrypt/live" | head -1)
    if [ -n "$CERT_DIR" ] && [ -f "$CERT_DIR/fullchain.pem" ] && [ -f "$CERT_DIR/privkey.pem" ]; then
        SSL_ENABLED="true"
    fi
fi

# Set up certificates if SSL is enabled
if [ "$SSL_ENABLED" = "true" ]; then
    msg $info "Setting up certificates for Mumble SSL..."
    sudo mkdir -p /etc/mumble-server/certs
    sudo cp "$CERT_DIR/fullchain.pem" /etc/mumble-server/certs/
    sudo cp "$CERT_DIR/privkey.pem" /etc/mumble-server/certs/
    sudo chown -R mumble-server:mumble-server /etc/mumble-server/certs/
    sudo chmod 640 /etc/mumble-server/certs/fullchain.pem
    sudo chmod 640 /etc/mumble-server/certs/privkey.pem
    
    # Verify certificates are readable
    if [ -r "/etc/mumble-server/certs/fullchain.pem" ] && [ -r "/etc/mumble-server/certs/privkey.pem" ]; then
        msg $success "Certificates copied and verified successfully"
    else
        msg $warn "Certificate files not readable, SSL may not work properly"
    fi
else
    msg $info "No Let's Encrypt certificates found, SSL will not be enabled"
fi

# Stop Mumble server if running
if systemctl is-active --quiet mumble-server; then
    msg $info "Stopping Mumble server..."
    sudo systemctl stop mumble-server
fi

# Create Mumble server configuration
msg $info "Creating Mumble server configuration..."
sudo tee /etc/mumble-server.ini > /dev/null << EOF
# Mumble server configuration
database=/var/lib/mumble-server/mumble-server.sqlite
ice="tcp -h 127.0.0.1 -p 6502"
icesecretread=
icesecretwrite=
autobanAttempts=10
autobanTimeframe=120
autobanTime=300
serverpassword=$MUMBLE_SERVER_PASS
bandwidth=72000
users=100
opusthreshold=100
channelnestinglimit=10
channelcountlimit=1000
defaultchannel=
rememberchannel=true
textmessagelength=5000
imagemessagelength=131072
allowhtml=true
logfile=/var/log/mumble-server/mumble-server.log
pidfile=/var/run/mumble-server/mumble-server.pid
welcometext="<br />Welcome to this Mumble server running <b>TAK Server</b>.<br />Enjoy your stay!<br />"
port=64738
host=
name=TAK Mumble Server
bonjour=True
sendversion=False
EOF

# Add SSL configuration if enabled
if [ "$SSL_ENABLED" = "true" ]; then
    msg $info "Adding SSL configuration to Mumble server..."
    sudo tee -a /etc/mumble-server.ini > /dev/null << EOF
sslCert=/etc/mumble-server/certs/fullchain.pem
sslKey=/etc/mumble-server/certs/privkey.pem
sslCiphers=EECDH+AESGCM:EDH+AESGCM:AES256+EECDH:AES256+EDH
EOF
fi

# Set proper permissions for config file
sudo chown mumble-server:mumble-server /etc/mumble-server.ini
sudo chmod 640 /etc/mumble-server.ini

# Start Mumble server
msg $info "Starting Mumble server..."
sudo systemctl start mumble-server
sudo systemctl enable mumble-server

# Wait for service to start
sleep 3

# Set SuperUser password using murmurd
msg $info "Setting SuperUser password..."
sudo -u mumble-server /usr/sbin/murmurd -ini /etc/mumble-server.ini -supw "$MUMBLE_ADMIN_PASS"

# Create tak-admin user (this requires the server to be running)
msg $info "Creating tak-admin user..."
# Note: Mumble doesn't have built-in user creation via command line
# Users are created when they first connect to the server
# The tak-admin user will need to be created manually or via Ice/GRPC

# Check service status
if sudo systemctl is-active --quiet mumble-server; then
    msg $success "Mumble server started successfully"
    msg $success "Mumble server is available at: $IP_ADDRESS:64738"
    msg $success "Server password: $MUMBLE_SERVER_PASS"
    msg $success "SuperUser password: $MUMBLE_ADMIN_PASS"
    msg $success "Server name: TAK Mumble Server"
    if [ "$SSL_ENABLED" = "true" ]; then
        msg $success "SSL is enabled"
    else
        msg $info "SSL is disabled (no certificates found)"
    fi
    
    # Save credentials to info file if RELEASE_PATH is set
    if [ -n "${RELEASE_PATH}" ]; then
        info ${RELEASE_PATH} "Mumble Server Credentials:" init
        info ${RELEASE_PATH} "Server: $IP_ADDRESS:64738"
        info ${RELEASE_PATH} "Server Password: $MUMBLE_SERVER_PASS"
        info ${RELEASE_PATH} "SuperUser Password: $MUMBLE_ADMIN_PASS"
        info ${RELEASE_PATH} "Server Name: TAK Mumble Server"
        
        # Also save to a separate file for run.sh to read
        echo "Mumble Server: $IP_ADDRESS:64738" > "${RELEASE_PATH}/mumble-credentials.txt"
        echo "Mumble Server Password: $MUMBLE_SERVER_PASS" >> "${RELEASE_PATH}/mumble-credentials.txt"
        echo "Mumble SuperUser Password: $MUMBLE_ADMIN_PASS" >> "${RELEASE_PATH}/mumble-credentials.txt"
        echo "Mumble Server Name: TAK Mumble Server" >> "${RELEASE_PATH}/mumble-credentials.txt"
    else
        # If no RELEASE_PATH, save to current directory for run.sh
        echo "Mumble Server: $IP_ADDRESS:64738" > "mumble-credentials.txt"
        echo "Mumble Server Password: $MUMBLE_SERVER_PASS" >> "mumble-credentials.txt"
        echo "Mumble SuperUser Password: $MUMBLE_ADMIN_PASS" >> "mumble-credentials.txt"
        echo "Mumble Server Name: TAK Mumble Server" >> "mumble-credentials.txt"
    fi
    
    # Restart Mumble to apply all settings
    msg $info "Restarting Mumble server to apply settings..."
    sudo systemctl restart mumble-server
    sleep 3
    
    if sudo systemctl is-active --quiet mumble-server; then
        msg $success "Mumble server restarted successfully"
    else
        msg $warn "Mumble server restart failed, checking status..."
        sudo systemctl status mumble-server
    fi
else
    msg $danger "Failed to start Mumble server"
    sudo systemctl status mumble-server
    exit 1
fi

msg $success "Mumble server installation completed successfully!"