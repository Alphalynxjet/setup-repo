#!/bin/bash

SCRIPT_PATH=$(realpath "$(dirname "${BASH_SOURCE[0]}")")
source ${SCRIPT_PATH}/inc/functions.sh

conf ${1}

cd ${RELEASE_PATH}/tak/certs

msg $warn "\nImporting Lets Encrypt requires \`sudo\` access: \n"

sudo cp /etc/letsencrypt/live/${TAK_URI}/fullchain.pem files/letsencrypt.pem
sudo cp /etc/letsencrypt/live/${TAK_URI}/privkey.pem files/letsencrypt.key.pem
sudo chown $(whoami) files/letsencrypt*

msg $info "\nImporting LetsEncrypt Certificate"

export PATH=${ROOT_PATH}/jdk/bin:${PATH}

openssl pkcs12 -export \
    -in files/letsencrypt.pem \
    -inkey files/letsencrypt.key.pem \
    -name letsencrypt \
    -out files/letsencrypt.p12 \
    -passout pass:${CA_PASS}

keytool -importkeystore \
    -srckeystore files/letsencrypt.p12 \
    -srcstorepass ${CA_PASS} \
    -destkeystore files/letsencrypt.jks \
    -deststorepass ${CA_PASS} \
    -srcstoretype PKCS12

keytool -import \
    -noprompt \
    -alias lebundle \
    -trustcacerts \
    -file files/letsencrypt.pem  \
    -srcstorepass ${CA_PASS} \
    -keystore files/letsencrypt.jks \
    -deststorepass ${CA_PASS} 

msg $info "\nAdding LetsEncrypt Root to Bundled Truststore"
curl -o files/letsencrypt-root.pem https://letsencrypt.org/certs/isrgrootx1.pem
# curl -o files/letsencrypt-intermediate.pem https://letsencrypt.org/certs/lets-encrypt-x3-cross-signed.pem

keytool -import \
    -noprompt \
    -alias letsencrypt-root \
    -file files/letsencrypt-root.pem \
    -keystore files/truststore-${TAK_CA_FILE}-bundle.p12 \
    -storetype PKCS12 \
    -storepass ${CA_PASS}

chmod 644 files/letsencrypt.*

# Restart Node-RED service if it's running to reload certificates
if systemctl is-active --quiet nodered.service; then
    msg $info "Restarting Node-RED service to reload certificates..."
    sudo systemctl restart nodered.service
    sleep 2
    if systemctl is-active --quiet nodered.service; then
        msg $success "Node-RED service restarted successfully"
    else
        msg $warn "Node-RED service failed to restart"
    fi
else
    msg $info "Node-RED service is not running, skipping restart"
fi

# Restart Mumble server if it's running to reload certificates
if systemctl is-active --quiet mumble-server; then
    msg $info "Restarting Mumble server to reload certificates..."
    # Copy new certificates to Mumble directory
    if [ -d "/etc/mumble-server/certs" ]; then
        sudo cp /etc/letsencrypt/live/${TAK_URI}/fullchain.pem /etc/mumble-server/certs/
        sudo cp /etc/letsencrypt/live/${TAK_URI}/privkey.pem /etc/mumble-server/certs/
        sudo chown -R mumble-server:mumble-server /etc/mumble-server/certs/
        sudo chmod 640 /etc/mumble-server/certs/fullchain.pem
        sudo chmod 640 /etc/mumble-server/certs/privkey.pem
    fi
    
    sudo systemctl restart mumble-server
    sleep 2
    if systemctl is-active --quiet mumble-server; then
        msg $success "Mumble server restarted successfully"
    else
        msg $warn "Mumble server failed to restart"
    fi
else
    msg $info "Mumble server is not running, skipping restart"
fi