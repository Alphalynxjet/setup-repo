#!/bin/bash

SCRIPT_PATH=$(realpath "$(dirname "${BASH_SOURCE[0]}")")
source ${SCRIPT_PATH}/inc/functions.sh

check_certificate() {
    local cert_path="$1"
    local cert_name="$2"
    local warn_days="${3:-30}"
    
    if [ ! -f "$cert_path" ]; then
        echo "  $cert_name: Certificate file not found"
        return 1
    fi
    
    local expiry_date=$(openssl x509 -enddate -noout -in "$cert_path" 2>/dev/null | cut -d= -f2)
    if [ -z "$expiry_date" ]; then
        echo "  $cert_name: Unable to read certificate expiration"
        return 1
    fi
    
    local expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null)
    local current_epoch=$(date +%s)
    local days_left=$(( ($expiry_epoch - $current_epoch) / 86400 ))
    
    local status="OK"
    local color="$success"
    
    if [ $days_left -lt 0 ]; then
        status="EXPIRED"
        color="$error"
    elif [ $days_left -lt $warn_days ]; then
        status="WARNING"
        color="$warn"
    fi
    
    printf "  %-20s: %s (%d days) - " "$cert_name" "$expiry_date" $days_left
    msg $color "$status"
    
    return $([ "$status" = "OK" ])
}

check_letsencrypt() {
    local domain="$1"
    local warn_days="${2:-30}"
    
    echo "LetsEncrypt Certificates for $domain:"
    
    local cert_dir="/etc/letsencrypt/live/$domain"
    if [ ! -d "$cert_dir" ]; then
        echo "  No LetsEncrypt certificates found for domain $domain"
        return 1
    fi
    
    local issues=0
    
    check_certificate "$cert_dir/cert.pem" "Certificate" $warn_days || ((issues++))
    check_certificate "$cert_dir/fullchain.pem" "Full Chain" $warn_days || ((issues++))
    
    return $issues
}

check_tak_certificates() {
    local config_file="$1"
    local warn_days="${2:-30}"
    
    conf "$config_file"
    
    if [ -z "$RELEASE_PATH" ] || [ ! -d "$RELEASE_PATH" ]; then
        echo "TAK release path not found or configured"
        return 1
    fi
    
    local cert_dir="${RELEASE_PATH}/tak/certs/files"
    if [ ! -d "$cert_dir" ]; then
        echo "TAK certificate directory not found: $cert_dir"
        return 1
    fi
    
    echo ""
    echo "TAK Server Certificates:"
    
    local issues=0
    
    if [ -f "$cert_dir/letsencrypt.pem" ]; then
        check_certificate "$cert_dir/letsencrypt.pem" "TAK LetsEncrypt" $warn_days || ((issues++))
    fi
    
    local ca_cert=$(find "$cert_dir" -name "*ca.pem" -o -name "*ca-crt.pem" | head -1)
    if [ -n "$ca_cert" ]; then
        check_certificate "$ca_cert" "TAK CA" $warn_days || ((issues++))
    fi
    
    local server_cert=$(find "$cert_dir" -name "*server*.pem" -o -name "*tak*.pem" | grep -v letsencrypt | head -1)
    if [ -n "$server_cert" ]; then
        check_certificate "$server_cert" "TAK Server" $warn_days || ((issues++))
    fi
    
    return $issues
}

generate_json_report() {
    local config_file="$1"
    local warn_days="${2:-30}"
    
    conf "$config_file"
    
    local timestamp=$(date -Iseconds)
    local hostname=$(hostname)
    
    echo "{"
    echo "  \"timestamp\": \"$timestamp\","
    echo "  \"hostname\": \"$hostname\","
    echo "  \"domain\": \"${TAK_URI:-unknown}\","
    echo "  \"certificates\": ["
    
    local first=true
    
    if [ -n "$TAK_URI" ] && [ -d "/etc/letsencrypt/live/$TAK_URI" ]; then
        local cert_file="/etc/letsencrypt/live/$TAK_URI/cert.pem"
        if [ -f "$cert_file" ]; then
            [ "$first" = false ] && echo ","
            local expiry_date=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
            local days_left=$(( ($(date -d "$expiry_date" +%s) - $(date +%s)) / 86400 ))
            local status="ok"
            [ $days_left -lt 0 ] && status="expired"
            [ $days_left -lt $warn_days ] && [ $days_left -ge 0 ] && status="warning"
            
            echo "    {"
            echo "      \"name\": \"letsencrypt\","
            echo "      \"path\": \"$cert_file\","
            echo "      \"expiry_date\": \"$expiry_date\","
            echo "      \"days_remaining\": $days_left,"
            echo "      \"status\": \"$status\""
            echo -n "    }"
            first=false
        fi
    fi
    
    if [ -n "$RELEASE_PATH" ] && [ -d "${RELEASE_PATH}/tak/certs/files" ]; then
        local cert_dir="${RELEASE_PATH}/tak/certs/files"
        
        if [ -f "$cert_dir/letsencrypt.pem" ]; then
            [ "$first" = false ] && echo ","
            local expiry_date=$(openssl x509 -enddate -noout -in "$cert_dir/letsencrypt.pem" 2>/dev/null | cut -d= -f2)
            local days_left=$(( ($(date -d "$expiry_date" +%s) - $(date +%s)) / 86400 ))
            local status="ok"
            [ $days_left -lt 0 ] && status="expired"
            [ $days_left -lt $warn_days ] && [ $days_left -ge 0 ] && status="warning"
            
            echo "    {"
            echo "      \"name\": \"tak_letsencrypt\","
            echo "      \"path\": \"$cert_dir/letsencrypt.pem\","
            echo "      \"expiry_date\": \"$expiry_date\","
            echo "      \"days_remaining\": $days_left,"
            echo "      \"status\": \"$status\""
            echo -n "    }"
            first=false
        fi
    fi
    
    echo ""
    echo "  ]"
    echo "}"
}

usage() {
    echo "Usage: $0 [config_file] [options]"
    echo ""
    echo "Options:"
    echo "  -w, --warn-days DAYS    Days before expiration to warn (default: 30)"
    echo "  -j, --json              Output in JSON format"
    echo "  -h, --help              Show this help"
    echo ""
    echo "Examples:"
    echo "  $0                      # Check all certificates with default settings"
    echo "  $0 -w 14                # Warn when certificates expire within 14 days"
    echo "  $0 -j                   # Output in JSON format"
    echo "  $0 /path/to/config -w 7 # Use specific config, warn at 7 days"
}

main() {
    local config_file=""
    local warn_days=30
    local json_output=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -w|--warn-days)
                warn_days="$2"
                shift 2
                ;;
            -j|--json)
                json_output=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -*)
                echo "Unknown option: $1"
                usage
                exit 1
                ;;
            *)
                if [ -z "$config_file" ] && [ -f "$1" ]; then
                    config_file="$1"
                else
                    echo "Unknown argument: $1"
                    usage
                    exit 1
                fi
                shift
                ;;
        esac
    done
    
    if [ "$json_output" = true ]; then
        generate_json_report "$config_file" $warn_days
        return
    fi
    
    conf "$config_file"
    
    echo "Certificate Expiration Check"
    echo "============================"
    echo "Warning threshold: $warn_days days"
    echo ""
    
    local total_issues=0
    
    if [ -n "$TAK_URI" ] && [ "$LETSENCRYPT" = "true" ]; then
        check_letsencrypt "$TAK_URI" $warn_days
        total_issues=$((total_issues + $?))
    else
        echo "LetsEncrypt not configured or disabled"
    fi
    
    check_tak_certificates "$config_file" $warn_days
    total_issues=$((total_issues + $?))
    
    echo ""
    if [ $total_issues -eq 0 ]; then
        msg $success "All certificates are OK"
    else
        msg $error "Found $total_issues certificate issues"
        
        echo ""
        echo "Recommendations:"
        echo "- For LetsEncrypt certificates: Run 'sudo certbot renew' or wait for automatic renewal"
        echo "- For TAK certificates: Regenerate certificates or import new LetsEncrypt certificates"
        echo "- Check renewal cron job: crontab -l | grep certbot"
    fi
    
    exit $total_issues
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi