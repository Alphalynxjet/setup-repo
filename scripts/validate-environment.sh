#!/bin/bash

SCRIPT_PATH=$(realpath "$(dirname "${BASH_SOURCE[0]}")")
source ${SCRIPT_PATH}/inc/functions.sh

validation_errors=0
validation_warnings=0

log_validation() {
    local level=$1
    local variable=$2
    local message=$3
    local suggestion="${4:-}"
    
    case "$level" in
        "ERROR")
            msg $error "✗ $variable: $message"
            if [ -n "$suggestion" ]; then
                echo "  Suggestion: $suggestion"
            fi
            validation_errors=$((validation_errors + 1))
            ;;
        "WARNING")
            msg $warn "⚠ $variable: $message"
            if [ -n "$suggestion" ]; then
                echo "  Suggestion: $suggestion"
            fi
            validation_warnings=$((validation_warnings + 1))
            ;;
        "INFO")
            msg $info "ℹ $variable: $message"
            ;;
        "SUCCESS")
            msg $success "✓ $variable: $message"
            ;;
    esac
}

validate_required_variable() {
    local var_name="$1"
    local var_value="${!var_name}"
    local description="$2"
    local suggestion="${3:-}"
    
    if [ -z "$var_value" ]; then
        log_validation "ERROR" "$var_name" "Required variable not set" "export $var_name=\"<value>\""
        return 1
    else
        log_validation "SUCCESS" "$var_name" "Set to '$var_value'"
        return 0
    fi
}

validate_optional_variable() {
    local var_name="$1"
    local var_value="${!var_name}"
    local description="$2"
    local default_value="${3:-}"
    
    if [ -z "$var_value" ]; then
        if [ -n "$default_value" ]; then
            log_validation "INFO" "$var_name" "Not set, will use default: $default_value"
        else
            log_validation "INFO" "$var_name" "Optional variable not set"
        fi
    else
        log_validation "SUCCESS" "$var_name" "Set to '$var_value'"
    fi
}

validate_format_domain() {
    local domain="$1"
    
    # Check if it's an IP address
    if [[ "$domain" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 1
    fi
    
    # Check basic domain format
    if [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        return 0
    fi
    
    return 1
}

validate_format_email() {
    local email="$1"
    
    if [[ "$email" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
        return 0
    fi
    
    return 1
}

validate_format_password() {
    local password="$1"
    local min_length="${2:-8}"
    
    if [ ${#password} -lt $min_length ]; then
        return 1
    fi
    
    # Check for potential problematic characters
    if [[ "$password" =~ [\"\'\`\$] ]]; then
        return 2
    fi
    
    return 0
}

validate_format_country() {
    local country="$1"
    
    if [ ${#country} -eq 2 ] && [[ "$country" =~ ^[A-Z]{2}$ ]]; then
        return 0
    fi
    
    return 1
}

validate_dependencies() {
    echo ""
    msg $info "Checking system dependencies..."
    
    local missing_deps=0
    
    # Required tools
    local required_tools=("openssl" "curl")
    
    for tool in "${required_tools[@]}"; do
        if command -v "$tool" >/dev/null 2>&1; then
            log_validation "SUCCESS" "$tool" "Available"
        else
            log_validation "ERROR" "$tool" "Not found in PATH" "Install $tool package"
            missing_deps=$((missing_deps + 1))
        fi
    done
    
    # Optional tools
    if [ "${TAK_DOWNLOAD_URL:-}" ]; then
        if command -v "gdown" >/dev/null 2>&1; then
            log_validation "SUCCESS" "gdown" "Available for Google Drive downloads"
        else
            log_validation "WARNING" "gdown" "Not found - required for TAK_DOWNLOAD_URL" "pip install gdown"
        fi
    fi
    
    if [ "${LETSENCRYPT:-}" = "true" ]; then
        if command -v "certbot" >/dev/null 2>&1; then
            log_validation "SUCCESS" "certbot" "Available for LetsEncrypt"
        else
            log_validation "ERROR" "certbot" "Not found - required for LetsEncrypt" "Install certbot package"
            missing_deps=$((missing_deps + 1))
        fi
    fi
    
    # Java for certificate operations
    if command -v "keytool" >/dev/null 2>&1; then
        log_validation "SUCCESS" "keytool" "Available"
    else
        log_validation "WARNING" "keytool" "Not found - may be installed during setup" "Install JDK package"
    fi
    
    # Scheduling systems
    local has_cron=false
    local has_systemd=false
    
    if command -v "crontab" >/dev/null 2>&1; then
        has_cron=true
        log_validation "SUCCESS" "cron" "Available for scheduling"
    fi
    
    if systemctl --version >/dev/null 2>&1; then
        has_systemd=true
        log_validation "SUCCESS" "systemd" "Available for scheduling"
    fi
    
    if [ "$has_cron" = false ] && [ "$has_systemd" = false ]; then
        log_validation "ERROR" "scheduling" "Neither cron nor systemd available" "Install cron or ensure systemd is available"
        missing_deps=$((missing_deps + 1))
    fi
    
    return $missing_deps
}

validate_core_variables() {
    echo ""
    msg $info "Validating core TAK Server variables..."
    
    # Required core variables (minimal set)
    validate_required_variable "TAK_URI" "Domain name for TAK Server"
    if [ -n "${TAK_URI:-}" ]; then
        if validate_format_domain "$TAK_URI"; then
            log_validation "SUCCESS" "TAK_URI" "Valid domain format"
        else
            log_validation "ERROR" "TAK_URI" "Must be a domain name (FQDN), not an IP address" "Use a domain like 'tak.example.com'"
        fi
    fi
    
    validate_required_variable "TAK_ALIAS" "Reference name and release pathname"
    
    # Optional variables (will be auto-generated if not set)
    validate_optional_variable "TAK_DB_PASS" "Database password" "Auto-generated"
    validate_optional_variable "INSTALLER" "Installation type" "docker"
    validate_optional_variable "VERSION" "TAK release version" "latest"
    
    # Optional core variables
    validate_optional_variable "TAK_DB_ALIAS" "Database hostname/IP" "${TAK_URI:-}"
    validate_optional_variable "TAK_ADMIN" "TAK Web Admin username" "tak-admin"
    validate_optional_variable "TAK_COT_PORT" "TAK API Port" "8089"
    validate_optional_variable "DOCKER_SUBNET" "Docker subnet" "172.20.0.0/24"
}

validate_certificate_variables() {
    echo ""
    msg $info "Validating certificate variables..."
    
    # Optional certificate variables (will be auto-generated/defaulted)
    validate_optional_variable "CA_PASS" "CA certificate password" "Auto-generated"
    validate_optional_variable "CERT_PASS" "User certificate password" "Auto-generated"
    validate_optional_variable "ORGANIZATION" "Certificate organization name" "TAK Organization"
    validate_optional_variable "ORGANIZATIONAL_UNIT" "Certificate organizational unit" "Operations"
    validate_optional_variable "CITY" "Certificate city" "City"
    validate_optional_variable "STATE" "Certificate state/province" "ST"
    validate_optional_variable "COUNTRY" "Certificate country code" "US"
    validate_optional_variable "CLIENT_VALID_DAYS" "Client certificate validity days" "30"
}

validate_letsencrypt_variables() {
    echo ""
    msg $info "Validating LetsEncrypt variables..."
    
    validate_optional_variable "LETSENCRYPT" "Enable LetsEncrypt certificates" "false"
    
    if [ "${LETSENCRYPT:-}" = "true" ]; then
        # Required when LetsEncrypt is enabled
        validate_required_variable "LE_EMAIL" "LetsEncrypt registration email"
        if [ -n "${LE_EMAIL:-}" ]; then
            if validate_format_email "$LE_EMAIL"; then
                log_validation "SUCCESS" "LE_EMAIL" "Valid email format"
            else
                log_validation "ERROR" "LE_EMAIL" "Invalid email format" "export LE_EMAIL=\"admin@example.com\""
            fi
        fi
        
        validate_required_variable "LE_VALIDATOR" "LetsEncrypt validation method"
        if [ -n "${LE_VALIDATOR:-}" ]; then
            case "$LE_VALIDATOR" in
                "web"|"dns")
                    log_validation "SUCCESS" "LE_VALIDATOR" "Valid validation method"
                    ;;
                *)
                    log_validation "ERROR" "LE_VALIDATOR" "Must be 'web' or 'dns'" "export LE_VALIDATOR=\"web\""
                    ;;
            esac
        fi
        
        # Optional LetsEncrypt variables
        validate_optional_variable "LE_NOTIFICATION_EMAIL" "Renewal notification email"
        if [ -n "${LE_NOTIFICATION_EMAIL:-}" ]; then
            if validate_format_email "$LE_NOTIFICATION_EMAIL"; then
                log_validation "SUCCESS" "LE_NOTIFICATION_EMAIL" "Valid email format"
            else
                log_validation "WARNING" "LE_NOTIFICATION_EMAIL" "Invalid email format"
            fi
        fi
        
        validate_optional_variable "LE_WEBHOOK_URL" "Renewal notification webhook URL"
        if [ -n "${LE_WEBHOOK_URL:-}" ]; then
            if [[ "$LE_WEBHOOK_URL" =~ ^https?:// ]]; then
                log_validation "SUCCESS" "LE_WEBHOOK_URL" "Valid URL format"
            else
                log_validation "WARNING" "LE_WEBHOOK_URL" "Should start with http:// or https://"
            fi
        fi
    else
        log_validation "INFO" "LETSENCRYPT" "Disabled - skipping LetsEncrypt variable validation"
    fi
}

validate_download_variables() {
    echo ""
    msg $info "Validating download variables..."
    
    validate_optional_variable "TAK_DOWNLOAD_URL" "Automatic TAK Server download URL"
    
    if [ -n "${TAK_DOWNLOAD_URL:-}" ]; then
        if [[ "$TAK_DOWNLOAD_URL" =~ ^https://drive\.google\.com/ ]]; then
            log_validation "SUCCESS" "TAK_DOWNLOAD_URL" "Valid Google Drive URL format"
        else
            log_validation "WARNING" "TAK_DOWNLOAD_URL" "Should be a Google Drive URL" "Use format: https://drive.google.com/file/d/FILE_ID/view"
        fi
    fi
}

validate_network_connectivity() {
    echo ""
    msg $info "Checking network connectivity..."
    
    if [ "${LETSENCRYPT:-}" = "true" ]; then
        # Test LetsEncrypt API connectivity
        if curl -s --connect-timeout 5 https://acme-v02.api.letsencrypt.org/directory >/dev/null 2>&1; then
            log_validation "SUCCESS" "LetsEncrypt API" "Reachable"
        else
            log_validation "WARNING" "LetsEncrypt API" "Not reachable" "Check internet connectivity and firewall"
        fi
        
        # Test domain resolution
        if [ -n "${TAK_URI:-}" ]; then
            if nslookup "$TAK_URI" >/dev/null 2>&1 || host "$TAK_URI" >/dev/null 2>&1; then
                log_validation "SUCCESS" "DNS Resolution" "$TAK_URI resolves"
            else
                log_validation "WARNING" "DNS Resolution" "$TAK_URI does not resolve" "Verify domain is configured in DNS"
            fi
        fi
    fi
    
    if [ -n "${TAK_DOWNLOAD_URL:-}" ]; then
        # Test Google Drive connectivity
        if curl -s --connect-timeout 5 https://drive.google.com >/dev/null 2>&1; then
            log_validation "SUCCESS" "Google Drive" "Reachable"
        else
            log_validation "WARNING" "Google Drive" "Not reachable" "Check internet connectivity"
        fi
    fi
}

generate_validation_report() {
    local json_output="$1"
    
    if [ "$json_output" = "true" ]; then
        cat << EOF
{
  "timestamp": "$(date -Iseconds)",
  "hostname": "$(hostname)",
  "validation_summary": {
    "errors": $validation_errors,
    "warnings": $validation_warnings,
    "status": "$([ $validation_errors -eq 0 ] && echo "PASS" || echo "FAIL")"
  },
  "environment_variables": {
    "TAK_URI": "${TAK_URI:-}",
    "TAK_ALIAS": "${TAK_ALIAS:-}",
    "INSTALLER": "${INSTALLER:-}",
    "VERSION": "${VERSION:-}",
    "LETSENCRYPT": "${LETSENCRYPT:-false}",
    "LE_VALIDATOR": "${LE_VALIDATOR:-}",
    "TAK_DOWNLOAD_URL_SET": "$([ -n "${TAK_DOWNLOAD_URL:-}" ] && echo "true" || echo "false")"
  }
}
EOF
    else
        echo ""
        echo "================================"
        echo "Validation Summary"
        echo "================================"
        echo "Errors: $validation_errors"
        echo "Warnings: $validation_warnings"
        echo ""
        
        if [ $validation_errors -eq 0 ]; then
            msg $success "✓ Environment validation PASSED"
            echo ""
            echo "Ready to run automated setup:"
            echo "  bash scripts/automated-setup.sh"
        else
            msg $error "✗ Environment validation FAILED"
            echo ""
            echo "Please fix the errors above before running setup."
            echo "See AUTOMATION.md for detailed variable descriptions."
        fi
        
        if [ $validation_warnings -gt 0 ]; then
            echo ""
            msg $warn "Note: $validation_warnings warning(s) found - review recommendations above"
        fi
    fi
}

usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -j, --json              Output validation results in JSON format"
    echo "  -q, --quiet             Only show errors and warnings"
    echo "  -h, --help              Show this help"
    echo ""
    echo "Description:"
    echo "  Validates all environment variables required for automated TAK Server setup."
    echo "  See AUTOMATION.md for complete variable documentation."
    echo ""
    echo "Examples:"
    echo "  $0                      # Full validation with human-readable output"
    echo "  $0 -j                   # JSON output for automation"
    echo "  $0 -q                   # Quiet mode - errors and warnings only"
    echo ""
    echo "Exit codes:"
    echo "  0 - All validations passed"
    echo "  1 - Validation errors found"
    echo "  2 - Invalid arguments"
}

main() {
    local json_output=false
    local quiet_mode=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -j|--json)
                json_output=true
                shift
                ;;
            -q|--quiet)
                quiet_mode=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "Unknown argument: $1"
                usage
                exit 2
                ;;
        esac
    done
    
    if [ "$json_output" = false ] && [ "$quiet_mode" = false ]; then
        echo "TAK Server Environment Validation"
        echo "================================="
    fi
    
    # Run all validations
    validate_dependencies
    validate_core_variables
    validate_certificate_variables
    validate_letsencrypt_variables
    validate_download_variables
    
    if [ "$quiet_mode" = false ]; then
        validate_network_connectivity
    fi
    
    # Generate report
    generate_validation_report "$json_output"
    
    # Return appropriate exit code
    if [ $validation_errors -eq 0 ]; then
        exit 0
    else
        exit 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi