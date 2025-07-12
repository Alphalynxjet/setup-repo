#!/bin/bash

SCRIPT_PATH=$(realpath "$(dirname "${BASH_SOURCE[0]}")")
source ${SCRIPT_PATH}/inc/functions.sh

LOG_FILE="/var/log/tak-automated-setup.log"

log_message() {
    local level=$1
    local message=$2
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

generate_secure_password() {
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-20
}

auto_generate_variables() {
    log_message "INFO" "Auto-generating missing configuration variables"
    
    # Auto-generate passwords if not set
    if [ -z "${TAK_DB_PASS:-}" ]; then
        export TAK_DB_PASS=$(generate_secure_password)
        log_message "INFO" "Generated TAK_DB_PASS"
    fi
    
    if [ -z "${CA_PASS:-}" ]; then
        export CA_PASS=$(generate_secure_password)
        log_message "INFO" "Generated CA_PASS"
    fi
    
    if [ -z "${CERT_PASS:-}" ]; then
        export CERT_PASS=$(generate_secure_password)
        log_message "INFO" "Generated CERT_PASS"
    fi
    
    # Set defaults for certificate info
    export ORGANIZATION="${ORGANIZATION:-TAK Organization}"
    export ORGANIZATIONAL_UNIT="${ORGANIZATIONAL_UNIT:-Operations}"
    export CITY="${CITY:-City}"
    export STATE="${STATE:-ST}"
    export COUNTRY="${COUNTRY:-US}"
    export CLIENT_VALID_DAYS="${CLIENT_VALID_DAYS:-30}"
    
    # Set defaults for other variables
    export INSTALLER="${INSTALLER:-docker}"
    export VERSION="${VERSION:-latest}"
    export LETSENCRYPT="${LETSENCRYPT:-true}"
    export LE_VALIDATOR="${LE_VALIDATOR:-web}"
    export LE_NOTIFICATION_EMAIL="${LE_NOTIFICATION_EMAIL:-${LE_EMAIL}}"
}

validate_environment() {
    local errors=0
    
    log_message "INFO" "Validating environment variables"
    
    # Required variables (minimal set)
    local required_vars=(
        "TAK_URI"
        "TAK_ALIAS" 
        "LE_EMAIL"
    )
    
    # LetsEncrypt variables (if enabled)
    if [ "${LETSENCRYPT}" = "true" ]; then
        required_vars+=("LE_EMAIL" "LE_VALIDATOR")
    fi
    
    for var in "${required_vars[@]}"; do
        if [ -z "${!var}" ]; then
            log_message "ERROR" "Required environment variable not set: $var"
            errors=$((errors + 1))
        fi
    done
    
    # Validate specific formats
    if [[ "${TAK_URI}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_message "ERROR" "TAK_URI must be a domain name (FQDN), not an IP address: ${TAK_URI}"
        errors=$((errors + 1))
    fi
    
    if [ "${LETSENCRYPT}" = "true" ] && [[ ! "${LE_EMAIL}" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
        log_message "ERROR" "LE_EMAIL must be a valid email address: ${LE_EMAIL}"
        errors=$((errors + 1))
    fi
    
    if [ "${LE_VALIDATOR}" != "web" ] && [ "${LE_VALIDATOR}" != "dns" ]; then
        log_message "ERROR" "LE_VALIDATOR must be 'web' or 'dns': ${LE_VALIDATOR}"
        errors=$((errors + 1))
    fi
    
    if [ "${INSTALLER}" != "docker" ] && [ "${INSTALLER}" != "ubuntu" ]; then
        log_message "ERROR" "INSTALLER must be 'docker' or 'ubuntu': ${INSTALLER}"
        errors=$((errors + 1))
    fi
    
    return $errors
}

download_tak_server() {
    if [ -z "${TAK_DOWNLOAD_URL}" ]; then
        log_message "INFO" "TAK_DOWNLOAD_URL not provided, skipping automatic download"
        return 0
    fi
    
    log_message "INFO" "Downloading TAK Server from Google Drive"
    
    if ! command -v gdown >/dev/null 2>&1; then
        log_message "INFO" "Installing gdown for Google Drive downloads"
        pip install gdown || {
            log_message "ERROR" "Failed to install gdown"
            return 1
        }
    fi
    
    local download_dir="${ROOT_PATH}/downloads"
    mkdir -p "$download_dir"
    cd "$download_dir"
    
    if ! gdown --fuzzy "${TAK_DOWNLOAD_URL}"; then
        log_message "ERROR" "Failed to download TAK Server file"
        return 1
    fi
    
    local downloaded_file=$(ls -t *.zip *.tar.gz *.deb 2>/dev/null | head -1)
    if [ -z "$downloaded_file" ]; then
        log_message "ERROR" "No TAK Server file found after download"
        return 1
    fi
    
    log_message "INFO" "Downloaded TAK Server file: $downloaded_file"
    
    # Move to expected location based on installer type
    if [ "${INSTALLER}" = "docker" ]; then
        local target_dir="${ROOT_PATH}/tak-pack"
        mkdir -p "$target_dir"
        mv "$downloaded_file" "$target_dir/"
        log_message "INFO" "Moved TAK Server file to: $target_dir/$downloaded_file"
    else
        log_message "INFO" "TAK Server file ready for Ubuntu installation: $download_dir/$downloaded_file"
    fi
    
    return 0
}

generate_config() {
    local config_file="${1:-${ROOT_PATH}/config.inc.sh}"
    
    log_message "INFO" "Generating configuration file: $config_file"
    
    cat > "$config_file" << EOF
####
#
# Auto-generated TAK Server Configuration
# Generated on: $(date)
#
####

## TAK
export TAK_DB_ALIAS=${TAK_DB_ALIAS:-${TAK_URI}}
export TAK_ADMIN=${TAK_ADMIN:-tak-admin}
export TAK_COT_PORT=${TAK_COT_PORT:-8089}

## LetsEncrypt
export LETSENCRYPT=${LETSENCRYPT:-false}
export LE_EMAIL=${LE_EMAIL:-}
export LE_VALIDATOR=${LE_VALIDATOR:-web}
export LE_NOTIFICATION_EMAIL=${LE_NOTIFICATION_EMAIL:-}
export LE_WEBHOOK_URL=${LE_WEBHOOK_URL:-}

## Certificate info
export CA_PASS=${CA_PASS}
export CERT_PASS=${CERT_PASS}
export ORGANIZATION=${ORGANIZATION}
export ORGANIZATIONAL_UNIT=${ORGANIZATIONAL_UNIT}
export CITY=${CITY}
export STATE=${STATE}
export COUNTRY=${COUNTRY}
export CLIENT_VALID_DAYS=${CLIENT_VALID_DAYS}

## Docker
export DOCKER_SUBNET=${DOCKER_SUBNET:-172.20.0.0/24}

## Install Options
export TAK_ALIAS=${TAK_ALIAS}
export TAK_URI=${TAK_URI}
export TAK_DB_PASS=${TAK_DB_PASS}
export INSTALLER=${INSTALLER}
export VERSION=${VERSION}
EOF
    
    chmod 600 "$config_file"
    log_message "INFO" "Configuration file generated successfully"
}

setup_letsencrypt() {
    local config_file="$1"
    
    if [ "${LETSENCRYPT}" != "true" ]; then
        log_message "INFO" "LetsEncrypt disabled, skipping setup"
        return 0
    fi
    
    log_message "INFO" "Setting up LetsEncrypt certificates"
    
    # Request certificate
    if ! bash "${SCRIPT_PATH}/letsencrypt-request.sh" "$config_file"; then
        log_message "ERROR" "Failed to request LetsEncrypt certificate"
        return 1
    fi
    
    # Import certificate
    if ! bash "${SCRIPT_PATH}/letsencrypt-import.sh" "$config_file"; then
        log_message "ERROR" "Failed to import LetsEncrypt certificate"
        return 1
    fi
    
    # Setup dual renewal system
    if ! bash "${SCRIPT_PATH}/setup-renewal-system.sh" "$config_file" setup; then
        log_message "ERROR" "Failed to setup renewal system"
        return 1
    fi
    
    log_message "INFO" "LetsEncrypt setup completed successfully"
    return 0
}

run_setup() {
    local config_file="${CONFIG_FILE:-${ROOT_PATH}/config.inc.sh}"
    
    log_message "INFO" "Starting automated TAK Server setup"
    
    # Auto-generate missing variables
    auto_generate_variables
    
    # Validate environment
    if ! validate_environment; then
        log_message "ERROR" "Environment validation failed"
        exit 1
    fi
    
    # Download TAK Server if URL provided
    if ! download_tak_server; then
        log_message "ERROR" "TAK Server download failed"
        exit 1
    fi
    
    # Generate configuration
    if ! generate_config "$config_file"; then
        log_message "ERROR" "Configuration generation failed"
        exit 1
    fi
    
    # Setup LetsEncrypt if enabled
    if ! setup_letsencrypt "$config_file"; then
        log_message "ERROR" "LetsEncrypt setup failed"
        exit 1
    fi
    
    # Run main setup script
    log_message "INFO" "Running main TAK Server setup"
    if ! bash "${SCRIPT_PATH}/setup.sh" "$config_file"; then
        log_message "ERROR" "TAK Server setup failed"
        exit 1
    fi
    
    log_message "INFO" "Automated TAK Server setup completed successfully"
    
    # Display status
    if [ "${LETSENCRYPT}" = "true" ]; then
        echo ""
        echo "=== Certificate Status ==="
        bash "${SCRIPT_PATH}/cert-check.sh" "$config_file"
        
        echo ""
        echo "=== Renewal System Status ==="
        bash "${SCRIPT_PATH}/renewal-health-check.sh" "$config_file"
    fi
}

usage() {
    echo "TAK Server Automated Setup"
    echo "=========================="
    echo ""
    echo "This script sets up TAK Server using environment variables."
    echo "See AUTOMATION.md for required environment variables."
    echo ""
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -c, --config FILE    Config file path (default: ./config.inc.sh)"
    echo "  -h, --help           Show this help"
    echo ""
    echo "Environment Variables:"
    echo "  See AUTOMATION.md for complete list of required variables"
    echo ""
    echo "Example:"
    echo "  export TAK_URI=tak.example.com"
    echo "  export LETSENCRYPT=true"
    echo "  export LE_EMAIL=admin@example.com"
    echo "  ... (see AUTOMATION.md for full list)"
    echo "  $0"
}

main() {
    local config_file=""
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--config)
                config_file="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "Unknown argument: $1"
                usage
                exit 1
                ;;
        esac
    done
    
    # Set default config file if not provided
    if [ -n "$config_file" ]; then
        export CONFIG_FILE="$config_file"
    fi
    
    run_setup
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi