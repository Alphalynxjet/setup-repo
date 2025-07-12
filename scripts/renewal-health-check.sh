#!/bin/bash

SCRIPT_PATH=$(realpath "$(dirname "${BASH_SOURCE[0]}")")
source ${SCRIPT_PATH}/inc/functions.sh

LOG_FILE="/var/log/tak-renewal-health.log"

log_message() {
    local level=$1
    local message=$2
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

check_cron_system() {
    local config_file="$1"
    local status="UNKNOWN"
    local details=""
    local health_score=0
    
    # Check if cron service is running
    if systemctl is-active cron >/dev/null 2>&1 || service cron status >/dev/null 2>&1; then
        details="Cron service: RUNNING"
        health_score=$((health_score + 25))
    else
        details="Cron service: STOPPED"
        status="CRITICAL"
    fi
    
    # Check if cron jobs exist
    local cron_jobs=$(crontab -l 2>/dev/null | grep "certbot renew.*letsencrypt-renewal" | wc -l)
    if [ "$cron_jobs" -gt 0 ]; then
        details="$details, Jobs: $cron_jobs configured"
        health_score=$((health_score + 25))
    else
        details="$details, Jobs: NONE"
        status="CRITICAL"
    fi
    
    # Check last execution
    if [ -f "/var/log/letsencrypt-cron.log" ]; then
        local last_run=$(stat -c %Y /var/log/letsencrypt-cron.log 2>/dev/null || echo 0)
        local current_time=$(date +%s)
        local days_since=$((($current_time - $last_run) / 86400))
        
        if [ $days_since -lt 8 ]; then
            details="$details, Last run: ${days_since}d ago"
            health_score=$((health_score + 25))
        else
            details="$details, Last run: ${days_since}d ago (STALE)"
            status="WARNING"
        fi
    else
        details="$details, Last run: UNKNOWN"
    fi
    
    # Check renewal script accessibility
    if [ -x "${SCRIPT_PATH}/letsencrypt-renewal.sh" ]; then
        details="$details, Script: ACCESSIBLE"
        health_score=$((health_score + 25))
    else
        details="$details, Script: INACCESSIBLE"
        status="CRITICAL"
    fi
    
    # Determine overall status
    if [ "$status" = "UNKNOWN" ]; then
        if [ $health_score -ge 75 ]; then
            status="HEALTHY"
        elif [ $health_score -ge 50 ]; then
            status="WARNING"
        else
            status="CRITICAL"
        fi
    fi
    
    echo "$status,$health_score,$details"
}

check_systemd_system() {
    local config_file="$1"
    local status="UNKNOWN"
    local details=""
    local health_score=0
    
    # Check if systemd is available
    if ! systemctl --version >/dev/null 2>&1; then
        echo "UNAVAILABLE,0,Systemd not available"
        return
    fi
    
    # Check timer status
    if systemctl is-active letsencrypt-renewal.timer >/dev/null 2>&1; then
        details="Timer: ACTIVE"
        health_score=$((health_score + 25))
    else
        details="Timer: INACTIVE"
    fi
    
    # Check if timer is enabled
    if systemctl is-enabled letsencrypt-renewal.timer >/dev/null 2>&1; then
        details="$details, Enabled: YES"
        health_score=$((health_score + 25))
    else
        details="$details, Enabled: NO"
    fi
    
    # Check service status
    local service_status=$(systemctl show letsencrypt-renewal.service --property=ActiveState --value 2>/dev/null || echo "unknown")
    details="$details, Service: $service_status"
    
    if [ "$service_status" != "failed" ]; then
        health_score=$((health_score + 25))
    fi
    
    # Check next scheduled run
    local next_run=$(systemctl list-timers letsencrypt-renewal.timer --no-pager --no-legend 2>/dev/null | awk '{print $1}')
    if [ -n "$next_run" ] && [ "$next_run" != "n/a" ]; then
        details="$details, Next: $next_run"
        health_score=$((health_score + 25))
    else
        details="$details, Next: UNSCHEDULED"
    fi
    
    # Determine overall status
    if [ $health_score -ge 75 ]; then
        status="HEALTHY"
    elif [ $health_score -ge 50 ]; then
        status="WARNING"
    else
        status="CRITICAL"
    fi
    
    echo "$status,$health_score,$details"
}

check_certificate_status() {
    local config_file="$1"
    local status="UNKNOWN"
    local details=""
    local health_score=0
    
    conf "$config_file"
    
    if [ -z "$TAK_URI" ] || [ "$LETSENCRYPT" != "true" ]; then
        echo "DISABLED,0,LetsEncrypt not configured"
        return
    fi
    
    # Check if certificates exist
    if [ -d "/etc/letsencrypt/live/$TAK_URI" ]; then
        details="Certificates: EXIST"
        health_score=$((health_score + 25))
        
        # Check certificate expiration
        local cert_file="/etc/letsencrypt/live/$TAK_URI/cert.pem"
        if [ -f "$cert_file" ]; then
            local expiry_date=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
            if [ -n "$expiry_date" ]; then
                local expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || echo 0)
                local current_epoch=$(date +%s)
                local days_left=$(( ($expiry_epoch - $current_epoch) / 86400 ))
                
                details="$details, Expires: ${days_left}d"
                
                if [ $days_left -gt 30 ]; then
                    health_score=$((health_score + 50))
                elif [ $days_left -gt 14 ]; then
                    health_score=$((health_score + 25))
                    status="WARNING"
                elif [ $days_left -gt 0 ]; then
                    status="CRITICAL"
                else
                    status="CRITICAL"
                    details="$details (EXPIRED)"
                fi
            else
                details="$details, Expires: UNREADABLE"
            fi
        else
            details="$details, File: MISSING"
        fi
        
        # Check TAK integration
        local tak_cert="${RELEASE_PATH}/tak/certs/files/letsencrypt.pem"
        if [ -f "$tak_cert" ]; then
            details="$details, TAK: INTEGRATED"
            health_score=$((health_score + 25))
        else
            details="$details, TAK: NOT_INTEGRATED"
        fi
    else
        details="Certificates: MISSING"
        status="CRITICAL"
    fi
    
    # Determine overall status
    if [ "$status" = "UNKNOWN" ]; then
        if [ $health_score -ge 75 ]; then
            status="HEALTHY"
        elif [ $health_score -ge 50 ]; then
            status="WARNING"
        else
            status="CRITICAL"
        fi
    fi
    
    echo "$status,$health_score,$details"
}

check_renewal_logs() {
    local status="UNKNOWN"
    local details=""
    local health_score=0
    
    # Check renewal log existence and recent activity
    if [ -f "/var/log/letsencrypt-renewal.log" ]; then
        details="Log: EXISTS"
        health_score=$((health_score + 25))
        
        # Check for recent activity
        local last_activity=$(tail -1 /var/log/letsencrypt-renewal.log 2>/dev/null | grep -o '[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}' || echo "")
        if [ -n "$last_activity" ]; then
            local last_epoch=$(date -d "$last_activity" +%s 2>/dev/null || echo 0)
            local current_epoch=$(date +%s)
            local days_since=$((($current_epoch - $last_epoch) / 86400))
            
            details="$details, Last: ${days_since}d ago"
            
            if [ $days_since -lt 8 ]; then
                health_score=$((health_score + 25))
            fi
        fi
        
        # Check for errors
        local error_count=$(grep -c "ERROR" /var/log/letsencrypt-renewal.log 2>/dev/null || echo 0)
        local success_count=$(grep -c "SUCCESS" /var/log/letsencrypt-renewal.log 2>/dev/null || echo 0)
        
        details="$details, Errors: $error_count, Success: $success_count"
        
        if [ $error_count -eq 0 ] && [ $success_count -gt 0 ]; then
            health_score=$((health_score + 50))
        elif [ $error_count -gt 0 ] && [ $success_count -gt $error_count ]; then
            health_score=$((health_score + 25))
            status="WARNING"
        elif [ $error_count -gt 0 ]; then
            status="CRITICAL"
        fi
    else
        details="Log: MISSING"
    fi
    
    # Determine overall status
    if [ "$status" = "UNKNOWN" ]; then
        if [ $health_score -ge 75 ]; then
            status="HEALTHY"
        elif [ $health_score -ge 50 ]; then
            status="WARNING"
        else
            status="CRITICAL"
        fi
    fi
    
    echo "$status,$health_score,$details"
}

perform_health_check() {
    local config_file="$1"
    local json_output="$2"
    
    log_message "INFO" "Starting renewal system health check"
    
    # Collect health data
    local cron_health=$(check_cron_system "$config_file")
    local systemd_health=$(check_systemd_system "$config_file")
    local cert_health=$(check_certificate_status "$config_file")
    local log_health=$(check_renewal_logs)
    
    # Parse results
    local cron_status=$(echo "$cron_health" | cut -d',' -f1)
    local cron_score=$(echo "$cron_health" | cut -d',' -f2)
    local cron_details=$(echo "$cron_health" | cut -d',' -f3-)
    
    local systemd_status=$(echo "$systemd_health" | cut -d',' -f1)
    local systemd_score=$(echo "$systemd_health" | cut -d',' -f2)
    local systemd_details=$(echo "$systemd_health" | cut -d',' -f3-)
    
    local cert_status=$(echo "$cert_health" | cut -d',' -f1)
    local cert_score=$(echo "$cert_health" | cut -d',' -f2)
    local cert_details=$(echo "$cert_health" | cut -d',' -f3-)
    
    local log_status=$(echo "$log_health" | cut -d',' -f1)
    local log_score=$(echo "$log_health" | cut -d',' -f2)
    local log_details=$(echo "$log_health" | cut -d',' -f3-)
    
    # Calculate overall health
    local total_score=$((cron_score + systemd_score + cert_score + log_score))
    local max_score=400
    local health_percentage=$((total_score * 100 / max_score))
    
    local overall_status="HEALTHY"
    if [ $health_percentage -lt 60 ]; then
        overall_status="CRITICAL"
    elif [ $health_percentage -lt 80 ]; then
        overall_status="WARNING"
    fi
    
    # Check for any critical components
    if [ "$cert_status" = "CRITICAL" ]; then
        overall_status="CRITICAL"
    fi
    
    if [ "$json_output" = "true" ]; then
        # JSON output
        cat << EOF
{
  "timestamp": "$(date -Iseconds)",
  "hostname": "$(hostname)",
  "overall": {
    "status": "$overall_status",
    "health_percentage": $health_percentage,
    "score": "$total_score/$max_score"
  },
  "components": {
    "cron": {
      "status": "$cron_status",
      "score": $cron_score,
      "details": "$cron_details"
    },
    "systemd": {
      "status": "$systemd_status",
      "score": $systemd_score,
      "details": "$systemd_details"
    },
    "certificates": {
      "status": "$cert_status",
      "score": $cert_score,
      "details": "$cert_details"
    },
    "logs": {
      "status": "$log_status",
      "score": $log_score,
      "details": "$log_details"
    }
  }
}
EOF
    else
        # Human-readable output
        echo "TAK Server Renewal System Health Check"
        echo "======================================"
        echo "Overall Status: $overall_status ($health_percentage% healthy)"
        echo "Total Score: $total_score/$max_score"
        echo ""
        echo "Component Status:"
        printf "  %-12s: %-8s (%2d/100) - %s\n" "Cron" "$cron_status" "$cron_score" "$cron_details"
        printf "  %-12s: %-8s (%2d/100) - %s\n" "Systemd" "$systemd_status" "$systemd_score" "$systemd_details"
        printf "  %-12s: %-8s (%2d/100) - %s\n" "Certificates" "$cert_status" "$cert_score" "$cert_details"
        printf "  %-12s: %-8s (%2d/100) - %s\n" "Logs" "$log_status" "$log_score" "$log_details"
        
        if [ "$overall_status" != "HEALTHY" ]; then
            echo ""
            echo "Recommendations:"
            if [ "$cert_status" = "CRITICAL" ]; then
                echo "  - Certificate issues detected - run certificate renewal immediately"
            fi
            if [ "$cron_status" = "CRITICAL" ]; then
                echo "  - Cron system issues - check cron service and job configuration"
            fi
            if [ "$systemd_status" = "CRITICAL" ] && [ "$cron_status" = "CRITICAL" ]; then
                echo "  - Both renewal systems failing - manual intervention required"
            fi
            if [ "$log_status" = "CRITICAL" ]; then
                echo "  - Check renewal logs for errors: tail -f /var/log/letsencrypt-renewal.log"
            fi
        fi
    fi
    
    # Log the result
    log_message "INFO" "Health check completed: $overall_status ($health_percentage%)"
    
    # Return appropriate exit code
    case "$overall_status" in
        "HEALTHY") return 0 ;;
        "WARNING") return 1 ;;
        "CRITICAL") return 2 ;;
        *) return 3 ;;
    esac
}

usage() {
    echo "Usage: $0 [config_file] [options]"
    echo ""
    echo "Options:"
    echo "  -j, --json              Output in JSON format"
    echo "  -h, --help              Show this help"
    echo ""
    echo "Examples:"
    echo "  $0                      # Health check with default config"
    echo "  $0 -j                   # JSON output"
    echo "  $0 /path/to/config      # Use specific config file"
    echo ""
    echo "Exit codes:"
    echo "  0 - HEALTHY"
    echo "  1 - WARNING"
    echo "  2 - CRITICAL"
    echo "  3 - ERROR"
}

main() {
    local config_file=""
    local json_output=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
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
    
    perform_health_check "$config_file" "$json_output"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi