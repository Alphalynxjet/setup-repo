#!/bin/bash

SCRIPT_PATH=$(realpath "$(dirname "${BASH_SOURCE[0]}")")
source ${SCRIPT_PATH}/inc/functions.sh

conf ${1}

if [ -z "${TAK_URI}" ] || [ -z "${LE_EMAIL}" ]; then
    msg $error "TAK_URI and LE_EMAIL must be configured"
    exit 1
fi

if [[ "${TAK_URI}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    msg $error "TAK_URI must be a domain name (FQDN), not an IP address: ${TAK_URI}"
    exit 1
fi

if [ -d "/etc/letsencrypt/live/${TAK_URI}" ]; then
    msg $warn "LetsEncrypt certificates already exist for ${TAK_URI}"
    msg $info "To renew, run: sudo certbot renew"
    exit 0
fi

if [ "${LE_VALIDATOR}" = "web" ]; then
    msg $warn "\nRequesting LetsEncrypt: HTTP Validator"
    if ! sudo certbot certonly --standalone -d ${TAK_URI} -m ${LE_EMAIL} --agree-tos --non-interactive; then
        msg $error "Failed to obtain LetsEncrypt certificate"
        exit 1
    fi
else
    msg $warn "\nRequesting LetsEncrypt: DNS Validator"
    if ! sudo certbot certonly --manual --preferred-challenges dns -d ${TAK_URI} -m ${LE_EMAIL}; then
        msg $error "Failed to obtain LetsEncrypt certificate"
        exit 1
    fi
fi

msg $success "LetsEncrypt certificate obtained successfully for ${TAK_URI}"
msg $info "\nNext steps:"
msg $info "1. Run: bash ${SCRIPT_PATH}/letsencrypt-import.sh ${1}"
msg $info "2. Setup auto-renewal: bash ${SCRIPT_PATH}/setup-letsencrypt-cron.sh ${1} setup"

pause