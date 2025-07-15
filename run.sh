#!/bin/bash

set -e

# Check for required parameters
if [ $# -lt 2 ]; then
    echo "Usage: $0 <domain> <email>"
    echo "  domain: FQDN for the TAK server (e.g., tak.example.com)"
    echo "  email: Email address for LetsEncrypt certificate"
    echo
    echo "Example: $0 tak.example.com admin@example.com"
    exit 1
fi

DOMAIN="$1"
EMAIL="$2"
INSTALLER_TYPE="docker"

echo "=== TAK Server Automated Setup (Docker) ==="
echo "Domain: $DOMAIN"
echo "Email: $EMAIL"
echo "This script will install required packages for TAK server setup"
echo

# Update system packages and install required tools
echo "Updating system packages..."
apt update && apt upgrade -y

echo "Configuring non-interactive installation..."
export DEBIAN_FRONTEND=noninteractive
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections

echo "Installing required packages..."
apt install -y \
    apache2-utils \
    apt-transport-https \
    ca-certificates \
    certbot \
    curl \
    docker.io \
    git \
    iptables-persistent \
    libxml2-utils \
    nano \
    net-tools \
    network-manager \
    openssh-server \
    openssl \
    pwgen \
    python3-pip \
    qrencode \
    software-properties-common \
    ufw \
    unzip \
    uuid-runtime \
    vim \
    wget \
    zip

echo "Installing gdown..."
pip3 install gdown

echo "Installing docker-compose..."
HW=$(uname -m)
if [[ $HW == "armv71" ]];then
    HW=armv7
fi
curl -L "https://github.com/docker/compose/releases/download/v2.20.2/docker-compose-$(uname -s | tr '[A-Z]' '[a-z]')-${HW}" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

echo "Starting Docker service..."
systemctl start docker
systemctl enable docker

echo
echo "=== Downloading Setup Repository ==="

REPO_URL="https://github.com/Alphalynxjet/setup-repo"
WORK_DIR="/opt/takgrid"

# Clean any existing work directory
if [ -d "$WORK_DIR" ]; then
    echo "Cleaning existing work directory..."
    rm -rf "$WORK_DIR"
fi

echo "Downloading setup-repo from GitHub..."
git clone "$REPO_URL" "$WORK_DIR"
cd "$WORK_DIR"

echo "Making all files executable..."
find . -type f -name "*.sh" -exec chmod +x {} \;

echo
echo "=== Downloading TAK Server Package ==="

# Check if tak-pack directory exists and has TAK packages
TAK_PACK_DIR="tak-pack"
if [ ! -d "$TAK_PACK_DIR" ]; then
    mkdir -p "$TAK_PACK_DIR"
fi

# Check for existing TAK packages
TAK_PACKAGES=(tak-pack/*tak*)
if [ ${#TAK_PACKAGES[@]} -eq 0 ] || [ ! -e "${TAK_PACKAGES[0]}" ]; then
    echo "No TAK Server packages found. Downloading from Google Drive..."
    
    # Download TAK package from Google Drive
    echo "Downloading TAK package..."
    cd "$TAK_PACK_DIR"
    gdown --fuzzy 'https://drive.google.com/file/d/1983WdwJxYI4Gw9ZIM9EP5hy6RR0Ovrf7/view?usp=sharing' || {
        echo "Failed to download TAK package from Google Drive"
        echo "Please download manually and place in: $(pwd)/../$TAK_PACK_DIR/"
        exit 1
    }
    cd ..
    
    # Verify download
    TAK_PACKAGES=(tak-pack/*tak*)
    if [ ${#TAK_PACKAGES[@]} -eq 0 ] || [ ! -e "${TAK_PACKAGES[0]}" ]; then
        echo "Download completed but no TAK packages found"
        echo "Please check the downloaded files in: $TAK_PACK_DIR/"
        exit 1
    fi
else
    echo "TAK packages already exist, skipping download..."
fi

echo "Found TAK packages:"
for pkg in tak-pack/*tak*; do
    if [ -e "$pkg" ]; then
        echo "  - $(basename "$pkg")"
    fi
done

echo
echo "=== Starting TAK Server Setup ==="
echo "Prerequisites installed and TAK package downloaded."
echo "Now running the setup script..."
echo

# Install expect for automation
echo "Installing expect for automation..."
apt install -y expect

# Create automated responses file
echo "Creating automated responses..."
cat > "auto_responses.exp" << 'EOF'
#!/usr/bin/expect -f

set timeout 300
set domain [lindex $argv 0]
set email [lindex $argv 1]

# Extract alias from domain
regsub -all {\.} $domain "-" alias

spawn ./scripts/setup.sh

# TAK package selection - select first option (1)
expect "Which TAK install package number:" {
    send "1\r"
}

# TAK alias - use domain-based alias
expect "Name your TAK release alias*:" {
    send "\r"
}

# TAK URI - use provided domain
expect "What is the URI*:" {
    send "$domain\r"
}

# Certificate Organization - use default
expect "Certificate Organization*:" {
    send "\r"
}

# Certificate Organizational Unit - use default
expect "Certificate Organizational Unit*:" {
    send "\r"
}

# Certificate City - use default
expect "Certificate City*:" {
    send "\r"
}

# Certificate State - use default
expect "Certificate State*:" {
    send "\r"
}

# Certificate Country - use default
expect "Certificate Country*:" {
    send "\r"
}

# Certificate Authority Password - use default
expect "Certificate Authority Password*:" {
    send "\r"
}

# Client Certificate Password - use default
expect "Client Certificate Password*:" {
    send "\r"
}

# Client Certificate Validity Duration - use default
expect "Client Certificate Validity Duration*:" {
    send "\r"
}

# Enable LetsEncrypt - yes
expect "Enable LetsEncrypt*:" {
    send "y\r"
}

# LetsEncrypt email
expect "LetsEncrypt Confirmation Email:" {
    send "$email\r"
}

# LetsEncrypt validator - web
expect "LetsEncrypt Validator*:" {
    send "web\r"
}

# Handle remaining prompts and capture admin credentials
set admin_username ""
set admin_password ""
set capture_next_line 0

expect {
    "Do you want to inline edit the conf with vi*" {
        send "n\r"
        exp_continue
    }
    "Do you want to inline edit*" {
        send "n\r"
        exp_continue
    }
    "Press Enter to resume setup*" {
        send "\r"
        exp_continue
    }
    "Kick off post-install script*" {
        send "y\r"
        exp_continue
    }
    -re "Username: (.*)" {
        set admin_username $expect_out(1,string)
        exp_continue
    }
    -re "Password: (.*)" {
        set admin_password $expect_out(1,string)
        exp_continue
    }
    eof {
        # Write credentials to file for later retrieval
        set fp [open "admin_credentials.txt" w]
        puts $fp "TAK Admin Username: $admin_username"
        puts $fp "TAK Admin Password: $admin_password"
        close $fp
        exit 0
    }
    timeout {
        puts "Timeout waiting for prompts"
        exit 1
    }
}
EOF

# Make setup script and expect script executable
chmod +x scripts/setup.sh
chmod +x auto_responses.exp

# Run automated setup
echo "Running automated setup..."
./auto_responses.exp "$DOMAIN" "$EMAIL"

# Wait for any background processes to finish output
sleep 0.5

# Install Node-RED
echo
echo "=== Installing Node-RED ==="
echo "Installing Node-RED with HTTPS support..."
./scripts/nodered-install.sh

# Wait for Node-RED to start
sleep 2

# Install Mumble Server
echo
echo "=== Installing Mumble Server ==="
echo "Installing Mumble server with SSL support..."
./scripts/mumble-setup.sh

# Wait for Mumble to start
sleep 2

# Install MediaMTX Server
echo
echo "=== Installing MediaMTX Server ==="
echo "Installing MediaMTX media server..."
./scripts/mediamtx-setup.sh

# Wait for MediaMTX to start
sleep 2

# Append Node-RED credentials to admin_credentials.txt if Node-RED installed
NODERED_CREDS_FILE=""
if [ -f "tak-*/node-red-credentials.txt" ]; then
    NODERED_CREDS_FILE=$(ls tak-*/node-red-credentials.txt | head -1)
elif [ -f "node-red-credentials.txt" ]; then
    NODERED_CREDS_FILE="node-red-credentials.txt"
fi

if [ -n "$NODERED_CREDS_FILE" ]; then
    # Append Node-RED credentials to the same file
    echo "" >> admin_credentials.txt
    cat "$NODERED_CREDS_FILE" >> admin_credentials.txt
    rm -f "$NODERED_CREDS_FILE"
fi

# Append Mumble credentials to admin_credentials.txt if Mumble installed
MUMBLE_CREDS_FILE=""
if [ -f "tak-*/mumble-credentials.txt" ]; then
    MUMBLE_CREDS_FILE=$(ls tak-*/mumble-credentials.txt | head -1)
elif [ -f "mumble-credentials.txt" ]; then
    MUMBLE_CREDS_FILE="mumble-credentials.txt"
fi

if [ -n "$MUMBLE_CREDS_FILE" ]; then
    # Append Mumble credentials to the same file
    echo "" >> admin_credentials.txt
    cat "$MUMBLE_CREDS_FILE" >> admin_credentials.txt
    rm -f "$MUMBLE_CREDS_FILE"
fi

# Append MediaMTX credentials to admin_credentials.txt if MediaMTX installed
MEDIAMTX_CREDS_FILE=""
if [ -f "tak-*/mediamtx-credentials.txt" ]; then
    MEDIAMTX_CREDS_FILE=$(ls tak-*/mediamtx-credentials.txt | head -1)
elif [ -f "mediamtx-credentials.txt" ]; then
    MEDIAMTX_CREDS_FILE="mediamtx-credentials.txt"
fi

if [ -n "$MEDIAMTX_CREDS_FILE" ]; then
    # Append MediaMTX credentials to the same file
    echo "" >> admin_credentials.txt
    cat "$MEDIAMTX_CREDS_FILE" >> admin_credentials.txt
    rm -f "$MEDIAMTX_CREDS_FILE"
fi

# Display all credentials if captured
if [ -f "admin_credentials.txt" ]; then
    echo "=== TAKSERVER Credentials ==="
    cat admin_credentials.txt
    echo
    echo " TAKServer should be running and accessible at https://$DOMAIN:8446"
    
    # Check if HTTPS is enabled for Node-RED
    if systemctl is-active --quiet nodered.service; then
        if [ -d "/etc/letsencrypt/live" ]; then
            echo " Node-RED should be running and accessible at https://$DOMAIN:1880"
        else
            echo " Node-RED should be running and accessible at http://$DOMAIN:1880"
        fi
    else
        echo " Node-RED service is not running. Check the service status."
    fi
    
    # Check Mumble server status
    if systemctl is-active --quiet mumble-server; then
        if [ -d "/etc/letsencrypt/live" ]; then
            echo " Mumble server should be running at $DOMAIN:64738 (SSL enabled)"
        else
            echo " Mumble server should be running at $DOMAIN:64738 (SSL disabled)"
        fi
    else
        echo " Mumble server is not running. Check the service status."
    fi
    
    # Check MediaMTX server status
    if systemctl is-active --quiet mediamtx; then
        echo " MediaMTX server should be running at:"
        echo "   RTSP: rtsp://$DOMAIN:8554"
        echo "   RTMP: rtmp://$DOMAIN:1935"
        echo "   HLS: http://$DOMAIN:8888"
        echo "   WebRTC: http://$DOMAIN:8889"
        echo "   SRT: srt://$DOMAIN:8890"
    else
        echo " MediaMTX server is not running. Check the service status."
    fi
    
fi