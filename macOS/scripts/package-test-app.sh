#!/bin/zsh
# Backward-compatible entry point. Use build-macos.command for the documented
# one-command build, signed app, verified ZIP, and generated-artifact cleanup.

SCRIPT_DIR="${0:A:h}"
exec "${SCRIPT_DIR}/build-macos.command" "$@"
