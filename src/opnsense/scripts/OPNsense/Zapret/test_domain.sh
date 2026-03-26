#!/bin/sh

# test_domain.sh — Quick connectivity test for a domain
# Usage: test_domain.sh <domain>

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

echo "=== DNS Resolution ==="
dig +short "${DOMAIN}" 2>&1

echo ""
echo "=== HTTPS Connection Test ==="
curl -4 -sk --connect-timeout 10 --max-time 15 -o /dev/null \
    -w "HTTP Status: %{http_code}\nRemote IP: %{remote_ip}\nTLS Version: %{ssl_version}\nTime Connect: %{time_connect}s\nTime TLS: %{time_appconnect}s\nTime Total: %{time_total}s\n" \
    "https://${DOMAIN}/" 2>&1

RESULT=$?

echo ""
if [ ${RESULT} -eq 0 ]; then
    echo "=== Result: SUCCESS ==="
elif [ ${RESULT} -eq 35 ]; then
    echo "=== Result: TLS HANDSHAKE FAILED (likely SNI blocking) ==="
elif [ ${RESULT} -eq 56 ]; then
    echo "=== Result: CONNECTION RESET (likely DPI blocking) ==="
elif [ ${RESULT} -eq 28 ]; then
    echo "=== Result: TIMEOUT ==="
elif [ ${RESULT} -eq 6 ]; then
    echo "=== Result: DNS RESOLUTION FAILED ==="
elif [ ${RESULT} -eq 7 ]; then
    echo "=== Result: CONNECTION REFUSED ==="
else
    echo "=== Result: FAILED (curl exit code: ${RESULT}) ==="
fi

exit ${RESULT}
