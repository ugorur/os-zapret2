#!/bin/sh

# watchdog.sh — Auto-disable zapret if the bypass is killing general HTTPS.
#
# Runs from cron every minute. If the zapret service is enabled AND running
# AND a control URL stops being reachable for N consecutive checks, this
# script stops the service (and logs why), so the user's internet auto-
# recovers from a misconfigured strategy without anyone touching anything.
#
# Re-enable manually from Services > Zapret DPI Bypass once the strategy
# is fixed (Diagnostics > Blockcheck helps find one that works).

ZAPRET_DIR="/usr/local/etc/zapret2"
CONFIG="${ZAPRET_DIR}/zapret.conf"
PIDFILE="/var/run/dvtws2.pid"
STATE="/var/run/zapret-watchdog.state"

# How many consecutive failed checks before auto-stop.
MAX_FAILURES=3

# Control URL — must be a stable HTTPS endpoint that's never DPI-blocked.
# example.com is operated by IANA, has minimal traffic, and is unlikely to
# go down or change. Override via /usr/local/etc/zapret2/watchdog.conf if
# the user wants a different probe target.
CONTROL_URL="https://example.com"
CONTROL_TIMEOUT=8

[ -f /usr/local/etc/zapret2/watchdog.conf ] && . /usr/local/etc/zapret2/watchdog.conf

log() {
    /usr/bin/logger -t zapret-watchdog -p daemon.notice "$*"
}

# Bail if config not present or service disabled
[ ! -f "${CONFIG}" ] && exit 0
. "${CONFIG}"
[ "${ZAPRET_ENABLED}" != "1" ] && exit 0

# Bail if service isn't running (nothing to watchdog)
if [ ! -f "${PIDFILE}" ] || ! kill -0 "$(cat ${PIDFILE})" 2>/dev/null; then
    # dvtws2 is dead — bypass is off. Reset failure counter, exit.
    rm -f "${STATE}"
    exit 0
fi

# Run the control check from the firewall itself. This goes through the
# divert rule (firewall-originated traffic IS subject to the rule), so it
# exercises the same path as user LAN traffic.
if /usr/bin/fetch -T ${CONTROL_TIMEOUT} -q -o /dev/null "${CONTROL_URL}" 2>/dev/null; then
    # Success — reset counter
    rm -f "${STATE}"
    exit 0
fi

# Failure path. Increment counter, decide whether to trip.
FAIL_COUNT=$(cat "${STATE}" 2>/dev/null || echo 0)
FAIL_COUNT=$((FAIL_COUNT + 1))
echo "${FAIL_COUNT}" > "${STATE}"
log "control fetch failed (${FAIL_COUNT}/${MAX_FAILURES}) for ${CONTROL_URL}"

if [ "${FAIL_COUNT}" -ge "${MAX_FAILURES}" ]; then
    log "${MAX_FAILURES} consecutive control failures — STOPPING zapret service to restore internet"
    /usr/local/sbin/configctl zapret stop >/dev/null 2>&1
    rm -f "${STATE}"
    log "service stopped. Re-enable via GUI after fixing strategy. Strategy that triggered the trip: HTTP_ARGS='${HTTP_ARGS}' HTTPS_ARGS='${HTTPS_ARGS}'"
fi

exit 0
