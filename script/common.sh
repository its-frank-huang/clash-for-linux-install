#!/bin/bash
# shellcheck disable=SC2034
# shellcheck disable=SC2155
[ -n "$BASH_VERSION" ] && set +o noglob
[ -n "$ZSH_VERSION" ] && setopt glob

URL_GH_PROXY='https://gh-proxy.com/'
URL_CLASH_UI="http://board.zash.run.place"

SCRIPT_BASE_DIR='./script'

RESOURCES_BASE_DIR='./resources'
RESOURCES_BIN_DIR="${RESOURCES_BASE_DIR}/bin"
RESOURCES_CONFIG="${RESOURCES_BASE_DIR}/config.yaml"
RESOURCES_CONFIG_MIXIN="${RESOURCES_BASE_DIR}/mixin.yaml"

ZIP_BASE_DIR="${RESOURCES_BASE_DIR}/zip"
ZIP_CLASH="${ZIP_BASE_DIR}/clash*.gz"
ZIP_MIHOMO="${ZIP_BASE_DIR}/mihomo*.gz"
ZIP_YQ="${ZIP_BASE_DIR}/yq*.tar.gz"
ZIP_SUBCONVERTER="${ZIP_BASE_DIR}/subconverter*.tar.gz"
ZIP_UI="${ZIP_BASE_DIR}/yacd.tar.xz"

CLASH_BASE_DIR='/opt/clash'
CLASH_SCRIPT_DIR="${CLASH_BASE_DIR}/$(basename $SCRIPT_BASE_DIR)"
CLASH_CONFIG_URL="${CLASH_BASE_DIR}/url"
CLASH_CONFIG_RAW="${CLASH_BASE_DIR}/$(basename $RESOURCES_CONFIG)"
CLASH_CONFIG_RAW_BAK="${CLASH_CONFIG_RAW}.bak"
CLASH_CONFIG_MIXIN="${CLASH_BASE_DIR}/$(basename $RESOURCES_CONFIG_MIXIN)"
CLASH_CONFIG_RUNTIME="${CLASH_BASE_DIR}/runtime.yaml"
CLASH_UPDATE_LOG="${CLASH_BASE_DIR}/clashupdate.log"

_set_var() {
    # Scheduled task path
    {
        local os_info=$(cat /etc/os-release)
        echo "$os_info" | grep -iqsE "rhel|centos" && {
            CLASH_CRON_TAB="/var/spool/cron/root"
        }
        echo "$os_info" | grep -iqsE "debian|ubuntu" && {
            CLASH_CRON_TAB="/var/spool/cron/crontabs/root"
        }
    }
    # rc file path
    {
        local home=$HOME
        [ -n "$SUDO_USER" ] && home=$(awk -F: -v user="$SUDO_USER" '$1==user{print $6}' /etc/passwd)

        # Detect shell type and set corresponding rc file
        if [ -n "$ZSH_VERSION" ]; then
            BASH_RC_ROOT='/root/.zshrc'
            BASH_RC_USER="${home}/.zshrc"
        else
            BASH_RC_ROOT='/root/.bashrc'
            BASH_RC_USER="${home}/.bashrc"
        fi
    }
}
_set_var

# shellcheck disable=SC2120
_set_bin() {
    local bin_base_dir="${CLASH_BASE_DIR}/bin"
    [ -n "$1" ] && bin_base_dir=$1
    BIN_CLASH="${bin_base_dir}/clash"
    BIN_MIHOMO="${bin_base_dir}/mihomo"
    BIN_YQ="${bin_base_dir}/yq"
    BIN_SUBCONVERTER_DIR="${bin_base_dir}/subconverter"
    BIN_SUBCONVERTER_CONFIG="$BIN_SUBCONVERTER_DIR/pref.yml"
    BIN_SUBCONVERTER_PORT="25500"
    BIN_SUBCONVERTER="${BIN_SUBCONVERTER_DIR}/subconverter"
    BIN_SUBCONVERTER_LOG="${BIN_SUBCONVERTER_DIR}/latest.log"

    [ -f "$BIN_MIHOMO" ] && {
        BIN_KERNEL=$BIN_MIHOMO
    }
    [ -f "$BIN_CLASH" ] && {
        BIN_KERNEL=$BIN_CLASH
    }
    BIN_KERNEL_NAME=$(basename "$BIN_KERNEL")
}
_set_bin

# shellcheck disable=SC2086
_set_rc() {
    [ "$BASH_RC_ROOT" = "$BASH_RC_USER" ] && unset BASH_RC_USER

    [ "$1" = "unset" ] && {
        sed -i "\|$CLASH_SCRIPT_DIR|d" $BASH_RC_ROOT $BASH_RC_USER
        return
    }

    [ -n "$(tail -n 1 "$BASH_RC_ROOT")" ] && echo >>"$BASH_RC_ROOT"
    [ -n "$(tail -n 1 "$BASH_RC_USER" >&/dev/null)" ] && echo >>"$BASH_RC_USER"

    echo "source $CLASH_SCRIPT_DIR/common.sh && source $CLASH_SCRIPT_DIR/clashctl.sh" |
        tee -a $BASH_RC_ROOT $BASH_RC_USER >&/dev/null
}

# Default integration, install mihomo kernel
# Remove/delete mihomo: download and install clash kernel
# shellcheck disable=SC2086
function _get_kernel() {
    [ -f $ZIP_CLASH ] && {
        ZIP_KERNEL=$ZIP_CLASH
        BIN_KERNEL=$BIN_CLASH
    }

    [ -f $ZIP_MIHOMO ] && {
        ZIP_KERNEL=$ZIP_MIHOMO
        BIN_KERNEL=$BIN_MIHOMO
    }

    [ ! -f $ZIP_MIHOMO ] && [ ! -f $ZIP_CLASH ] && {
        local arch=$(uname -m)
        _failcat "${ZIP_BASE_DIR}: No available kernel package detected"
        _download_clash "$arch"
        ZIP_KERNEL=$ZIP_CLASH
        BIN_KERNEL=$BIN_CLASH
    }

    BIN_KERNEL_NAME=$(basename "$BIN_KERNEL")
    _okcat "Installing kernel: $BIN_KERNEL_NAME"
}

_get_random_port() {
    local randomPort=$((RANDOM % 64512 + 1024))
    ! _is_bind "$randomPort" && { echo "$randomPort" && return; }
    _get_random_port
}

function _get_kernel_port() {
    local mixed_port=$(sudo "$BIN_YQ" '.mixed-port // ""' $CLASH_CONFIG_RUNTIME)
    local ext_addr=$(sudo "$BIN_YQ" '.external-controller // ""' $CLASH_CONFIG_RUNTIME)
    local ext_port=${ext_addr##*:}

    MIXED_PORT=${mixed_port:-7890}
    UI_PORT=${ext_port:-9090}

    # Port occupation scenario
    local port
    for port in $MIXED_PORT $UI_PORT; do
        _is_already_in_use "$port" "$BIN_KERNEL_NAME" && {
            [ "$port" = "$MIXED_PORT" ] && {
                local newPort=$(_get_random_port)
                local msg="Port occupied: ${MIXED_PORT} 🎲 Random assignment: $newPort"
                sudo "$BIN_YQ" -i ".mixed-port = $newPort" $CLASH_CONFIG_RUNTIME
                MIXED_PORT=$newPort
                _failcat '🎯' "$msg"
                continue
            }
            [ "$port" = "$UI_PORT" ] && {
                newPort=$(_get_random_port)
                msg="Port occupied: ${UI_PORT} 🎲 Random assignment: $newPort"
                sudo "$BIN_YQ" -i ".external-controller = \"0.0.0.0:$newPort\"" $CLASH_CONFIG_RUNTIME
                UI_PORT=$newPort
                _failcat '🎯' "$msg"
            }
        }
    done
}

function _get_color() {
    local hex="${1#\#}"
    local r=$((16#${hex:0:2}))
    local g=$((16#${hex:2:2}))
    local b=$((16#${hex:4:2}))
    printf "\e[38;2;%d;%d;%dm" "$r" "$g" "$b"
}
_get_color_msg() {
    local color=$(_get_color "$1")
    local msg=$2
    local reset="\033[0m"
    printf "%b%s%b\n" "$color" "$msg" "$reset"
}

function _okcat() {
    local color=#c8d6e5
    local emoji=😼
    [ $# -gt 1 ] && emoji=$1 && shift
    local msg="${emoji} $1"
    _get_color_msg "$color" "$msg" && return 0
}

function _failcat() {
    local color=#fd79a8
    local emoji=😾
    [ $# -gt 1 ] && emoji=$1 && shift
    local msg="${emoji} $1"
    _get_color_msg "$color" "$msg" >&2 && return 1
}

function _error_quit() {
    [ $# -gt 0 ] && {
        local color=#f92f60
        local emoji=📢
        [ $# -gt 1 ] && emoji=$1 && shift
        local msg="${emoji} $1"
        _get_color_msg "$color" "$msg"
    }
    exec $SHELL
}

_is_bind() {
    local port=$1
    { sudo ss -tulnp || sudo netstat -tulnp; } | grep ":${port}\b"
}

_is_already_in_use() {
    local port=$1
    local progress=$2
    _is_bind "$port" | grep -qs -v "$progress"
}

function _is_root() {
    [ "$(whoami)" = "root" ]
}

function _valid_env() {
    _is_root || _error_quit "Root or sudo privileges required"
    # Detect current shell
    if [ -n "$BASH_VERSION" ] || [ -n "$ZSH_VERSION" ]; then
        : # No operation, condition satisfied
    else
        _error_quit "Current terminal is not bash or zsh"
    fi
    [ "$(ps -p 1 -o comm=)" != "systemd" ] && _error_quit "System does not have systemd"
}

function _valid_config() {
    [ -e "$1" ] && [ "$(wc -l <"$1")" -gt 1 ] && {
        local test_cmd="$BIN_KERNEL -d $(dirname "$1") -f $1 -t"
        local fail_msg
        fail_msg=$($test_cmd) || {
            $test_cmd
            echo "$fail_msg" | grep -qs "unsupport proxy type" && _error_quit "Unsupported proxy protocol, please install mihomo kernel"
        }
    }
}

_download_clash() {
    local arch=$1
    local url sha256sum
    case "$arch" in
    x86_64)
        url=https://downloads.clash.wiki/ClashPremium/clash-linux-amd64-2023.08.17.gz
        sha256sum='92380f053f083e3794c1681583be013a57b160292d1d9e1056e7fa1c2d948747'
        ;;
    *86*)
        url=https://downloads.clash.wiki/ClashPremium/clash-linux-386-2023.08.17.gz
        sha256sum='254125efa731ade3c1bf7cfd83ae09a824e1361592ccd7c0cccd2a266dcb92b5'
        ;;
    armv*)
        url=https://downloads.clash.wiki/ClashPremium/clash-linux-armv5-2023.08.17.gz
        sha256sum='622f5e774847782b6d54066f0716114a088f143f9bdd37edf3394ae8253062e8'
        ;;
    aarch64)
        url=https://downloads.clash.wiki/ClashPremium/clash-linux-arm64-2023.08.17.gz
        sha256sum='c45b39bb241e270ae5f4498e2af75cecc0f03c9db3c0db5e55c8c4919f01afdd'
        ;;
    *)
        _error_quit "Unknown architecture version: $arch, please download the corresponding version to ${ZIP_BASE_DIR} directory: https://downloads.clash.wiki/ClashPremium/"
        ;;
    esac

    _okcat '⏳' "Downloading: clash: ${arch} architecture..."
    local clash_zip="${ZIP_BASE_DIR}/$(basename $url)"
    curl \
        --progress-bar \
        --show-error \
        --fail \
        --insecure \
        --connect-timeout 15 \
        --retry 1 \
        --output "$clash_zip" \
        "$url"
    echo $sha256sum "$clash_zip" | sha256sum -c ||
        _error_quit "Download failed: Please download the corresponding version to ${ZIP_BASE_DIR} directory: https://downloads.clash.wiki/ClashPremium/"
}

function _download_config() {
    _download_raw_config() {
        local dest=$1
        local url=$2
        local agent='Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:130.0) Gecko/20100101 Firefox/130.0'
        sudo curl \
            --silent \
            --show-error \
            --insecure \
            --connect-timeout 4 \
            --retry 1 \
            --user-agent "$agent" \
            --output "$dest" \
            "$url" ||
            sudo wget \
                --no-verbose \
                --no-check-certificate \
                --timeout 3 \
                --tries 1 \
                --user-agent "$agent" \
                --output-document "$dest" \
                "$url"
    }
    _download_convert_config() {
        local dest=$1
        local url=$2
        _start_convert
        local convert_url=$(
            target='clash'
            base_url="http://127.0.0.1:${BIN_SUBCONVERTER_PORT}/sub"
            curl \
                --get \
                --silent \
                --output /dev/null \
                --data-urlencode "target=$target" \
                --data-urlencode "url=$url" \
                --write-out '%{url_effective}' \
                "$base_url"
        )
        _download_raw_config "$dest" "$convert_url"
        _stop_convert
    }
    local dest=$1
    local url=$2
    [ "${url:0:4}" = 'file' ] && return 0
    _download_raw_config "$dest" "$url" || return 1
    _okcat '🍃' 'Download successful: Kernel validating configuration...'
    _valid_config "$dest" || {
        _failcat '🍂' "Validation failed: Attempting subscription conversion..."
        _download_convert_config "$dest" "$url" || _failcat '🍂' "Conversion failed: Please check log: $BIN_SUBCONVERTER_LOG"
    }
}

_start_convert() {
    _is_already_in_use $BIN_SUBCONVERTER_PORT 'subconverter' && {
        local newPort=$(_get_random_port)
        _failcat '🎯' "Port occupied: $BIN_SUBCONVERTER_PORT 🎲 Random assignment: $newPort"
        [ ! -e "$BIN_SUBCONVERTER_CONFIG" ] && {
            sudo /bin/mv -f "$BIN_SUBCONVERTER_DIR/pref.example.yml" "$BIN_SUBCONVERTER_CONFIG"
        }
        sudo "$BIN_YQ" -i ".server.port = $newPort" "$BIN_SUBCONVERTER_CONFIG"
        BIN_SUBCONVERTER_PORT=$newPort
    }
    local start=$(date +%s)
    # Run in subshell to suppress kill output
    (sudo "$BIN_SUBCONVERTER" 2>&1 | sudo tee "$BIN_SUBCONVERTER_LOG" >/dev/null &)
    while ! _is_bind "$BIN_SUBCONVERTER_PORT" >&/dev/null; do
        sleep 0.05s
        local now=$(date +%s)
        [ $((now - start)) -gt 1 ] && _error_quit "Subscription conversion service not started, please check log: $BIN_SUBCONVERTER_LOG"
    done
}
_stop_convert() {
    pkill -9 -f "$BIN_SUBCONVERTER" >&/dev/null
}
