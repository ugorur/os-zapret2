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

# blockcheck2 refuses to run reliably while another DPI bypass is active.
# Stop zapret if it's running — we'll restart it on exit if it was.
WAS_RUNNING=0
if [ -f /var/run/dvtws2.pid ] && kill -0 "$(cat /var/run/dvtws2.pid)" 2>/dev/null; then
    WAS_RUNNING=1
    /usr/local/sbin/configctl zapret stop >/dev/null 2>&1
    sleep 2
fi

# blockcheck2 wants ipfw enabled to install its own divert rules. Save the
# previous state so we can restore after.
PREV_IPFW=$(/sbin/sysctl -n net.inet.ip.fw.enable 2>/dev/null || echo 0)
PREV_IPFW6=$(/sbin/sysctl -n net.inet6.ip6.fw.enable 2>/dev/null || echo 0)
/sbin/kldstat -q -m ipdivert || /sbin/kldload ipdivert
/sbin/kldstat -q -m ipfw     || /sbin/kldload ipfw
/sbin/sysctl net.inet.ip.fw.enable=1   >/dev/null 2>&1
/sbin/sysctl net.inet6.ip6.fw.enable=1 >/dev/null 2>&1

LOG=$(mktemp /tmp/zapret-blockcheck.XXXXXX) || {
    emit_error "could not create temp log"
    [ "${WAS_RUNNING}" = "1" ] && /usr/local/sbin/configctl zapret start >/dev/null 2>&1
    exit 1
}

# blockcheck2 has a BATCH=1 env mode that suppresses every interactive
# prompt; combined with DOMAINS/IPVS/ENABLE_*/REPEATS/PARALLEL/SCANLEVEL
# vars, the whole flow is fully non-interactive (no stdin piping needed).
cd "${ZAPRET_DIR}"
env \
    BATCH=1 \
    IFACE_WAN="${WAN_DEV}" \
    DOMAINS="${DOMAIN}" \
    IPVS=4 \
    ENABLE_HTTP=1 \
    ENABLE_HTTPS_TLS12=1 \
    ENABLE_HTTPS_TLS13=1 \
    ENABLE_HTTP3=0 \
    REPEATS=1 \
    PARALLEL=0 \
    SCANLEVEL=standard \
    /usr/bin/timeout ${TIMEOUT} /bin/sh "${BLOCKCHECK}" >"${LOG}" 2>&1
EXIT=$?

# Restore ipfw enable state
/sbin/sysctl net.inet.ip.fw.enable=${PREV_IPFW}   >/dev/null 2>&1
/sbin/sysctl net.inet6.ip6.fw.enable=${PREV_IPFW6} >/dev/null 2>&1

# Restart zapret if it was running when we started
[ "${WAS_RUNNING}" = "1" ] && /usr/local/sbin/configctl zapret start >/dev/null 2>&1

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
