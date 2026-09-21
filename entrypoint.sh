#!/bin/bash
set -e

# Check if the first argument is bash (for bash mode)
if [ "$1" = "bash" ] || [ "$1" = "/bin/bash" ]; then
    exec "$@"
fi

# Launch Antigravity CLI (agy) when selected by codebox.sh
if [ "${CODEBOX_MODE:-opencode}" = "agy" ] && command -v agy >/dev/null 2>&1; then
    echo "---------------------------------------------------------------"
    echo "⏳ Initializing Antigravity CLI (agy), please wait..."
    echo "---------------------------------------------------------------"
    echo ""
    exec agy "$@"
fi

# Show loading message for OpenCode mode
echo "---------------------------------------------------------------"
echo "⏳ Initializing OpenCode, please wait..."
echo "---------------------------------------------------------------"
echo ""

# Execute opencode with all arguments
exec opencode "$@"
