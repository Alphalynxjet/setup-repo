#!/bin/bash

SCRIPT_PATH=$(realpath "$(dirname "${BASH_SOURCE[0]}")")
source ${SCRIPT_PATH}/inc/functions.sh

setup_systemd() {
    local config_file="${1:-}"
    
    conf "$config_file"
    
    if [ -z "$TAK_URI" ] || [ -z "$LETSENCRYPT" ] || [ "$LETSENCRYPT" != "true" ]; then
        msg $error "LetsEncrypt not properly configured in config file"
        exit 1
    fi
    
    if ! systemctl --version >/dev/null 2>&1; then
        msg $error "systemd not available on this system"
        exit 1
    fi
    
    local renewal_script="${SCRIPT_PATH}/letsencrypt-renewal.sh"
    local config_arg=""
    if [ -n "$config_file" ]; then
        config_arg=" $config_file"
    fi
    
    msg $info "Setting up LetsEncrypt automatic renewal via systemd for domain: ${TAK_URI}"
    
    local service_file="/etc/systemd/system/letsencrypt-renewal.service"
    local timer_file="/etc/systemd/system/letsencrypt-renewal.timer"
    
    msg $info "Creating systemd service file: $service_file"
    sudo sed "s|__RENEWAL_SCRIPT__|$renewal_script$config_arg|g" \
        "${SCRIPT_PATH}/systemd/letsencrypt-renewal.service" > /tmp/letsencrypt-renewal.service
    sudo mv /tmp/letsencrypt-renewal.service "$service_file"
    
    msg $info "Creating systemd timer file: $timer_file"
    sudo cp "${SCRIPT_PATH}/systemd/letsencrypt-renewal.timer" "$timer_file"
    
    sudo systemctl daemon-reload
    
    if sudo systemctl enable letsencrypt-renewal.timer; then
        msg $success "LetsEncrypt renewal timer enabled"
    else
        msg $error "Failed to enable LetsEncrypt renewal timer"
        exit 1
    fi
    
    if sudo systemctl start letsencrypt-renewal.timer; then
        msg $success "LetsEncrypt renewal timer started"
    else
        msg $error "Failed to start LetsEncrypt renewal timer"
        exit 1
    fi
    
    msg $info "Systemd timer configured to run weekly"
    msg $info "Logs will be available via: journalctl -u letsencrypt-renewal.service"
    
    msg $warn "\nTo test the renewal process manually, run:"
    msg $warn "  sudo systemctl start letsencrypt-renewal.service"
    msg $warn "  sudo journalctl -u letsencrypt-renewal.service -f"
}

remove_systemd() {
    msg $info "Removing LetsEncrypt systemd timer and service"
    
    if systemctl is-active --quiet letsencrypt-renewal.timer; then
        sudo systemctl stop letsencrypt-renewal.timer
    fi
    
    if systemctl is-enabled --quiet letsencrypt-renewal.timer; then
        sudo systemctl disable letsencrypt-renewal.timer
    fi
    
    sudo rm -f /etc/systemd/system/letsencrypt-renewal.service
    sudo rm -f /etc/systemd/system/letsencrypt-renewal.timer
    
    sudo systemctl daemon-reload
    sudo systemctl reset-failed
    
    msg $success "LetsEncrypt systemd components removed"
}

status_systemd() {
    local config_file="${1:-}"
    
    conf "$config_file"
    
    msg $info "LetsEncrypt Systemd Timer Status"
    echo "================================="
    
    if [ -n "$TAK_URI" ] && [ "$LETSENCRYPT" = "true" ]; then
        echo "Domain: $TAK_URI"
        echo "LetsEncrypt enabled: Yes"
    else
        echo "LetsEncrypt: Not configured or disabled"
        return 1
    fi
    
    echo ""
    if systemctl list-unit-files | grep -q "letsencrypt-renewal.timer"; then
        echo "Timer status:"
        systemctl status letsencrypt-renewal.timer --no-pager
        
        echo ""
        echo "Service status:"
        systemctl status letsencrypt-renewal.service --no-pager
        
        echo ""
        echo "Next scheduled run:"
        systemctl list-timers letsencrypt-renewal.timer --no-pager
        
        echo ""
        echo "Recent logs:"
        journalctl -u letsencrypt-renewal.service --no-pager -n 10
    else
        echo "Systemd timer not configured"
    fi
}

usage() {
    echo "Usage: $0 [config_file] <command>"
    echo ""
    echo "Commands:"
    echo "  setup                   Setup systemd timer for automatic renewal"
    echo "  remove                  Remove systemd timer"
    echo "  status                  Show timer status"
    echo ""
    echo "Examples:"
    echo "  $0 setup                           # Setup with default config"
    echo "  $0 /path/to/config setup           # Setup with specific config file"
    echo "  $0 remove                          # Remove systemd timer"
    echo "  $0 status                          # Show status"
    echo ""
    echo "The systemd timer runs weekly with a random delay up to 1 hour"
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
    
    case "$command" in
        "setup")
            setup_systemd "$config_file"
            ;;
        "remove")
            remove_systemd
            ;;
        "status")
            status_systemd "$config_file"
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