#!/bin/bash

SCRIPT_PATH=$(realpath "$(dirname "${BASH_SOURCE[0]}")")
source ${SCRIPT_PATH}/inc/functions.sh

setup_cron() {
    local config_file="${1:-}"
    local cron_time="${2:-"0 2 * * 0"}"
    
    conf "$config_file"
    
    if [ -z "$TAK_URI" ] || [ -z "$LETSENCRYPT" ] || [ "$LETSENCRYPT" != "true" ]; then
        msg $error "LetsEncrypt not properly configured in config file"
        exit 1
    fi
    
    msg $info "Setting up LetsEncrypt automatic renewal for domain: ${TAK_URI}"
    
    local renewal_script="${SCRIPT_PATH}/letsencrypt-renewal.sh"
    local config_arg=""
    if [ -n "$config_file" ]; then
        config_arg=" $config_file"
    fi
    
    local cron_job="$cron_time /usr/bin/certbot renew --quiet --deploy-hook \"$renewal_script$config_arg\" >> /var/log/letsencrypt-cron.log 2>&1"
    
    msg $info "Adding cron job: $cron_job"
    
    if ! crontab -l 2>/dev/null | grep -q "certbot renew.*letsencrypt-renewal"; then
        (crontab -l 2>/dev/null; echo "$cron_job") | crontab -
        msg $success "LetsEncrypt auto-renewal cron job added successfully"
    else
        msg $warn "LetsEncrypt renewal cron job already exists, skipping"
    fi
    
    sudo mkdir -p /var/log
    sudo touch /var/log/letsencrypt-renewal.log /var/log/letsencrypt-cron.log
    sudo chmod 644 /var/log/letsencrypt-renewal.log /var/log/letsencrypt-cron.log
    
    msg $info "Cron job will run: $(echo "$cron_time" | awk '{
        if ($3 == "*" && $4 == "*" && $5 == "0") print "Every Sunday at " $2 ":" sprintf("%02d", $1)
        else if ($3 == "*" && $4 == "*") print "Every day at " $2 ":" sprintf("%02d", $1)
        else print "Custom schedule: " $0
    }')"
    
    msg $info "Logs will be written to:"
    msg $info "  - Renewal activity: /var/log/letsencrypt-renewal.log"
    msg $info "  - Cron execution: /var/log/letsencrypt-cron.log"
    
    msg $warn "\nTo test the renewal process manually, run:"
    msg $warn "  sudo certbot renew --dry-run --deploy-hook '$renewal_script$config_arg'"
}

remove_cron() {
    msg $info "Removing LetsEncrypt auto-renewal cron jobs"
    
    crontab -l 2>/dev/null | grep -v "certbot renew.*letsencrypt-renewal" | crontab -
    msg $success "LetsEncrypt auto-renewal cron jobs removed"
}

status_cron() {
    local config_file="${1:-}"
    
    conf "$config_file"
    
    msg $info "LetsEncrypt Auto-Renewal Status"
    echo "================================"
    
    if [ -n "$TAK_URI" ] && [ "$LETSENCRYPT" = "true" ]; then
        echo "Domain: $TAK_URI"
        echo "LetsEncrypt enabled: Yes"
    else
        echo "LetsEncrypt: Not configured or disabled"
        return 1
    fi
    
    local cron_jobs=$(crontab -l 2>/dev/null | grep "certbot renew.*letsencrypt-renewal" | wc -l)
    if [ "$cron_jobs" -gt 0 ]; then
        echo "Cron jobs configured: $cron_jobs"
        echo ""
        echo "Active cron jobs:"
        crontab -l 2>/dev/null | grep "certbot renew.*letsencrypt-renewal"
    else
        echo "Cron jobs configured: None"
    fi
    
    echo ""
    if [ -f "/var/log/letsencrypt-renewal.log" ]; then
        echo "Last renewal activity:"
        tail -5 /var/log/letsencrypt-renewal.log 2>/dev/null || echo "  No recent activity"
    else
        echo "No renewal log found"
    fi
    
    echo ""
    if [ -d "/etc/letsencrypt/live/${TAK_URI}" ]; then
        echo "Certificate status:"
        local cert_file="/etc/letsencrypt/live/${TAK_URI}/cert.pem"
        if [ -f "$cert_file" ]; then
            local expiry=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
            local days_left=$(( ($(date -d "$expiry" +%s) - $(date +%s)) / 86400 ))
            echo "  Expires: $expiry"
            echo "  Days remaining: $days_left"
            
            if [ "$days_left" -lt 30 ]; then
                echo "  Status: WARNING - Certificate expires soon!"
            elif [ "$days_left" -lt 0 ]; then
                echo "  Status: EXPIRED - Certificate has expired!"
            else
                echo "  Status: OK"
            fi
        else
            echo "  Status: Certificate file not found"
        fi
    else
        echo "Certificate directory not found: /etc/letsencrypt/live/${TAK_URI}"
    fi
}

usage() {
    echo "Usage: $0 [config_file] <command> [options]"
    echo ""
    echo "Commands:"
    echo "  setup [cron_schedule]   Setup automatic renewal (default: 0 2 * * 0 = Sunday 2:00 AM)"
    echo "  remove                  Remove automatic renewal"
    echo "  status                  Show renewal status"
    echo ""
    echo "Examples:"
    echo "  $0 setup                           # Setup with default schedule"
    echo "  $0 setup \"0 3 * * 1\"               # Setup for Monday 3:00 AM"
    echo "  $0 /path/to/config setup           # Setup with specific config file"
    echo "  $0 remove                          # Remove auto-renewal"
    echo "  $0 status                          # Show status"
    echo ""
    echo "Default cron schedule runs every Sunday at 2:00 AM"
}

main() {
    local config_file=""
    local command=""
    local schedule=""
    
    if [ $# -eq 0 ]; then
        usage
        exit 1
    fi
    
    if [ -f "$1" ]; then
        config_file="$1"
        shift
    fi
    
    command="$1"
    shift
    
    case "$command" in
        "setup")
            schedule="${1:-"0 2 * * 0"}"
            setup_cron "$config_file" "$schedule"
            ;;
        "remove")
            remove_cron
            ;;
        "status")
            status_cron "$config_file"
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi