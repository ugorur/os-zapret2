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
# Use `drill` (FreeBSD base) — `dig` is only present if bind-tools port
# is installed, which OPNsense doesn't ship by default.
DNS_RESULT=$(drill "${DOMAIN}" A 2>/dev/null | awk '
    /^;; ANSWER SECTION/ {in_ans=1; next}
    /^;;/ {in_ans=0}
    in_ans && $4=="A" {print $5}
')
[ -z "${DNS_RESULT}" ] && DNS_RESULT="(no answer — DNS may be blocked)"
echo "${DNS_RESULT}"

echo ""
echo "=== HTTPS Connection Test ==="
# %{ssl_version} is not exposed by FreeBSD's curl build, so we omit it.
# %{ssl_verify_result} is available and tells us whether the TLS chain
# validated (0 == OK, 20 == "unable to get local issuer cert" w/ -k, etc.)
curl -4 -sk --connect-timeout 5 --max-time 10 -o /dev/null \
    -w "HTTP Status: %{http_code}\nRemote IP: %{remote_ip}\nTLS Verify: %{ssl_verify_result}\nTime Connect: %{time_connect}s\nTime TLS: %{time_appconnect}s\nTime Total: %{time_total}s\n" \
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
