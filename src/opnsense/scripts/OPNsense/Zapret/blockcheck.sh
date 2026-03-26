#!/bin/sh

# blockcheck.sh — Wrapper for zapret2's blockcheck2.sh
# Usage: blockcheck.sh <domain>

ZAPRET_DIR="/usr/local/etc/zapret2"
BLOCKCHECK="${ZAPRET_DIR}/blockcheck2.sh"

DOMAIN="$1"

if [ -z "${DOMAIN}" ]; then
    echo '{"status": "error", "message": "No domain specified."}'
    exit 1
fi

# Validate domain format
echo "${DOMAIN}" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9\.\-]+[a-zA-Z]{2,}$'
if [ $? -ne 0 ]; then
    echo '{"status": "error", "message": "Invalid domain format."}'
    exit 1
fi

if [ ! -x "${BLOCKCHECK}" ]; then
    echo '{"status": "error", "message": "blockcheck2.sh not found. Run setup first."}'
    exit 1
fi

cd "${ZAPRET_DIR}"

# Run blockcheck with the specified domain
# Capture output with timeout (5 minutes max)
timeout 300 "${BLOCKCHECK}" --domain="${DOMAIN}" 2>&1

exit $?
