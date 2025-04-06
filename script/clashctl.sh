#!/bin/bash
# shellcheck disable=SC2155

function _clash_on() {
    _get_kernel_port
    sudo systemctl start "$BIN_KERNEL_NAME" && _okcat 'Proxy environment enabled' ||
        _failcat 'Startup failed: Run "clash status" to view logs' || return 1

    local http_proxy_addr="http://127.0.0.1:${MIXED_PORT}"
    local socks_proxy_addr="socks5://127.0.0.1:${MIXED_PORT}"
    local no_proxy_addr="localhost,127.0.0.1,::1"

    export http_proxy=$http_proxy_addr
    export https_proxy=$http_proxy
    export HTTP_PROXY=$http_proxy
    export HTTPS_PROXY=$http_proxy

    export all_proxy=$socks_proxy_addr
    export ALL_PROXY=$all_proxy

    export no_proxy=$no_proxy_addr
    export NO_PROXY=$no_proxy
}

systemctl is-active "$BIN_KERNEL_NAME" >&/dev/null && [ -z "$http_proxy" ] && {
    _is_root || _failcat 'No proxy variables detected in current shell, run "clash on" to enable proxy environment' && _clash_on
}

function _clash_off() {
    sudo systemctl stop "$BIN_KERNEL_NAME" && _okcat 'Proxy environment disabled' ||
        _failcat 'Shutdown failed: Run "clash status" to view logs' || return 1

    unset http_proxy
    unset https_proxy
    unset HTTP_PROXY
    unset HTTPS_PROXY
    unset all_proxy
    unset ALL_PROXY
    unset no_proxy
    unset NO_PROXY
}

_clash_restart() {
    { _clash_off && _clash_on; } >&/dev/null
}

_clash_status() {
    sudo systemctl status "$BIN_KERNEL_NAME"
}

function _clash_ui() {
    # Prevent TUN mode from forcing proxy and not getting real public IP
    _clash_off >&/dev/null
    _get_kernel_port
    # Public IP
    # ifconfig.me
    local query_url='api64.ipify.org'
    local public_ip=$(curl -s --noproxy "*" --connect-timeout 2 $query_url)
    local public_address="http://${public_ip:-public}:${UI_PORT}/ui"
    # Local IP
    # ip route get 1.1.1.1 | grep -oP 'src \K\S+'
    local local_ip=$(hostname -I | awk '{print $1}')
    local local_address="http://${local_ip}:${UI_PORT}/ui"
    printf "\n"
    printf "╔═══════════════════════════════════════════════╗\n"
    printf "║                %s                  ║\n" "$(_okcat 'Web Console')"
    printf "║═══════════════════════════════════════════════║\n"
    printf "║                                               ║\n"
    printf "║     🔓 Open port: %-5s                   ║\n" "$UI_PORT"
    printf "║     🏠 Local: %-31s  ║\n" "$local_address"
    printf "║     🌏 Public: %-31s  ║\n" "$public_address"
    printf "║     ☁️  Cloud: %-31s  ║\n" "$URL_CLASH_UI"
    printf "║                                               ║\n"
    printf "╚═══════════════════════════════════════════════╝\n"
    printf "\n"
    _clash_on >&/dev/null
}

_merge_config_restart() {
    _valid_config "$CLASH_CONFIG_MIXIN" || _error_quit "Validation failed: Please check Mixin configuration"
    sudo "$BIN_YQ" -n "load(\"$CLASH_CONFIG_RAW\") * load(\"$CLASH_CONFIG_MIXIN\")" | sudo tee "$CLASH_CONFIG_RUNTIME" >&/dev/null && _clash_restart
}

function _clash_secret() {
    case "$#" in
    0)
        _okcat "Current secret: $(sudo "$BIN_YQ" '.secret // ""' "$CLASH_CONFIG_RUNTIME")"
        ;;
    1)
        sudo "$BIN_YQ" -i ".secret = \"$1\"" "$CLASH_CONFIG_MIXIN" || {
            _failcat "Secret update failed, please try again"
            return 1
        }
        _merge_config_restart
        _okcat "Secret updated successfully, restarted to take effect"
        ;;
    *)
        _failcat "Secret should not contain spaces or be surrounded by quotes"
        ;;
    esac
}

_tunstatus() {
    local tun_status=$(sudo "$BIN_YQ" '.tun.enable' "${CLASH_CONFIG_RUNTIME}")
    # shellcheck disable=SC2015
    [ "$tun_status" = 'true' ] && _okcat 'Tun status: Enabled' || _failcat 'Tun status: Disabled'
}

_tunoff() {
    _tunstatus >/dev/null || return 0
    sudo "$BIN_YQ" -i '.tun.enable = false' "$CLASH_CONFIG_MIXIN"
    _merge_config_restart && _okcat "Tun mode disabled"
}

_tunon() {
    _tunstatus 2>/dev/null && return 0
    sudo "$BIN_YQ" -i '.tun.enable = true' "$CLASH_CONFIG_MIXIN"
    _merge_config_restart
    sleep 0.5s
    sudo journalctl -u "$BIN_KERNEL_NAME" --since "1 min ago" | grep -E -m1 'unsupported kernel version|Start TUN listening error' && {
        _tunoff >&/dev/null
        _error_quit 'Unsupported kernel version'
    }
    _okcat "Tun mode enabled"
}

function _clash_tun() {
    case "$1" in
    on)
        _tunon
        ;;
    off)
        _tunoff
        ;;
    *)
        _tunstatus
        ;;
    esac
}

function _clash_update() {
    local url=$(cat "$CLASH_CONFIG_URL")
    local is_auto

    case "$1" in
    auto)
        is_auto=true
        [ -n "$2" ] && url=$2
        ;;
    log)
        sudo tail "${CLASH_UPDATE_LOG}" 2>/dev/null || _failcat "No update logs available yet"
        return 0
        ;;
    *)
        [ -n "$1" ] && url=$1
        ;;
    esac

    # If no valid subscription link is provided (url is empty or doesn't start with http), use default config file
    [ "${url:0:4}" != "http" ] && {
        _failcat "No valid subscription link provided: Using ${CLASH_CONFIG_RAW} for update..."
        url="file://$CLASH_CONFIG_RAW"
    }

    # If in auto update mode, set up a scheduled task
    [ "$is_auto" = true ] && {
        # Detect shell type and set corresponding rc file path
        local rc_file="$BASH_RC_ROOT"
        sudo grep -qs 'clash update' "$CLASH_CRON_TAB" || echo "0 0 */2 * * . $rc_file;clash update $url" | sudo tee -a "$CLASH_CRON_TAB" >&/dev/null
        _okcat "Scheduled task set successfully" && return 0
    }

    _okcat '👌' "Backing up configuration: $CLASH_CONFIG_RAW_BAK"
    sudo cat "$CLASH_CONFIG_RAW" | sudo tee "$CLASH_CONFIG_RAW_BAK" >&/dev/null

    _rollback() {
        _failcat '🍂' "$1"
        sudo cat "$CLASH_CONFIG_RAW_BAK" | sudo tee "$CLASH_CONFIG_RAW" >&/dev/null
        _failcat '❌' "[$(date +"%Y-%m-%d %H:%M:%S")] Subscription update failed: $url" 2>&1 | sudo tee -a "${CLASH_UPDATE_LOG}" >&/dev/null
        _error_quit
    }

    _download_config "$CLASH_CONFIG_RAW" "$url" || _rollback "Update failed: Configuration rolled back"
    _valid_config "$CLASH_CONFIG_RAW" || _rollback "Conversion failed: Configuration rolled back, check log: $BIN_SUBCONVERTER_LOG"

    _merge_config_restart && _okcat '🍃' 'Subscription updated successfully'
    echo "$url" | sudo tee "$CLASH_CONFIG_URL" >&/dev/null
    _okcat '✅' "[$(date +"%Y-%m-%d %H:%M:%S")] Subscription updated successfully: $url" | sudo tee -a "${CLASH_UPDATE_LOG}" >&/dev/null
}

function _clash_mixin() {
    case "$1" in
    -e)
        sudo vim "$CLASH_CONFIG_MIXIN" && {
            _merge_config_restart && _okcat "Configuration updated successfully, restarted to take effect"
        }
        ;;
    -r)
        less "$CLASH_CONFIG_RUNTIME"
        ;;
    *)
        less "$CLASH_CONFIG_MIXIN"
        ;;
    esac
}

# Function to manage systemd service autostart
function _clash_autostart() {
    # Check current status if no argument or invalid argument is given
    if [ -z "$1" ] || [[ "$1" != "on" && "$1" != "off" ]]; then
        if systemctl is-enabled "$BIN_KERNEL_NAME" --quiet; then
            _okcat '✅' "Autostart is currently ENABLED for $BIN_KERNEL_NAME."
        else
            # Check if the service exists but is disabled, or doesn't exist
            if systemctl list-unit-files | grep -q "^${BIN_KERNEL_NAME}.service"; then
                _okcat '❌' "Autostart is currently DISABLED for $BIN_KERNEL_NAME."
            else
                _failcat '❓' "Service $BIN_KERNEL_NAME not found or not installed correctly."
            fi
        fi
        _okcat 'ℹ️' "Usage: clash autostart [on|off]"
        return 0
    fi

    if [ "$1" = "on" ]; then
        _okcat '⏳' "Enabling autostart for $BIN_KERNEL_NAME..."
        if sudo systemctl enable "$BIN_KERNEL_NAME"; then
            _okcat '🚀' "Autostart enabled for $BIN_KERNEL_NAME."
        else
            _failcat '💥' "Failed to enable autostart for $BIN_KERNEL_NAME. Check permissions or service status."
            return 1
        fi
    elif [ "$1" = "off" ]; then
        _okcat '⏳' "Disabling autostart for $BIN_KERNEL_NAME..."
        if sudo systemctl disable "$BIN_KERNEL_NAME"; then
            _okcat '🛑' "Autostart disabled for $BIN_KERNEL_NAME."
        else
            _failcat '💥' "Failed to disable autostart for $BIN_KERNEL_NAME. Check permissions or service status."
            return 1
        fi
    fi
}

function clash() {
    case "$1" in
    on)
        _clash_on
        return
        ;;
    off)
        _clash_off
        return
        ;;
    ui)
        _clash_ui
        return
        ;;
    status)
        _clash_status "$2"
        return
        ;;
    tun)
        _clash_tun "$2"
        return
        ;;
    mixin)
        _clash_mixin "$2"
        return
        ;;
    secret)
        _clash_secret "$2"
        return
        ;;
    update)
        _clash_update "$2" "$3"
        return
        ;;
    autostart)
        _clash_autostart "$2"
        return
        ;;
    esac

    local color=#c8d6e5
    local prefix=$(_get_color "$color")
    local suffix=$(printf '\033[0m')
    printf "%b\n" "$(
        cat <<EOF | column -t -s ',' | sed -E "/clash/ s|(clash)(\w*)|\1${prefix}\2${suffix}|g"
Usage:
    clash                    Command overview,
    clash on                 Enable proxy,
    clash off                Disable proxy,
    clash autostart [on|off] Manage service autostart,
    clash ui                 Panel address,
    clash status             Kernel status,
    clash tun     [on|off]   Tun mode,
    clash mixin   [-e|-r]    Mixin configuration,
    clash secret  [secret]   Web secret key,
    clash update  [auto|log] Update subscription,
EOF
    )"
}
