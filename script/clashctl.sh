#!/bin/bash
# shellcheck disable=SC2155

function _clash_on() {
    _get_kernel_port
    sudo systemctl start "$BIN_KERNEL_NAME" && _okcat '已开启代理环境' ||
        _failcat '启动失败: 执行 "clash status" 查看日志' || return 1

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
    _is_root || _failcat '当前 shell 未检测到代理变量，需执行 clash on 开启代理环境' && _clash_on
}

function _clash_off() {
    sudo systemctl stop "$BIN_KERNEL_NAME" && _okcat '已关闭代理环境' ||
        _failcat '关闭失败: 执行 "clash status" 查看日志' || return 1

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
    # 防止tun模式强制走代理获取不到真实公网ip
    _clash_off >&/dev/null
    _get_kernel_port
    # 公网ip
    # ifconfig.me
    local query_url='api64.ipify.org'
    local public_ip=$(curl -s --noproxy "*" --connect-timeout 2 $query_url)
    local public_address="http://${public_ip:-公网}:${UI_PORT}/ui"
    # 内网ip
    # ip route get 1.1.1.1 | grep -oP 'src \K\S+'
    local local_ip=$(hostname -I | awk '{print $1}')
    local local_address="http://${local_ip}:${UI_PORT}/ui"
    printf "\n"
    printf "╔═══════════════════════════════════════════════╗\n"
    printf "║                %s                  ║\n" "$(_okcat 'Web 控制台')"
    printf "║═══════════════════════════════════════════════║\n"
    printf "║                                               ║\n"
    printf "║     🔓 注意放行端口：%-5s                    ║\n" "$UI_PORT"
    printf "║     🏠 内网：%-31s  ║\n" "$local_address"
    printf "║     🌏 公网：%-31s  ║\n" "$public_address"
    printf "║     ☁️  公共：%-31s  ║\n" "$URL_CLASH_UI"
    printf "║                                               ║\n"
    printf "╚═══════════════════════════════════════════════╝\n"
    printf "\n"
    _clash_on >&/dev/null
}

_merge_config_restart() {
    _valid_config "$CLASH_CONFIG_MIXIN" || _error_quit "验证失败：请检查 Mixin 配置"
    sudo "$BIN_YQ" -n "load(\"$CLASH_CONFIG_RAW\") * load(\"$CLASH_CONFIG_MIXIN\")" | sudo tee "$CLASH_CONFIG_RUNTIME" >&/dev/null && _clash_restart
}

function _clash_secret() {
    case "$#" in
    0)
        _okcat "当前密钥：$(sudo "$BIN_YQ" '.secret // ""' "$CLASH_CONFIG_RUNTIME")"
        ;;
    1)
        sudo "$BIN_YQ" -i ".secret = \"$1\"" "$CLASH_CONFIG_MIXIN" || {
            _failcat "密钥更新失败，请重新输入"
            return 1
        }
        _merge_config_restart
        _okcat "密钥更新成功，已重启生效"
        ;;
    *)
        _failcat "密钥不要包含空格或使用引号包围"
        ;;
    esac
}

_tunstatus() {
    local tun_status=$(sudo "$BIN_YQ" '.tun.enable' "${CLASH_CONFIG_RUNTIME}")
    # shellcheck disable=SC2015
    [ "$tun_status" = 'true' ] && _okcat 'Tun 状态：启用' || _failcat 'Tun 状态：关闭'
}

_tunoff() {
    _tunstatus >/dev/null || return 0
    sudo "$BIN_YQ" -i '.tun.enable = false' "$CLASH_CONFIG_MIXIN"
    _merge_config_restart && _okcat "Tun 模式已关闭"
}

_tunon() {
    _tunstatus 2>/dev/null && return 0
    sudo "$BIN_YQ" -i '.tun.enable = true' "$CLASH_CONFIG_MIXIN"
    _merge_config_restart
    sleep 0.5s
    sudo journalctl -u "$BIN_KERNEL_NAME" --since "1 min ago" | grep -E -m1 'unsupported kernel version|Start TUN listening error' && {
        _tunoff >&/dev/null
        _error_quit '不支持的内核版本'
    }
    _okcat "Tun 模式已开启"
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
        sudo tail "${CLASH_UPDATE_LOG}" 2>/dev/null || _failcat "暂无更新日志"
        return 0
        ;;
    *)
        [ -n "$1" ] && url=$1
        ;;
    esac

    # 如果没有提供有效的订阅链接（url为空或者不是http开头），则使用默认配置文件
    [ "${url:0:4}" != "http" ] && {
        _failcat "没有提供有效的订阅链接：使用 ${CLASH_CONFIG_RAW} 进行更新..."
        url="file://$CLASH_CONFIG_RAW"
    }

    # 如果是自动更新模式，则设置定时任务
    [ "$is_auto" = true ] && {
        # 检测shell类型并设置对应的rc文件路径
        local rc_file="$BASH_RC_ROOT"
        sudo grep -qs 'clash update' "$CLASH_CRON_TAB" || echo "0 0 */2 * * . $rc_file;clash update $url" | sudo tee -a "$CLASH_CRON_TAB" >&/dev/null
        _okcat "定时任务设置成功" && return 0
    }

    _okcat '👌' "备份配置：$CLASH_CONFIG_RAW_BAK"
    sudo cat "$CLASH_CONFIG_RAW" | sudo tee "$CLASH_CONFIG_RAW_BAK" >&/dev/null

    _rollback() {
        _failcat '🍂' "$1"
        sudo cat "$CLASH_CONFIG_RAW_BAK" | sudo tee "$CLASH_CONFIG_RAW" >&/dev/null
        _failcat '❌' "[$(date +"%Y-%m-%d %H:%M:%S")] 订阅更新失败：$url" 2>&1 | sudo tee -a "${CLASH_UPDATE_LOG}" >&/dev/null
        _error_quit
    }

    _download_config "$CLASH_CONFIG_RAW" "$url" || _rollback "更新失败：已回滚配置"
    _valid_config "$CLASH_CONFIG_RAW" || _rollback "转换失败：已回滚配置，请检查日志：$BIN_SUBCONVERTER_LOG"

    _merge_config_restart && _okcat '🍃' '订阅更新成功'
    echo "$url" | sudo tee "$CLASH_CONFIG_URL" >&/dev/null
    _okcat '✅' "[$(date +"%Y-%m-%d %H:%M:%S")] 订阅更新成功：$url" | sudo tee -a "${CLASH_UPDATE_LOG}" >&/dev/null
}

function _clash_mixin() {
    case "$1" in
    -e)
        sudo vim "$CLASH_CONFIG_MIXIN" && {
            _merge_config_restart && _okcat "配置更新成功，已重启生效"
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
    clash                    命令一览,
    clash on                 开启代理,
    clash off                关闭代理,
    clash autostart [on|off] 管理服务自启,
    clash ui                 面板地址,
    clash status             内核状况,
    clash tun     [on|off]   Tun 模式,
    clash mixin   [-e|-r]    Mixin 配置,
    clash secret  [secret]   Web 密钥,
    clash update  [auto|log] 更新订阅,
EOF
    )"
}
