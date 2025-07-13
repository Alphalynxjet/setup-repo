#!/bin/bash

SCRIPT_PATH=$(realpath "$(dirname "${BASH_SOURCE[0]}")")
source ${SCRIPT_PATH}/inc/functions.sh

conf ${1}

##
# TAK Server Post-Install: LetsEncrypt Auto-Renewal Setup
# This script sets up automatic certificate renewal and import for TAK Server

echo
msg $info "Setting up LetsEncrypt automatic certificate renewal..."

# Only set up renewal if LetsEncrypt is enabled
if [[ "$LETSENCRYPT" != "true" ]]; then
    msg $warn "LetsEncrypt not enabled, skipping auto-renewal setup"
    exit 0
fi

# Check if certificates exist
if [ ! -d "/etc/letsencrypt/live/${TAK_URI}" ]; then
    msg $warn "LetsEncrypt certificates not found for ${TAK_URI}, skipping auto-renewal setup"
    exit 0
fi

# Create the auto-renewal script
RENEWAL_SCRIPT="${SCRIPT_PATH}/letsencrypt-auto-renew.sh"
msg $info "Creating renewal script: ${RENEWAL_SCRIPT}"

cat > "${RENEWAL_SCRIPT}" << 'EOF'
#!/bin/bash

# LetsEncrypt Auto-Renewal Script for TAK Server
# This script checks for certificate renewal and imports new certificates if renewed

# Set full PATH for cron compatibility
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

SCRIPT_PATH=$(realpath "$(dirname "${BASH_SOURCE[0]}")")
source ${SCRIPT_PATH}/inc/functions.sh

# Find the TAK_ALIAS directory (exclude cert-backup and look for config.inc.sh)
RELEASE_DIR="${SCRIPT_PATH}/../release"
TAK_ALIAS=""

# Look for directories that contain config.inc.sh (the actual TAK installation)
for dir in "${RELEASE_DIR}"/*; do
    if [ -d "$dir" ] && [ -f "$dir/config.inc.sh" ]; then
        TAK_ALIAS=$(basename "$dir")
        break
    fi
done

if [ -z "$TAK_ALIAS" ]; then
    echo "$(date): ERROR - No TAK release directory with config.inc.sh found" >> /var/log/tak-cert-renewal.log
    exit 1
fi

# Load configuration
conf ${TAK_ALIAS}

# Log start
echo "$(date): Starting certificate renewal check for ${TAK_URI}" >> /var/log/tak-cert-renewal.log

# Check if LetsEncrypt is enabled
if [[ "$LETSENCRYPT" != "true" ]]; then
    echo "$(date): LetsEncrypt not enabled, exiting" >> /var/log/tak-cert-renewal.log
    exit 0
fi

# Store current certificate modification time
CERT_FILE="/etc/letsencrypt/live/${TAK_URI}/fullchain.pem"
if [ ! -f "$CERT_FILE" ]; then
    echo "$(date): ERROR - Certificate file not found: $CERT_FILE" >> /var/log/tak-cert-renewal.log
    exit 1
fi

BEFORE_MTIME=$(stat -c %Y "$CERT_FILE" 2>/dev/null)

# Attempt certificate renewal
echo "$(date): Running certbot renew..." >> /var/log/tak-cert-renewal.log
/usr/bin/certbot renew --quiet

# Check if certificate was renewed
AFTER_MTIME=$(stat -c %Y "$CERT_FILE" 2>/dev/null)

if [ "$BEFORE_MTIME" != "$AFTER_MTIME" ]; then
    echo "$(date): Certificate renewed! Importing new certificate..." >> /var/log/tak-cert-renewal.log
    
    # Non-interactive certificate import
    cd ${RELEASE_PATH}/tak/certs
    
    echo "$(date): Copying LetsEncrypt certificates..." >> /var/log/tak-cert-renewal.log
    sudo cp /etc/letsencrypt/live/${TAK_URI}/fullchain.pem files/letsencrypt.pem
    sudo cp /etc/letsencrypt/live/${TAK_URI}/privkey.pem files/letsencrypt.key.pem
    sudo chown $(whoami) files/letsencrypt*
    
    # Set Java PATH
    export PATH=${ROOT_PATH}/jdk/bin:${PATH}
    
    echo "$(date): Converting certificates to Java keystore..." >> /var/log/tak-cert-renewal.log
    
    # Convert to PKCS12
    openssl pkcs12 -export \
        -in files/letsencrypt.pem \
        -inkey files/letsencrypt.key.pem \
        -name letsencrypt \
        -out files/letsencrypt.p12 \
        -passout pass:${CA_PASS} >> /var/log/tak-cert-renewal.log 2>&1
    
    # Import to Java keystore with noprompt to overwrite existing
    echo "yes" | keytool -importkeystore \
        -srckeystore files/letsencrypt.p12 \
        -srcstorepass ${CA_PASS} \
        -destkeystore files/letsencrypt.jks \
        -deststorepass ${CA_PASS} \
        -srcstoretype PKCS12 >> /var/log/tak-cert-renewal.log 2>&1
    
    # Import certificate bundle
    keytool -import \
        -noprompt \
        -alias lebundle \
        -trustcacerts \
        -file files/letsencrypt.pem  \
        -srcstorepass ${CA_PASS} \
        -keystore files/letsencrypt.jks \
        -deststorepass ${CA_PASS} >> /var/log/tak-cert-renewal.log 2>&1
    
    # Download and import LetsEncrypt root CA
    curl -o files/letsencrypt-root.pem https://letsencrypt.org/certs/isrgrootx1.pem >> /var/log/tak-cert-renewal.log 2>&1
    
    keytool -import \
        -noprompt \
        -alias letsencrypt-root \
        -file files/letsencrypt-root.pem \
        -keystore files/truststore-${TAK_CA_FILE}-bundle.p12 \
        -storetype PKCS12 \
        -storepass ${CA_PASS} >> /var/log/tak-cert-renewal.log 2>&1
    
    chmod 644 files/letsencrypt.* >> /var/log/tak-cert-renewal.log 2>&1
    
    echo "$(date): Certificate import completed" >> /var/log/tak-cert-renewal.log
    
    # Restart TAK Server
    echo "$(date): Restarting TAK Server..." >> /var/log/tak-cert-renewal.log
    cd ${SCRIPT_PATH}
    if ./system.sh ${TAK_ALIAS} restart >> /var/log/tak-cert-renewal.log 2>&1; then
        echo "$(date): TAK Server restart successful" >> /var/log/tak-cert-renewal.log
    else
        echo "$(date): ERROR - TAK Server restart failed" >> /var/log/tak-cert-renewal.log
    fi
else
    echo "$(date): No certificate renewal needed" >> /var/log/tak-cert-renewal.log
fi

echo "$(date): Certificate renewal check completed" >> /var/log/tak-cert-renewal.log
EOF

# Make the renewal script executable
chmod +x "${RENEWAL_SCRIPT}"
msg $success "Created renewal script: ${RENEWAL_SCRIPT}"

# Create log file with proper permissions
touch /var/log/tak-cert-renewal.log
chmod 644 /var/log/tak-cert-renewal.log
msg $success "Created log file: /var/log/tak-cert-renewal.log"

# Set up cron job for daily renewal check at 2 AM
CRON_JOB="0 2 * * * ${RENEWAL_SCRIPT} >> /var/log/tak-cert-renewal.log 2>&1"

# Check if cron job already exists
if ! crontab -l 2>/dev/null | grep -q "letsencrypt-auto-renew.sh"; then
    # Add the cron job
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
    msg $success "Added daily cron job for certificate renewal at 2 AM"
else
    msg $info "Cron job for certificate renewal already exists"
fi

# Display cron job information
msg $info "Current cron jobs:"
crontab -l 2>/dev/null | grep -E "(letsencrypt|tak)" || echo "No TAK-related cron jobs found"

echo
msg $success "LetsEncrypt auto-renewal setup completed!"
msg $info "Certificate renewal will run daily at 2 AM"
msg $info "Renewal logs will be written to: /var/log/tak-cert-renewal.log"
msg $info "To manually test renewal: ${RENEWAL_SCRIPT}"

echo


