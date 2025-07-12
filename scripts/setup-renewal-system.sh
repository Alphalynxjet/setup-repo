#!/bin/bash

SCRIPT_PATH=$(realpath "$(dirname "${BASH_SOURCE[0]}")")
source ${SCRIPT_PATH}/inc/functions.sh

LOG_FILE="/var/log/tak-renewal-system.log"

log_message() {
    local level=$1
    local message=$2
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

check_system_capabilities() {
    local has_cron=false
    local has_systemd=false
    
    # Check for cron
    if command -v crontab >/dev/null 2>&1; then
        has_cron=true
        log_message "INFO" "Cron available"
    else
        log_message "WARN" "Cron not available"
    fi
    
    # Check for systemd
    if systemctl --version >/dev/null 2>&1; then
        has_systemd=true
        log_message "INFO" "Systemd available"
    else
        log_message "WARN" "Systemd not available"
    fi
    
    if [ "$has_cron" = false ] && [ "$has_systemd" = false ]; then
        log_message "ERROR" "Neither cron nor systemd available for scheduling"
        return 1
    fi
    
    echo "${has_cron},${has_systemd}"
    return 0
}

setup_cron_primary() {
    local config_file="$1"
    local schedule="${2:-"0 2 * * 0"}"
    
    log_message "INFO" "Setting up cron as primary renewal system"
    
    if ! bash "${SCRIPT_PATH}/setup-letsencrypt-cron.sh" "$config_file" setup "$schedule"; then
        log_message "ERROR" "Failed to setup cron renewal"
        return 1
    fi
    
    # Create marker file
    echo "primary" > /var/lib/tak-renewal-primary
    log_message "INFO" "Cron renewal system marked as primary"
    return 0
}

setup_systemd_fallback() {
    local config_file="$1"
    
    log_message "INFO" "Setting up systemd as fallback renewal system"
    
    if ! bash "${SCRIPT_PATH}/setup-letsencrypt-systemd.sh" "$config_file" setup; then
        log_message "ERROR" "Failed to setup systemd renewal"
        return 1
    fi
    
    # Disable systemd timer initially (fallback only)
    sudo systemctl stop letsencrypt-renewal.timer 2>/dev/null || true
    sudo systemctl disable letsencrypt-renewal.timer 2>/dev/null || true
    
    # Create marker file
    echo "fallback" > /var/lib/tak-renewal-fallback
    log_message "INFO" "Systemd renewal system marked as fallback"
    return 0
}

setup_systemd_primary() {
    local config_file="$1"
    
    log_message "INFO" "Setting up systemd as primary renewal system"
    
    if ! bash "${SCRIPT_PATH}/setup-letsencrypt-systemd.sh" "$config_file" setup; then
        log_message "ERROR" "Failed to setup systemd renewal"
        return 1
    fi
    
    # Create marker file
    echo "primary" > /var/lib/tak-renewal-primary
    log_message "INFO" "Systemd renewal system marked as primary"
    return 0
}

setup_cron_fallback() {
    local config_file="$1"
    local schedule="${2:-"0 3 * * 0"}"  # Different time for fallback
    
    log_message "INFO" "Setting up cron as fallback renewal system"
    
    if ! bash "${SCRIPT_PATH}/setup-letsencrypt-cron.sh" "$config_file" setup "$schedule"; then
        log_message "ERROR" "Failed to setup cron renewal"
        return 1
    fi
    
    # Disable cron job initially (fallback only)
    crontab -l 2>/dev/null | grep -v "certbot renew.*letsencrypt-renewal" | crontab -
    
    # Create marker file
    echo "fallback" > /var/lib/tak-renewal-fallback
    log_message "INFO" "Cron renewal system marked as fallback"
    return 0
}

create_failover_script() {
    local config_file="$1"
    
    cat > /usr/local/bin/tak-renewal-failover.sh << 'EOF'
#!/bin/bash

LOG_FILE="/var/log/tak-renewal-system.log"

log_message() {
    local level=$1
    local message=$2
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
}

check_primary_health() {
    local primary_type="$1"
    local config_file="$2"
    
    # Check if primary system is working
    case "$primary_type" in
        "cron")
            # Check if cron job exists and is scheduled
            if crontab -l 2>/dev/null | grep -q "certbot renew.*letsencrypt-renewal"; then
                # Check if cron service is running
                if systemctl is-active cron >/dev/null 2>&1 || service cron status >/dev/null 2>&1; then
                    return 0
                fi
            fi
            return 1
            ;;
        "systemd")
            # Check if systemd timer is active and enabled
            if systemctl is-active letsencrypt-renewal.timer >/dev/null 2>&1 && \
               systemctl is-enabled letsencrypt-renewal.timer >/dev/null 2>&1; then
                return 0
            fi
            return 1
            ;;
    esac
    return 1
}

activate_fallback() {
    local fallback_type="$1"
    local config_file="$2"
    
    log_message "WARN" "Activating fallback renewal system: $fallback_type"
    
    case "$fallback_type" in
        "cron")
            # Re-add cron job
            local renewal_script_path="${SCRIPT_PATH}/letsencrypt-renewal.sh"
            local cron_job="0 3 * * 0 /usr/bin/certbot renew --quiet --deploy-hook \"$renewal_script_path $config_file\" >> /var/log/letsencrypt-cron.log 2>&1"
            (crontab -l 2>/dev/null; echo "$cron_job") | crontab -
            log_message "INFO" "Cron fallback activated"
            ;;
        "systemd")
            sudo systemctl enable letsencrypt-renewal.timer
            sudo systemctl start letsencrypt-renewal.timer
            log_message "INFO" "Systemd fallback activated"
            ;;
    esac
    
    # Update marker files
    echo "primary" > /var/lib/tak-renewal-primary-$fallback_type
    echo "failed" > /var/lib/tak-renewal-failed-primary
}

main() {
    local config_file="${1:-/opt/tak/tak-tools/config.inc.sh}"
    
    # Determine current primary system
    local primary_type=""
    local fallback_type=""
    
    if [ -f "/var/lib/tak-renewal-primary" ]; then
        if crontab -l 2>/dev/null | grep -q "certbot renew.*letsencrypt-renewal"; then
            primary_type="cron"
            fallback_type="systemd"
        elif systemctl is-active letsencrypt-renewal.timer >/dev/null 2>&1; then
            primary_type="systemd"
            fallback_type="cron"
        fi
    fi
    
    if [ -z "$primary_type" ]; then
        log_message "ERROR" "No primary renewal system detected"
        exit 1
    fi
    
    # Check primary system health
    if ! check_primary_health "$primary_type" "$config_file"; then
        log_message "ERROR" "Primary renewal system ($primary_type) failed health check"
        activate_fallback "$fallback_type" "$config_file"
        
        # Send notification
        if [ -n "$LE_NOTIFICATION_EMAIL" ]; then
            echo "TAK Server renewal system failover: $primary_type -> $fallback_type on $(hostname)" | \
                mail -s "TAK Renewal System Failover" "$LE_NOTIFICATION_EMAIL" 2>/dev/null || true
        fi
    fi
}

main "$@"
EOF

    chmod +x /usr/local/bin/tak-renewal-failover.sh
    
    # Update the script with actual config file path
    sed -i "s|/path/to/letsencrypt-renewal.sh|${SCRIPT_PATH}/letsencrypt-renewal.sh|g" /usr/local/bin/tak-renewal-failover.sh
    
    log_message "INFO" "Failover script created at /usr/local/bin/tak-renewal-failover.sh"
}

setup_health_monitoring() {
    local config_file="$1"
    
    log_message "INFO" "Setting up renewal system health monitoring"
    
    # Create health check cron job (runs daily)
    local health_check_job="0 1 * * * /usr/local/bin/tak-renewal-failover.sh $config_file >> /var/log/tak-renewal-system.log 2>&1"
    
    # Add health check to crontab
    (crontab -l 2>/dev/null | grep -v "tak-renewal-failover"; echo "$health_check_job") | crontab -
    
    log_message "INFO" "Health monitoring cron job added"
}

setup_dual_system() {
    local config_file="$1"
    local primary_schedule="${2:-"0 2 * * 0"}"
    local fallback_schedule="${3:-"0 3 * * 0"}"
    
    conf "$config_file"
    
    if [ -z "$TAK_URI" ] || [ -z "$LETSENCRYPT" ] || [ "$LETSENCRYPT" != "true" ]; then
        log_message "ERROR" "LetsEncrypt not properly configured"
        exit 1
    fi
    
    log_message "INFO" "Setting up dual renewal system for domain: ${TAK_URI}"
    
    # Check system capabilities
    local capabilities
    capabilities=$(check_system_capabilities) || exit 1
    local has_cron=$(echo "$capabilities" | cut -d',' -f1)
    local has_systemd=$(echo "$capabilities" | cut -d',' -f2)
    
    sudo mkdir -p /var/lib
    
    if [ "$has_cron" = "true" ] && [ "$has_systemd" = "true" ]; then
        # Both available - cron primary, systemd fallback
        log_message "INFO" "Both cron and systemd available - setting up dual system"
        
        setup_cron_primary "$config_file" "$primary_schedule" || exit 1
        setup_systemd_fallback "$config_file" || exit 1
        
    elif [ "$has_cron" = "true" ]; then
        # Only cron available
        log_message "INFO" "Only cron available - setting up cron-only system"
        setup_cron_primary "$config_file" "$primary_schedule" || exit 1
        
    elif [ "$has_systemd" = "true" ]; then
        # Only systemd available
        log_message "INFO" "Only systemd available - setting up systemd-only system"
        setup_systemd_primary "$config_file" || exit 1
        
    else
        log_message "ERROR" "No scheduling system available"
        exit 1
    fi
    
    # Create failover script and health monitoring
    create_failover_script "$config_file"
    setup_health_monitoring "$config_file"
    
    log_message "INFO" "Dual renewal system setup completed"
}

remove_dual_system() {
    log_message "INFO" "Removing dual renewal system"
    
    # Remove cron jobs
    bash "${SCRIPT_PATH}/setup-letsencrypt-cron.sh" remove 2>/dev/null || true
    
    # Remove systemd components
    bash "${SCRIPT_PATH}/setup-letsencrypt-systemd.sh" remove 2>/dev/null || true
    
    # Remove health monitoring
    crontab -l 2>/dev/null | grep -v "tak-renewal-failover" | crontab - 2>/dev/null || true
    
    # Remove marker files
    sudo rm -f /var/lib/tak-renewal-primary /var/lib/tak-renewal-fallback
    sudo rm -f /var/lib/tak-renewal-primary-* /var/lib/tak-renewal-failed-primary
    
    # Remove failover script
    sudo rm -f /usr/local/bin/tak-renewal-failover.sh
    
    log_message "INFO" "Dual renewal system removed"
}

status_dual_system() {
    local config_file="$1"
    
    conf "$config_file"
    
    echo "TAK Server Renewal System Status"
    echo "================================"
    echo "Domain: ${TAK_URI:-Not configured}"
    echo "LetsEncrypt: ${LETSENCRYPT:-Not configured}"
    echo ""
    
    # Check primary system
    echo "Primary System:"
    if [ -f "/var/lib/tak-renewal-primary" ]; then
        if crontab -l 2>/dev/null | grep -q "certbot renew.*letsencrypt-renewal"; then
            echo "  Type: Cron"
            echo "  Status: $(crontab -l 2>/dev/null | grep "certbot renew.*letsencrypt-renewal" | wc -l) job(s) configured"
        elif systemctl is-active letsencrypt-renewal.timer >/dev/null 2>&1; then
            echo "  Type: Systemd"
            echo "  Status: $(systemctl is-active letsencrypt-renewal.timer)"
        else
            echo "  Type: Unknown"
            echo "  Status: Not detected"
        fi
    else
        echo "  Not configured"
    fi
    
    echo ""
    echo "Fallback System:"
    if [ -f "/var/lib/tak-renewal-fallback" ]; then
        echo "  Configured: Yes"
        echo "  Status: Standby"
    else
        echo "  Not configured"
    fi
    
    echo ""
    echo "Health Monitoring:"
    if crontab -l 2>/dev/null | grep -q "tak-renewal-failover"; then
        echo "  Enabled: Yes"
        echo "  Frequency: Daily"
    else
        echo "  Enabled: No"
    fi
    
    echo ""
    echo "Recent Logs:"
    if [ -f "$LOG_FILE" ]; then
        tail -5 "$LOG_FILE" 2>/dev/null || echo "  No recent activity"
    else
        echo "  No log file found"
    fi
}

usage() {
    echo "Usage: $0 [config_file] <command> [options]"
    echo ""
    echo "Commands:"
    echo "  setup [primary_schedule] [fallback_schedule]   Setup dual renewal system"
    echo "  remove                                         Remove dual renewal system"
    echo "  status                                         Show system status"
    echo ""
    echo "Default schedules:"
    echo "  Primary: 0 2 * * 0 (Sunday 2:00 AM)"
    echo "  Fallback: 0 3 * * 0 (Sunday 3:00 AM)"
    echo ""
    echo "Examples:"
    echo "  $0 setup                              # Setup with defaults"
    echo "  $0 /path/to/config setup              # Setup with specific config"
    echo "  $0 setup \"0 1 * * 0\" \"0 2 * * 0\"     # Custom schedules"
    echo "  $0 remove                             # Remove system"
    echo "  $0 status                             # Show status"
}

main() {
    local config_file=""
    local command=""
    
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
            setup_dual_system "$config_file" "$1" "$2"
            ;;
        "remove")
            remove_dual_system
            ;;
        "status")
            status_dual_system "$config_file"
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