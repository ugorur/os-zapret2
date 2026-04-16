#!/bin/sh

# watchdog_loop.sh — Long-running wrapper that calls watchdog.sh every 60s.
# Started by zapret_service.sh under daemon(8) supervision so it survives
# crashes and gets cleaned up on service stop.

WATCHDOG="/usr/local/opnsense/scripts/OPNsense/Zapret/watchdog.sh"

# Initial settle delay — give dvtws2 a moment after start before we start
# probing the bypass path.
sleep 30

while true; do
    [ -x "${WATCHDOG}" ] && "${WATCHDOG}"
    sleep 60
done
