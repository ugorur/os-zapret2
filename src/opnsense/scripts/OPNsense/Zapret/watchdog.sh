#!/bin/sh

# watchdog.sh — Auto-disable zapret if the bypass is killing general HTTPS.
#
# Runs every minute from watchdog_loop.sh. If the zapret service is enabled AND running
# AND none of the check domains is reachable for N consecutive checks, this
# script stops the service (and logs why), so the user's internet auto-
# recovers from a misconfigured strategy without anyone touching anything.
#
# Re-enable manually from Services > Zapret DPI Bypass once the strategy
# is fixed (Diagnostics > Blockcheck helps find one that works).

ZAPRET_DIR="${ZAPRET_DIR:-/usr/local/etc/zapret2}"
CONFIG="${ZAPRET_DIR}/zapret.conf"
STATE_DIR="${WATCHDOG_STATE_DIR:-/var/run}"
PIDFILE="${STATE_DIR}/dvtws2.pid"
STATE="${STATE_DIR}/zapret-watchdog.state"
CURL="${CURL:-/usr/local/bin/curl}"
CONFIGCTL="${CONFIGCTL:-/usr/local/sbin/configctl}"
LOGGER="${LOGGER:-/usr/bin/logger}"

# How many consecutive failed checks before auto-stop.
MAX_FAILURES=3

# Hard limit in seconds for one probe: DNS, TCP, TLS and the response.
CONTROL_TIMEOUT=8

# Legacy override: a full URL set in watchdog.conf wins over the
# "Watchdog Check Domains" setting from the GUI.
CONTROL_URL=""

[ -f "${ZAPRET_DIR}/watchdog.conf" ] && . "${ZAPRET_DIR}/watchdog.conf"

log() {
    "${LOGGER}" -t zapret-watchdog -p daemon.notice "$*"
}

# Any HTTP answer, even 429 (rate limited) or 5xx, proves HTTPS through the
# bypass works; only a transport failure (status 000) counts. curl's
# --max-time bounds the whole probe. fetch(1)'s -T did not cover the TLS
# handshake, so a target that stalled it hung the watchdog (issue #14).
control_ok() {
    code=$("${CURL}" -sS -o /dev/null --connect-timeout 5 \
        --max-time "${CONTROL_TIMEOUT}" -w '%{http_code}' "$1" 2>/dev/null)
    [ -n "${code}" ] && [ "${code}" != "000" ]
}

# Bail if config not present or service disabled
[ ! -f "${CONFIG}" ] && exit 0
. "${CONFIG}"
[ "${ZAPRET_ENABLED}" != "1" ] && exit 0

# Bail if service isn't running (nothing to watchdog)
if [ ! -f "${PIDFILE}" ] || ! kill -0 "$(cat "${PIDFILE}")" 2>/dev/null; then
    # dvtws2 is dead — bypass is off. Reset failure counter, exit.
    rm -f "${STATE}"
    exit 0
fi

if [ -n "${CONTROL_URL}" ]; then
    URLS=" ${CONTROL_URL}"
else
    URLS=""
    for domain in $(printf '%s' "${WATCHDOG_DOMAINS:-example.com}" | tr ',' ' '); do
        URLS="${URLS} https://${domain}"
    done
fi

# Run the control check from the firewall itself. This goes through the
# divert rule (firewall-originated traffic IS subject to the rule — even
# when SOURCE_NETS narrows the rule, zapret_service.sh appends `me` to the
# source list precisely so this probe keeps working), so it exercises the
# same path as user LAN traffic. One reachable domain is enough; each is
# tried once per run, never retried in a loop.
for url in ${URLS}; do
    if control_ok "${url}"; then
        rm -f "${STATE}"
        exit 0
    fi
done

# Failure path. Increment counter, decide whether to trip.
FAIL_COUNT=$(cat "${STATE}" 2>/dev/null || echo 0)
FAIL_COUNT=$((FAIL_COUNT + 1))
echo "${FAIL_COUNT}" > "${STATE}"
log "control check failed (${FAIL_COUNT}/${MAX_FAILURES}) for${URLS}"

if [ "${FAIL_COUNT}" -ge "${MAX_FAILURES}" ]; then
    log "${MAX_FAILURES} consecutive control failures — STOPPING zapret service to restore internet"
    "${CONFIGCTL}" zapret stop >/dev/null 2>&1
    rm -f "${STATE}"
    log "service stopped. Re-enable via GUI after fixing strategy. Strategy that triggered the trip: HTTP_ARGS='${HTTP_ARGS}' HTTPS_ARGS='${HTTPS_ARGS}'"
fi

exit 0
