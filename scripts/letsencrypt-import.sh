#!/bin/bash

SCRIPT_PATH=$(realpath "$(dirname "${BASH_SOURCE[0]}")")
source ${SCRIPT_PATH}/inc/functions.sh

conf ${1}

if [ -z "${TAK_URI}" ]; then
    msg $error "TAK_URI not configured"
    exit 1
fi

if [ ! -d "/etc/letsencrypt/live/${TAK_URI}" ]; then
    msg $error "LetsEncrypt certificates not found for domain ${TAK_URI}"
    msg $info "Run: bash ${SCRIPT_PATH}/letsencrypt-request.sh ${1}"
    exit 1
fi

# Handle different installation types
if [ "${INSTALLER}" = "docker" ]; then
    CERTS_DIR="${ROOT_PATH}/tak-pack/certs"
    if [ ! -d "${CERTS_DIR}" ]; then
        mkdir -p "${CERTS_DIR}/files"
    fi
else
    CERTS_DIR="${RELEASE_PATH}/tak/certs"
    if [ ! -d "${CERTS_DIR}" ]; then
        msg $error "TAK certs directory not found: ${CERTS_DIR}"
        exit 1
    fi
fi

cd ${CERTS_DIR}

msg $warn "\nImporting Lets Encrypt requires \`sudo\` access: \n"

if ! sudo cp /etc/letsencrypt/live/${TAK_URI}/fullchain.pem files/letsencrypt.pem; then
    msg $error "Failed to copy fullchain.pem"
    exit 1
fi

if ! sudo cp /etc/letsencrypt/live/${TAK_URI}/privkey.pem files/letsencrypt.key.pem; then
    msg $error "Failed to copy privkey.pem"
    exit 1
fi

if ! sudo chown $(whoami) files/letsencrypt*; then
    msg $error "Failed to change ownership of certificate files"
    exit 1
fi

msg $info "\nImporting LetsEncrypt Certificate"

export PATH=${ROOT_PATH}/jdk/bin:${PATH}

if ! openssl pkcs12 -export \
    -in files/letsencrypt.pem \
    -inkey files/letsencrypt.key.pem \
    -name letsencrypt \
    -out files/letsencrypt.p12 \
    -passout pass:${CA_PASS}; then
    msg $error "Failed to create PKCS12 certificate"
    exit 1
fi

if ! keytool -importkeystore \
    -noprompt \
    -srckeystore files/letsencrypt.p12 \
    -srcstorepass ${CA_PASS} \
    -destkeystore files/letsencrypt.jks \
    -deststorepass ${CA_PASS} \
    -srcstoretype PKCS12; then
    msg $error "Failed to import keystore"
    exit 1
fi

if ! keytool -import \
    -noprompt \
    -alias lebundle \
    -trustcacerts \
    -file files/letsencrypt.pem  \
    -srcstorepass ${CA_PASS} \
    -keystore files/letsencrypt.jks \
    -deststorepass ${CA_PASS}; then
    msg $error "Failed to import certificate bundle"
    exit 1
fi 

msg $info "\nAdding LetsEncrypt Root to Bundled Truststore"
if ! curl -o files/letsencrypt-root.pem https://letsencrypt.org/certs/isrgrootx1.pem; then
    msg $error "Failed to download LetsEncrypt root certificate"
    exit 1
fi

if ! keytool -import \
    -noprompt \
    -alias letsencrypt-root \
    -file files/letsencrypt-root.pem \
    -keystore files/truststore-${TAK_CA_FILE}-bundle.p12 \
    -storetype PKCS12 \
    -storepass ${CA_PASS}; then
    msg $error "Failed to import LetsEncrypt root certificate to truststore"
    exit 1
fi

if ! chmod 644 files/letsencrypt.*; then
    msg $error "Failed to set certificate file permissions"
    exit 1
fi

msg $success "LetsEncrypt certificates imported successfully"
msg $info "\nNext steps:"
msg $info "1. Restart TAK Server to use new certificates"
msg $info "2. Setup auto-renewal: bash ${SCRIPT_PATH}/setup-letsencrypt-cron.sh ${1} setup"