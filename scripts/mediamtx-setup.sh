#!/bin/bash

export SCRIPT_PATH=$(realpath "$(dirname "${BASH_SOURCE[0]}")")
source "${SCRIPT_PATH}/inc/functions.sh"

install_init

###########
#
#            MEDIAMTX SETUP SCRIPT
#
##

msg $info "Starting MediaMTX setup..."

# Check if Go is installed
if ! command -v go &> /dev/null; then
    msg $info "Go is not installed. Installing Go..."
    sudo apt update
    sudo apt install -y golang-go
fi

# Set up MediaMTX directory
MEDIAMTX_DIR="/opt/mediamtx"
MEDIAMTX_USER="mediamtx"
MEDIAMTX_VERSION="latest"

# Create MediaMTX user
if ! id "$MEDIAMTX_USER" &>/dev/null; then
    msg $info "Creating MediaMTX system user..."
    sudo useradd --system --no-create-home --shell /bin/false $MEDIAMTX_USER
fi

# Create MediaMTX directory
msg $info "Creating MediaMTX directory..."
sudo mkdir -p $MEDIAMTX_DIR
sudo mkdir -p /etc/mediamtx
sudo mkdir -p /var/log/mediamtx

# Download MediaMTX
msg $info "Fetching latest MediaMTX release version..."
LATEST_TAG=$(curl -s https://api.github.com/repos/bluenviron/mediamtx/releases/latest | grep -Po '"tag_name": "\K.*?(?=")')

if [ -z "$LATEST_TAG" ]; then
    msg $danger "Error: Could not fetch latest release tag."
    exit 1
fi

msg $info "Latest version is $LATEST_TAG"

# Detect architecture and map to MediaMTX naming
ARCH=$(dpkg --print-architecture)
case $ARCH in
    amd64)
        MEDIAMTX_ARCH="amd64"
        ;;
    arm64)
        MEDIAMTX_ARCH="arm64v8"
        ;;
    armhf)
        MEDIAMTX_ARCH="armv7"
        ;;
    *)
        MEDIAMTX_ARCH="amd64"
        ;;
esac

# Download MediaMTX
cd /tmp
DOWNLOAD_URL="https://github.com/bluenviron/mediamtx/releases/download/${LATEST_TAG}/mediamtx_${LATEST_TAG}_linux_${MEDIAMTX_ARCH}.tar.gz"
msg $info "Downloading MediaMTX $LATEST_TAG from: $DOWNLOAD_URL"
curl -L -o mediamtx.tar.gz "$DOWNLOAD_URL"

if [ ! -f mediamtx.tar.gz ]; then
    msg $danger "Failed to download MediaMTX"
    exit 1
fi

msg $info "Extracting and installing..."
tar -xzf mediamtx.tar.gz
if [ ! -f mediamtx ]; then
    msg $danger "MediaMTX binary not found in archive"
    exit 1
fi

sudo mv mediamtx $MEDIAMTX_DIR/
sudo chmod +x $MEDIAMTX_DIR/mediamtx
sudo chown -R $MEDIAMTX_USER:$MEDIAMTX_USER $MEDIAMTX_DIR

# Create MediaMTX configuration
msg $info "Creating MediaMTX configuration..."
sudo tee /etc/mediamtx/mediamtx.yml > /dev/null << EOF
# MediaMTX configuration
logLevel: info
logDestinations: [stdout, file]
logFile: /var/log/mediamtx/mediamtx.log

# API server
api: yes
apiAddress: 127.0.0.1:9997

# Metrics server
metrics: yes
metricsAddress: 127.0.0.1:9998

# RTSP server
rtsp: yes
rtspAddress: :8554

# RTMP server
rtmp: yes
rtmpAddress: :1935

# HLS server
hls: yes
hlsAddress: :8888

# WebRTC server
webrtc: yes
webrtcAddress: :8889
webrtcICEServers2:
  - url: stun:stun.l.google.com:19302

# SRT server
srt: yes
srtAddress: :8890

# No authentication - remove authMethod for open access

# Path defaults
pathDefaults:
  # Source
  source: publisher
  sourceProtocol: automatic
  sourceAnyPortEnable: no
  sourceFingerprint: 
  sourceOnDemand: no
  sourceOnDemandStartTimeout: 10s
  sourceOnDemandCloseAfter: 10s
  sourceRedirect: 
  overridePublisher: yes
  fallback: 

# Paths
paths:
  # Default path for all streams - no authentication
  ~^.*$:
    source: publisher
    
  # Example specific path
  test:
    source: publisher
EOF

# Set proper permissions
sudo chown -R $MEDIAMTX_USER:$MEDIAMTX_USER /etc/mediamtx
sudo chown -R $MEDIAMTX_USER:$MEDIAMTX_USER /var/log/mediamtx

# Create systemd service
msg $info "Creating MediaMTX systemd service..."
sudo tee /etc/systemd/system/mediamtx.service > /dev/null << EOF
[Unit]
Description=MediaMTX media server
After=network.target

[Service]
Type=simple
User=$MEDIAMTX_USER
Group=$MEDIAMTX_USER
ExecStart=$MEDIAMTX_DIR/mediamtx /etc/mediamtx/mediamtx.yml
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Enable and start MediaMTX service
msg $info "Starting MediaMTX service..."
sudo systemctl daemon-reload
sudo systemctl enable mediamtx
sudo systemctl start mediamtx

# Wait for service to start
sleep 3

# Check service status
if sudo systemctl is-active --quiet mediamtx; then
    msg $success "MediaMTX started successfully"
    msg $success "MediaMTX is available at:"
    msg $success "  RTSP: rtsp://$IP_ADDRESS:8554"
    msg $success "  RTMP: rtmp://$IP_ADDRESS:1935"
    msg $success "  HLS: http://$IP_ADDRESS:8888"
    msg $success "  WebRTC: http://$IP_ADDRESS:8889"
    msg $success "  SRT: srt://$IP_ADDRESS:8890"
    msg $success "  API: http://127.0.0.1:9997"
    msg $success "  Metrics: http://127.0.0.1:9998"
    
    # Save service info to info file if RELEASE_PATH is set
    if [ -n "${RELEASE_PATH}" ]; then
        info ${RELEASE_PATH} "MediaMTX Media Server:" init
        info ${RELEASE_PATH} "RTSP: rtsp://$IP_ADDRESS:8554"
        info ${RELEASE_PATH} "RTMP: rtmp://$IP_ADDRESS:1935"
        info ${RELEASE_PATH} "HLS: http://$IP_ADDRESS:8888"
        info ${RELEASE_PATH} "WebRTC: http://$IP_ADDRESS:8889"
        info ${RELEASE_PATH} "SRT: srt://$IP_ADDRESS:8890"
        info ${RELEASE_PATH} "API: http://127.0.0.1:9997"
        info ${RELEASE_PATH} "Metrics: http://127.0.0.1:9998"
        
        # Also save to a separate file for run.sh to read
        echo "MediaMTX RTSP: rtsp://$IP_ADDRESS:8554" > "${RELEASE_PATH}/mediamtx-credentials.txt"
        echo "MediaMTX RTMP: rtmp://$IP_ADDRESS:1935" >> "${RELEASE_PATH}/mediamtx-credentials.txt"
        echo "MediaMTX HLS: http://$IP_ADDRESS:8888" >> "${RELEASE_PATH}/mediamtx-credentials.txt"
        echo "MediaMTX WebRTC: http://$IP_ADDRESS:8889" >> "${RELEASE_PATH}/mediamtx-credentials.txt"
        echo "MediaMTX SRT: srt://$IP_ADDRESS:8890" >> "${RELEASE_PATH}/mediamtx-credentials.txt"
        echo "MediaMTX API: http://127.0.0.1:9997" >> "${RELEASE_PATH}/mediamtx-credentials.txt"
        echo "MediaMTX Metrics: http://127.0.0.1:9998" >> "${RELEASE_PATH}/mediamtx-credentials.txt"
    else
        # If no RELEASE_PATH, save to current directory for run.sh
        echo "MediaMTX RTSP: rtsp://$IP_ADDRESS:8554" > "mediamtx-credentials.txt"
        echo "MediaMTX RTMP: rtmp://$IP_ADDRESS:1935" >> "mediamtx-credentials.txt"
        echo "MediaMTX HLS: http://$IP_ADDRESS:8888" >> "mediamtx-credentials.txt"
        echo "MediaMTX WebRTC: http://$IP_ADDRESS:8889" >> "mediamtx-credentials.txt"
        echo "MediaMTX SRT: srt://$IP_ADDRESS:8890" >> "mediamtx-credentials.txt"
        echo "MediaMTX API: http://127.0.0.1:9997" >> "mediamtx-credentials.txt"
        echo "MediaMTX Metrics: http://127.0.0.1:9998" >> "mediamtx-credentials.txt"
    fi
    
    # Clean up temporary files
    rm -f /tmp/mediamtx.tar.gz
    
else
    msg $danger "Failed to start MediaMTX service"
    sudo systemctl status mediamtx
    exit 1
fi

msg $success "MediaMTX setup completed successfully!"