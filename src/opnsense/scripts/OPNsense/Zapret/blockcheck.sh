#!/bin/sh

# blockcheck.sh — Non-interactive driver for upstream zapret2's blockcheck2.sh
#
# Runs blockcheck2 against a single domain, feeds its interactive prompts
# from stdin, captures the output, and returns the SUMMARY section as JSON.
# Used by the Diagnostics > Blockcheck page in the OPNsense GUI.
#
# Usage: blockcheck.sh <domain>
#
# Output (always JSON):
#   { "status": "ok",      "domain": "...", "summary": "<text>",
#     "winning": [...]  }
#   { "status": "error",   "message": "..." }

ZAPRET_DIR="/usr/local/etc/zapret2"
BLOCKCHECK="${ZAPRET_DIR}/blockcheck2.sh"
CONFIG="${ZAPRET_DIR}/zapret.conf"

# How long to let blockcheck run before aborting (seconds). Standard scan
# usually finishes in 1–3 minutes; we cap at 10 to be safe.
TIMEOUT=600

DOMAIN="$1"

emit_error() {
    /usr/local/bin/jq -nc --arg msg "$1" '{status:"error", message:$msg}'
}

# Argument validation
if [ -z "${DOMAIN}" ]; then
    emit_error "no domain specified"
    exit 1
fi
if ! echo "${DOMAIN}" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9.\-]+[a-zA-Z]{2,}$'; then
    emit_error "invalid domain format"
    exit 1
fi
if [ ! -x "${BLOCKCHECK}" ]; then
    emit_error "blockcheck2.sh not found — run setup.sh first"
    exit 1
fi
if [ ! -f "${CONFIG}" ]; then
    emit_error "zapret config not found — save plugin settings first"
    exit 1
fi

# Resolve WAN device from plugin config
. "${CONFIG}"
WAN_DEV=""
if [ -x /usr/local/bin/jq ]; then
    WAN_DEV=$(/usr/local/sbin/pluginctl -4 "${WAN_IF}" 2>/dev/null \
        | /usr/local/bin/jq -r --arg if "${WAN_IF}" '.[$if][0].device // empty')
fi
[ -z "${WAN_DEV}" ] && WAN_DEV="${WAN_IF}"

# blockcheck2 wants ipfw enabled to install its own divert rules. Save the
# previous state so we can restore after — we don't want to leave the user's
# kernel state changed.
PREV_IPFW=$(/sbin/sysctl -n net.inet.ip.fw.enable 2>/dev/null || echo 0)
PREV_IPFW6=$(/sbin/sysctl -n net.inet6.ip6.fw.enable 2>/dev/null || echo 0)
/sbin/kldstat -q -m ipdivert || /sbin/kldload ipdivert
/sbin/kldstat -q -m ipfw     || /sbin/kldload ipfw
/sbin/sysctl net.inet.ip.fw.enable=1   >/dev/null 2>&1
/sbin/sysctl net.inet6.ip6.fw.enable=1 >/dev/null 2>&1

LOG=$(mktemp /tmp/zapret-blockcheck.XXXXXX) || {
    emit_error "could not create temp log"
    exit 1
}

# Feed answers to blockcheck2's prompts:
#   "press enter to continue"  → blank line
#   "select test : 1/2"        → 2 (standard)
#   "specify domain(s)"        → ${DOMAIN}
#   "ip protocol version(s)"   → 4 (IPv4 only)
#   "check http (Y/N)"         → Y
#   "check https tls 1.2"      → Y
#   "check https tls 1.3"      → Y
#   "check http3 QUIC"         → N (skip — UDP, less relevant for SNI)
#   "REPEATS"                  → 1
#   "enable parallel scan"     → N
# Trailing blank lines absorb any further "(Y/N) ?" follow-up prompts that
# accept defaults.
INPUT=$(printf '\n2\n%s\n4\nY\nY\nY\nN\n1\nN\n\n\n\n\n\n\n\n\n\n\n' "${DOMAIN}")

cd "${ZAPRET_DIR}"
echo "${INPUT}" | env IFACE_WAN="${WAN_DEV}" /usr/bin/timeout ${TIMEOUT} \
    /bin/sh "${BLOCKCHECK}" >"${LOG}" 2>&1
EXIT=$?

# Restore ipfw enable state (don't leave the kernel changed)
/sbin/sysctl net.inet.ip.fw.enable=${PREV_IPFW}   >/dev/null 2>&1
/sbin/sysctl net.inet6.ip6.fw.enable=${PREV_IPFW6} >/dev/null 2>&1

# Parse SUMMARY section. blockcheck2 prints:
#   summary
#   -------
#   <strategy 1> : <result>
#   <strategy 2> : <result>
#   <strategy ...>
SUMMARY=$(awk '/^summary$/,0' "${LOG}" 2>/dev/null)
if [ -z "${SUMMARY}" ]; then
    /usr/local/bin/jq -nc \
        --arg msg "blockcheck did not produce a summary (exit=${EXIT})" \
        --rawfile log "${LOG}" \
        '{status:"error", message:$msg, log:$log[-2000:]}'
    rm -f "${LOG}"
    exit 1
fi

# Extract winning strategies — lines containing "OK" or "ipv4: ok".
WINNING=$(echo "${SUMMARY}" | grep -iE 'ok|works' | head -20)

/usr/local/bin/jq -nc \
    --arg domain "${DOMAIN}" \
    --arg summary "${SUMMARY}" \
    --arg winning "${WINNING}" \
    '{status:"ok", domain:$domain, summary:$summary, winning:($winning|split("\n"))}'

rm -f "${LOG}"
exit 0
