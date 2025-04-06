#!/bin/bash
# shellcheck disable=SC1091
. script/common.sh
. script/clashctl.sh

# Modify _valid_env function call to allow running in zsh
_valid_env

[ -d "$CLASH_BASE_DIR" ] && _error_quit "Please run the uninstall script first to clear the installation path: $CLASH_BASE_DIR"

_get_kernel
# shellcheck disable=SC2086
{
    /bin/install -D <(gzip -dc $ZIP_KERNEL) "${RESOURCES_BIN_DIR}/$BIN_KERNEL_NAME"
    tar -xf $ZIP_SUBCONVERTER -C "$RESOURCES_BIN_DIR"
    tar -xf $ZIP_YQ -C "${RESOURCES_BIN_DIR}"
    /bin/mv -f ${RESOURCES_BIN_DIR}/yq_* ${RESOURCES_BIN_DIR}/yq
}

_set_bin "$RESOURCES_BIN_DIR"
_valid_config "$RESOURCES_CONFIG" || {
    prompt=$(_okcat '✈️ ' 'Enter subscription link:')
    read -p "$prompt" -r url
    _okcat '⏳' 'Downloading...'
    _download_config "$RESOURCES_CONFIG" "$url" || _error_quit "Download failed: Please write configuration content to $RESOURCES_CONFIG and reinstall"
    _valid_config "$RESOURCES_CONFIG" || _error_quit "Invalid configuration, please check: $RESOURCES_CONFIG"
}
_okcat '✅' 'Configuration available'
mkdir "$CLASH_BASE_DIR"
echo "$url" >"$CLASH_CONFIG_URL"

/bin/cp -rf "$SCRIPT_BASE_DIR" "$CLASH_BASE_DIR"
/bin/ls "$RESOURCES_BASE_DIR" | grep -Ev 'zip|png' | xargs -I {} /bin/cp -rf "${RESOURCES_BASE_DIR}/{}" "$CLASH_BASE_DIR"
tar -xf "$ZIP_UI" -C "$CLASH_BASE_DIR"

_set_rc
_set_bin
_merge_config_restart
cat <<EOF >"/etc/systemd/system/${BIN_KERNEL_NAME}.service"
[Unit]
Description=$BIN_KERNEL_NAME Daemon, A[nother] Clash Kernel.

[Service]
Type=simple
Restart=always
ExecStart=${BIN_KERNEL} -d ${CLASH_BASE_DIR} -f ${CLASH_CONFIG_RUNTIME}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
# Ask the user about enabling auto-start
read -p "$(_okcat '⚙️ ' 'Enable automatic startup on login? (y/N): ')" -n 1 -r enable_auto_start
echo # Move to a new line after user input

# Conditionally enable the service based on user input
if [[ "$enable_auto_start" =~ ^[Yy]$ ]]; then
    systemctl enable "$BIN_KERNEL_NAME" >&/dev/null || _failcat '💥' "Failed to set auto-start" && _okcat '🚀' "Auto-start has been set"
else
    _okcat 'ℹ️' "Auto-start not set. You can enable it manually later: sudo systemctl enable $BIN_KERNEL_NAME"
fi

source /opt/clash/script/common.sh && source /opt/clash/script/clashctl.sh
clash on && _okcat '🎉' 'enjoy 🎉'
clash ui
clash
