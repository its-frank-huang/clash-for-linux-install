#!/bin/bash
# shellcheck disable=SC1091
. script/common.sh >&/dev/null
. script/clashctl.sh >&/dev/null

_valid_env

clashoff >&/dev/null

systemctl disable "$BIN_KERNEL_NAME" >&/dev/null
rm -f "/etc/systemd/system/${BIN_KERNEL_NAME}.service"
systemctl daemon-reload

rm -rf "$CLASH_BASE_DIR"
_set_rc unset
_okcat '✨' 'Uninstalled, related configurations have been cleared'
# Variables and functions that are not exported will not be inherited
# Detect current shell type and execute corresponding shell
if [ -n "$ZSH_VERSION" ]; then
  exec zsh
else
  exec bash
fi
