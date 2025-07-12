#!/bin/bash

SCRIPT_PATH=$(realpath "$(dirname "${BASH_SOURCE[0]}")")
source ${SCRIPT_PATH}/inc/functions.sh

LOG_FILE="/var/log/letsencrypt-renewal.log"
BACKUP_DIR="/var/backups/tak-certs"

log_message() {
    local level=$1
    local message=$2
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $message" | sudo tee -a "$LOG_FILE"
}

backup_certificates() {
    log_message "INFO" "Backing up existing certificates"
    sudo mkdir -p "$BACKUP_DIR"
    
    if [ -d "${RELEASE_PATH}/tak/certs/files" ]; then
        sudo cp -r "${RELEASE_PATH}/tak/certs/files" "$BACKUP_DIR/certs-backup-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    fi
}

restart_services() {
    log_message "INFO" "Restarting TAK Server services"
    
    if [[ "${INSTALLER}" == "docker" ]]; then
        if [ -f "${RELEASE_PATH}/docker-compose.yml" ]; then
            cd "${RELEASE_PATH}"
            sudo docker-compose restart tak-server 2>&1 | sudo tee -a "$LOG_FILE"
            if [ $? -eq 0 ]; then
                log_message "INFO" "Docker TAK Server restarted successfully"
            else
                log_message "ERROR" "Failed to restart Docker TAK Server"
                return 1
            fi
        else
            log_message "ERROR" "Docker compose file not found at ${RELEASE_PATH}/docker-compose.yml"
            return 1
        fi
    elif [[ "${INSTALLER}" == "ubuntu" ]]; then
        sudo systemctl restart takserver 2>&1 | sudo tee -a "$LOG_FILE"
        if [ $? -eq 0 ]; then
            log_message "INFO" "Ubuntu TAK Server restarted successfully"
        else
            log_message "ERROR" "Failed to restart Ubuntu TAK Server"
            return 1
        fi
    else
        log_message "WARNING" "Unknown installer type: ${INSTALLER}. Manual service restart may be required."
    fi
}

send_notification() {
    local status=$1
    local message=$2
    
    if [ -n "$LE_NOTIFICATION_EMAIL" ] && command -v mail >/dev/null 2>&1; then
        echo "$message" | mail -s "TAK Server LetsEncrypt Renewal $status" "$LE_NOTIFICATION_EMAIL"
    fi
    
    if [ -n "$LE_WEBHOOK_URL" ] && command -v curl >/dev/null 2>&1; then
        curl -X POST "$LE_WEBHOOK_URL" \
             -H "Content-Type: application/json" \
             -d "{\"status\":\"$status\",\"message\":\"$message\",\"timestamp\":\"$(date -Iseconds)\",\"hostname\":\"$(hostname)\"}" \
             >/dev/null 2>&1 || true
    fi
}

main() {
    local config_file="${1:-}"
    
    log_message "INFO" "Starting LetsEncrypt certificate renewal process"
    
    conf "$config_file"
    
    if [ -z "$TAK_URI" ] || [ -z "$LETSENCRYPT" ] || [ "$LETSENCRYPT" != "true" ]; then
        log_message "ERROR" "LetsEncrypt not properly configured. TAK_URI=$TAK_URI, LETSENCRYPT=$LETSENCRYPT"
        exit 1
    fi
    
    if [ ! -d "/etc/letsencrypt/live/${TAK_URI}" ]; then
        log_message "ERROR" "LetsEncrypt certificates not found for domain ${TAK_URI}"
        exit 1
    fi
    
    backup_certificates
    
    log_message "INFO" "Importing renewed LetsEncrypt certificates for domain ${TAK_URI}"
    
    if ! bash "${SCRIPT_PATH}/letsencrypt-import.sh" "$config_file" 2>&1 | sudo tee -a "$LOG_FILE"; then
        log_message "ERROR" "Failed to import LetsEncrypt certificates"
        send_notification "FAILED" "LetsEncrypt certificate import failed for ${TAK_URI} on $(hostname)"
        exit 1
    fi
    
    if ! restart_services; then
        log_message "ERROR" "Failed to restart TAK Server services after certificate renewal"
        send_notification "FAILED" "TAK Server restart failed after LetsEncrypt renewal for ${TAK_URI} on $(hostname)"
        exit 1
    fi
    
    log_message "INFO" "LetsEncrypt certificate renewal completed successfully"
    send_notification "SUCCESS" "LetsEncrypt certificates renewed successfully for ${TAK_URI} on $(hostname)"
    
    if command -v "${SCRIPT_PATH}/cert-check.sh" >/dev/null 2>&1; then
        bash "${SCRIPT_PATH}/cert-check.sh" "$config_file" 2>&1 | sudo tee -a "$LOG_FILE"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi