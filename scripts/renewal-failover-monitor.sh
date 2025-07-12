#!/bin/bash

SCRIPT_PATH=$(realpath "$(dirname "${BASH_SOURCE[0]}")")
source ${SCRIPT_PATH}/inc/functions.sh

LOG_FILE="/var/log/tak-renewal-failover.log"

log_message() {
    local level=$1
    local message=$2
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

get_primary_system() {
    # Determine current primary system based on active configuration
    if crontab -l 2>/dev/null | grep -q "certbot renew.*letsencrypt-renewal" && \
       (systemctl is-active cron >/dev/null 2>&1 || service cron status >/dev/null 2>&1); then
        echo "cron"
    elif systemctl is-active letsencrypt-renewal.timer >/dev/null 2>&1 && \
         systemctl is-enabled letsencrypt-renewal.timer >/dev/null 2>&1; then
        echo "systemd"
    else
        echo "none"
    fi
}

check_cron_health() {
    local issues=0
    
    # Check cron service
    if ! (systemctl is-active cron >/dev/null 2>&1 || service cron status >/dev/null 2>&1); then
        log_message "ERROR" "Cron service is not running"
        issues=$((issues + 1))
    fi
    
    # Check cron job exists
    if ! crontab -l 2>/dev/null | grep -q "certbot renew.*letsencrypt-renewal"; then
        log_message "ERROR" "LetsEncrypt cron job not found"
        issues=$((issues + 1))
    fi
    
    # Check recent execution
    if [ -f "/var/log/letsencrypt-cron.log" ]; then
        local last_run=$(stat -c %Y /var/log/letsencrypt-cron.log 2>/dev/null || echo 0)
        local current_time=$(date +%s)
        local days_since=$((($current_time - $last_run) / 86400))
        
        if [ $days_since -gt 14 ]; then
            log_message "WARN" "Cron last executed ${days_since} days ago (may be stale)"
            issues=$((issues + 1))
        fi
    fi
    
    return $issues
}

check_systemd_health() {
    local issues=0
    
    # Check if systemd is available
    if ! systemctl --version >/dev/null 2>&1; then
        log_message "ERROR" "Systemd not available"
        return 10  # High number to indicate unavailable
    fi
    
    # Check timer status
    if ! systemctl is-active letsencrypt-renewal.timer >/dev/null 2>&1; then
        log_message "ERROR" "Systemd timer is not active"
        issues=$((issues + 1))
    fi
    
    # Check if timer is enabled
    if ! systemctl is-enabled letsencrypt-renewal.timer >/dev/null 2>&1; then
        log_message "ERROR" "Systemd timer is not enabled"
        issues=$((issues + 1))
    fi
    
    # Check service health
    local service_status=$(systemctl show letsencrypt-renewal.service --property=ActiveState --value 2>/dev/null || echo "unknown")
    if [ "$service_status" = "failed" ]; then
        log_message "ERROR" "Systemd service is in failed state"
        issues=$((issues + 1))
    fi
    
    return $issues
}

activate_fallback_system() {
    local current_primary="$1"
    local config_file="$2"
    
    log_message "WARN" "Primary system ($current_primary) failed, activating fallback"
    
    case "$current_primary" in
        "cron")
            # Switch to systemd
            log_message "INFO" "Switching from cron to systemd"
            
            # Disable cron job
            crontab -l 2>/dev/null | grep -v "certbot renew.*letsencrypt-renewal" | crontab - 2>/dev/null || true
            
            # Enable systemd
            if systemctl --version >/dev/null 2>&1; then
                sudo systemctl enable letsencrypt-renewal.timer
                sudo systemctl start letsencrypt-renewal.timer
                log_message "INFO" "Systemd timer activated as primary"
                echo "systemd" > /var/lib/tak-renewal-primary 2>/dev/null || true
            else
                log_message "ERROR" "Cannot switch to systemd - not available"
                return 1
            fi
            ;;
            
        "systemd")
            # Switch to cron
            log_message "INFO" "Switching from systemd to cron"
            
            # Disable systemd
            sudo systemctl stop letsencrypt-renewal.timer 2>/dev/null || true
            sudo systemctl disable letsencrypt-renewal.timer 2>/dev/null || true
            
            # Enable cron
            if command -v crontab >/dev/null 2>&1; then
                local renewal_script="${SCRIPT_PATH}/letsencrypt-renewal.sh"
                local config_arg=""
                if [ -n "$config_file" ]; then
                    config_arg=" $config_file"
                fi
                
                local cron_job="0 2 * * 0 /usr/bin/certbot renew --quiet --deploy-hook \"$renewal_script$config_arg\" >> /var/log/letsencrypt-cron.log 2>&1"
                (crontab -l 2>/dev/null; echo "$cron_job") | crontab -
                log_message "INFO" "Cron job activated as primary"
                echo "cron" > /var/lib/tak-renewal-primary 2>/dev/null || true
            else
                log_message "ERROR" "Cannot switch to cron - not available"
                return 1
            fi
            ;;
            
        *)
            log_message "ERROR" "Unknown primary system: $current_primary"
            return 1
            ;;
    esac
    
    # Record failover event
    echo "$(date -Iseconds): $current_primary -> $(get_primary_system)" >> /var/lib/tak-renewal-failover-history 2>/dev/null || true
    
    return 0
}

send_failover_notification() {
    local old_system="$1"
    local new_system="$2"
    local config_file="$3"
    
    conf "$config_file"
    
    local message="TAK Server LetsEncrypt renewal system failover on $(hostname):
- Previous system: $old_system (FAILED)
- New system: $new_system (ACTIVE)
- Domain: ${TAK_URI:-unknown}
- Time: $(date)
- Check logs: tail -f /var/log/tak-renewal-failover.log"
    
    # Email notification
    if [ -n "$LE_NOTIFICATION_EMAIL" ] && command -v mail >/dev/null 2>&1; then
        echo "$message" | mail -s "TAK Renewal System Failover: $old_system -> $new_system" "$LE_NOTIFICATION_EMAIL" 2>/dev/null || true
    fi
    
    # Webhook notification
    if [ -n "$LE_WEBHOOK_URL" ] && command -v curl >/dev/null 2>&1; then
        curl -X POST "$LE_WEBHOOK_URL" \
             -H "Content-Type: application/json" \
             -d "{
                 \"status\":\"FAILOVER\",
                 \"message\":\"Renewal system failover: $old_system -> $new_system\",
                 \"hostname\":\"$(hostname)\",
                 \"domain\":\"${TAK_URI:-unknown}\",
                 \"old_system\":\"$old_system\",
                 \"new_system\":\"$new_system\",
                 \"timestamp\":\"$(date -Iseconds)\"
             }" \
             >/dev/null 2>&1 || true
    fi
    
    log_message "INFO" "Failover notifications sent"
}

perform_failover_check() {
    local config_file="$1"
    local force_check="$2"
    
    log_message "INFO" "Starting failover monitoring check"
    
    local current_primary=$(get_primary_system)
    
    if [ "$current_primary" = "none" ]; then
        log_message "ERROR" "No active renewal system detected"
        
        # Try to activate any available system
        if systemctl --version >/dev/null 2>&1; then
            log_message "INFO" "Attempting to activate systemd as emergency primary"
            bash "${SCRIPT_PATH}/setup-letsencrypt-systemd.sh" "$config_file" setup 2>/dev/null || true
        elif command -v crontab >/dev/null 2>&1; then
            log_message "INFO" "Attempting to activate cron as emergency primary"
            bash "${SCRIPT_PATH}/setup-letsencrypt-cron.sh" "$config_file" setup 2>/dev/null || true
        else
            log_message "CRITICAL" "No renewal systems available - manual intervention required"
        fi
        return 1
    fi
    
    log_message "INFO" "Current primary system: $current_primary"
    
    local health_issues=0
    local requires_failover=false
    
    case "$current_primary" in
        "cron")
            check_cron_health
            health_issues=$?
            if [ $health_issues -gt 2 ] || [ "$force_check" = "true" ]; then
                requires_failover=true
            fi
            ;;
        "systemd")
            check_systemd_health
            health_issues=$?
            if [ $health_issues -gt 2 ] || [ "$force_check" = "true" ]; then
                requires_failover=true
            fi
            ;;
    esac
    
    if [ "$requires_failover" = "true" ]; then
        log_message "WARN" "Primary system health check failed (issues: $health_issues), initiating failover"
        
        local old_system="$current_primary"
        if activate_fallback_system "$current_primary" "$config_file"; then
            local new_system=$(get_primary_system)
            log_message "INFO" "Failover successful: $old_system -> $new_system"
            send_failover_notification "$old_system" "$new_system" "$config_file"
        else
            log_message "CRITICAL" "Failover failed - manual intervention required"
            return 1
        fi
    else
        log_message "INFO" "Primary system health check passed (issues: $health_issues)"
    fi
    
    return 0
}

show_failover_status() {
    local config_file="$1"
    
    conf "$config_file"
    
    echo "TAK Server Renewal Failover Status"
    echo "=================================="
    echo "Domain: ${TAK_URI:-Not configured}"
    echo "Current primary: $(get_primary_system)"
    echo ""
    
    echo "System Health:"
    echo "  Cron:"
    if check_cron_health >/dev/null 2>&1; then
        echo "    Status: HEALTHY"
    else
        echo "    Status: UNHEALTHY"
    fi
    
    echo "  Systemd:"
    if check_systemd_health >/dev/null 2>&1; then
        echo "    Status: HEALTHY"
    else
        echo "    Status: UNHEALTHY"
    fi
    
    echo ""
    echo "Failover History:"
    if [ -f "/var/lib/tak-renewal-failover-history" ]; then
        tail -5 /var/lib/tak-renewal-failover-history 2>/dev/null || echo "  No failover events recorded"
    else
        echo "  No failover history file found"
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
    echo "  check [--force]     Perform failover health check"
    echo "  status              Show failover system status"
    echo "  force-failover      Force immediate failover"
    echo ""
    echo "Options:"
    echo "  --force             Force failover regardless of health status"
    echo ""
    echo "Examples:"
    echo "  $0 check                          # Normal health check"
    echo "  $0 check --force                  # Force failover"
    echo "  $0 /path/to/config status         # Show status with config"
    echo "  $0 force-failover                 # Emergency failover"
}

main() {
    local config_file=""
    local command=""
    local force_check=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --force)
                force_check=true
                shift
                ;;
            -*)
                echo "Unknown option: $1"
                usage
                exit 1
                ;;
            *)
                if [ -z "$config_file" ] && [ -f "$1" ]; then
                    config_file="$1"
                elif [ -z "$command" ]; then
                    command="$1"
                else
                    echo "Unknown argument: $1"
                    usage
                    exit 1
                fi
                shift
                ;;
        esac
    done
    
    # Default command
    if [ -z "$command" ]; then
        command="check"
    fi
    
    case "$command" in
        "check")
            perform_failover_check "$config_file" "$force_check"
            ;;
        "status")
            show_failover_status "$config_file"
            ;;
        "force-failover")
            perform_failover_check "$config_file" "true"
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