#!/bin/sh

# zapret_service.sh — Service management for zapret2 on OPNsense
# Called by configd via actions_zapret.conf.
#
# Architecture (rev 7+): pf divert-to instead of ipfw divert.
#   - pf rule in our own anchor (userrules/zapret) matches outbound HTTP/HTTPS
#     on the WAN interface and diverts to dvtws2 via 127.0.0.1:DIVERT_PORT.
#   - pf's stateful divert handling avoids the infinite re-divert loop that
#     ipfw divert exhibits on Proxmox/virtio (and is fragile on bare-metal+
#     PPPoE too). The anchor survives main-pf reloads (OPNsense GUI saves).
#   - dvtws2 unchanged: receives, applies LUA-driven desync, reinjects.
#   - safety watchdog (separate script) probes a control URL through the
#     bypass; auto-stops the service after 3 consecutive failures so a
#     misconfigured strategy can't kill household internet for long.

ZAPRET_DIR="/usr/local/etc/zapret2"
CONFIG="${ZAPRET_DIR}/zapret.conf"
PIDFILE="/var/run/dvtws2.pid"
SUPERVISOR_PIDFILE="/var/run/dvtws2-supervisor.pid"
WATCHDOG_PIDFILE="/var/run/zapret-watchdog.pid"
WATCHDOG_SUPERVISOR_PIDFILE="/var/run/zapret-watchdog-supervisor.pid"
WATCHDOG_LOOP="/usr/local/opnsense/scripts/OPNsense/Zapret/watchdog_loop.sh"
DVTWS_BIN="${ZAPRET_DIR}/binaries/my/dvtws2"
HOSTLIST="${ZAPRET_DIR}/hostlist.txt"
HOSTLIST_EXCLUDE="${ZAPRET_DIR}/hostlist-exclude.txt"
AUTOHOSTLIST="${ZAPRET_DIR}/autohostlist.txt"
LUA_LIB="${ZAPRET_DIR}/lua/zapret-lib.lua"
LUA_ANTIDPI="${ZAPRET_DIR}/lua/zapret-antidpi.lua"

PF_ANCHOR="userrules/zapret"

load_config() {
    if [ ! -f "${CONFIG}" ]; then
        echo "zapret is not running (configuration file not found — save settings first)"
        exit 1
    fi
    . "${CONFIG}"
}

resolve_interface() {
    local iface="$1"

    # Direct match first (raw device names like pppoe2, igc0)
    if ifconfig "${iface}" > /dev/null 2>&1; then
        echo "${iface}"
        return
    fi

    # Map an OPNsense logical interface (opt11, wan, lan, …) to its kernel
    # device. pluginctl -4 emits JSON like:
    #   {"opt11":[{"address":"...","device":"pppoe2", ...}]}
    local dev=""
    if [ -x /usr/local/bin/jq ]; then
        dev=$(/usr/local/sbin/pluginctl -4 "${iface}" 2>/dev/null \
            | /usr/local/bin/jq -r --arg if "${iface}" '.[$if][0].device // empty')
    fi
    if [ -n "${dev}" ]; then
        echo "${dev}"
        return
    fi

    # Last resort: hand the original string back to the caller.
    echo "${iface}"
}

remove_pf_anchor() {
    /sbin/pfctl -a "${PF_ANCHOR}" -F rules >/dev/null 2>&1 || true
}

start_service() {
    load_config

    if [ "${ZAPRET_ENABLED}" != "1" ]; then
        echo "zapret is not running (disabled in settings)"
        exit 0
    fi

    # Already running?
    if [ -f "${SUPERVISOR_PIDFILE}" ] && kill -0 "$(cat ${SUPERVISOR_PIDFILE})" 2>/dev/null; then
        echo "zapret is already running as pid $(cat ${PIDFILE} 2>/dev/null || echo unknown)"
        exit 0
    fi

    if [ ! -x "${DVTWS_BIN}" ]; then
        echo "dvtws2 binary not found at ${DVTWS_BIN} — run setup.sh first" >&2
        exit 1
    fi

    # Load required kernel modules. ipdivert is the kernel side of pf's
    # divert-to (and ipfw divert too — same infrastructure either way).
    kldstat -q -m ipdivert || kldload ipdivert

    local wan_dev=$(resolve_interface "${WAN_IF}")
    if [ -z "${wan_dev}" ]; then
        echo "could not resolve WAN interface '${WAN_IF}' to a kernel device" >&2
        exit 1
    fi

    # Build dvtws2 args
    local args="--port=${DIVERT_PORT}"
    [ -f "${LUA_LIB}" ]      && args="${args} --lua-init=@${LUA_LIB}"
    [ -f "${LUA_ANTIDPI}" ]  && args="${args} --lua-init=@${LUA_ANTIDPI}"
    [ -n "${HTTP_ARGS}" ]    && args="${args} ${HTTP_ARGS}"
    [ -n "${HTTPS_ARGS}" ]   && args="${args} ${HTTPS_ARGS}"

    if [ "${HOSTLIST_MODE}" = "list" ] && [ -f "${HOSTLIST}" ] && [ -s "${HOSTLIST}" ]; then
        args="${args} --hostlist=${HOSTLIST}"
    elif [ "${HOSTLIST_MODE}" = "auto" ]; then
        touch "${AUTOHOSTLIST}" 2>/dev/null
        args="${args} --hostlist-auto=${AUTOHOSTLIST}"
    fi

    if [ -f "${HOSTLIST_EXCLUDE}" ] && [ -s "${HOSTLIST_EXCLUDE}" ]; then
        args="${args} --hostlist-exclude=${HOSTLIST_EXCLUDE}"
    fi

    [ -n "${EXTRA_ARGS}" ] && args="${args} ${EXTRA_ARGS}"

    # Run dvtws2 under daemon(8) -r so a crash auto-restarts within 1s.
    # No --daemon / --pidfile to dvtws2 — daemon(8) manages those.
    /usr/sbin/daemon \
        -P "${SUPERVISOR_PIDFILE}" \
        -p "${PIDFILE}" \
        -r -R 1 \
        -t zapret2 \
        -f \
        ${DVTWS_BIN} ${args} --sockarg=0x200

    sleep 1
    if [ ! -f "${SUPERVISOR_PIDFILE}" ] || ! kill -0 "$(cat ${SUPERVISOR_PIDFILE})" 2>/dev/null; then
        echo "dvtws2 supervisor failed to start" >&2
        exit 1
    fi
    if [ ! -f "${PIDFILE}" ] || ! kill -0 "$(cat ${PIDFILE})" 2>/dev/null; then
        sleep 2
        if [ ! -f "${PIDFILE}" ] || ! kill -0 "$(cat ${PIDFILE})" 2>/dev/null; then
            kill "$(cat ${SUPERVISOR_PIDFILE})" 2>/dev/null
            rm -f "${SUPERVISOR_PIDFILE}"
            echo "dvtws2 child failed to start — check strategy arguments" >&2
            exit 1
        fi
    fi

    # Install pf divert-to rule via our private anchor. The anchor survives
    # OPNsense's pf rule reloads (verified empirically); we just need to
    # (re-)install it whenever the service starts.
    #
    # `pass out quick on $WAN ... divert-to 127.0.0.1 port $DIVERT_PORT keep state`
    # diverts the first packet of each new outbound HTTP/HTTPS connection
    # to dvtws2; subsequent packets of the same connection are tied to the
    # state, dvtws2 sees them too, and reinjections are NOT re-diverted
    # because pf's divert-to handles loop prevention via state. This is the
    # critical difference vs ipfw divert which infinite-loops on virtio.
    remove_pf_anchor
    PORT_LIST=$(echo "${PORTS}" | sed 's/,/, /g')   # "80,443" → "80, 443"
    /sbin/pfctl -a "${PF_ANCHOR}" -f - <<EOF
pass out quick on ${wan_dev} inet proto tcp from any to any port { ${PORT_LIST} } divert-to 127.0.0.1 port ${DIVERT_PORT} keep state
EOF

    # Start the safety watchdog under daemon(8) too. It probes a control URL
    # every minute and stops the service if 3 consecutive checks fail —
    # so a misconfigured strategy that breaks general HTTPS auto-recovers
    # within ~3 minutes instead of leaving the household offline.
    if [ -x "${WATCHDOG_LOOP}" ]; then
        /usr/sbin/daemon \
            -P "${WATCHDOG_SUPERVISOR_PIDFILE}" \
            -p "${WATCHDOG_PIDFILE}" \
            -r -R 5 \
            -t zapret-watchdog \
            -f \
            "${WATCHDOG_LOOP}"
    fi

    echo "zapret is running as pid $(cat ${PIDFILE}) (supervisor pid $(cat ${SUPERVISOR_PIDFILE}))"
}

stop_service() {
    # Remove pf divert-to rule FIRST so traffic flows normally during the
    # tear-down window.
    remove_pf_anchor

    # Kill the watchdog FIRST (before its supervisor can respawn it).
    # Also clean any orphans from previous installs that lost their
    # supervisor's pidfile during pkg upgrade.
    if [ -f "${WATCHDOG_SUPERVISOR_PIDFILE}" ]; then
        kill "$(cat ${WATCHDOG_SUPERVISOR_PIDFILE})" 2>/dev/null
        rm -f "${WATCHDOG_SUPERVISOR_PIDFILE}"
    fi
    if [ -f "${WATCHDOG_PIDFILE}" ]; then
        kill "$(cat ${WATCHDOG_PIDFILE})" 2>/dev/null
        rm -f "${WATCHDOG_PIDFILE}"
    fi
    pkill -f watchdog_loop.sh 2>/dev/null
    pkill -f "daemon: zapret-watchdog" 2>/dev/null
    rm -f /var/run/zapret-watchdog.state

    # Kill the dvtws2 supervisor so daemon -r doesn't respawn dvtws2
    if [ -f "${SUPERVISOR_PIDFILE}" ]; then
        kill "$(cat ${SUPERVISOR_PIDFILE})" 2>/dev/null
        rm -f "${SUPERVISOR_PIDFILE}"
    fi

    # Then dvtws2 itself, in case it survives or wasn't supervised
    if [ -f "${PIDFILE}" ]; then
        kill "$(cat ${PIDFILE})" 2>/dev/null
        rm -f "${PIDFILE}"
    fi
    killall dvtws2 2>/dev/null

    echo "zapret is not running (stopped)"
}

status_service() {
    # Output must match the convention ApiMutableServiceControllerBase
    # parses: substring "is running" → running; "not running" → stopped.
    if [ -f "${PIDFILE}" ] && kill -0 "$(cat ${PIDFILE})" 2>/dev/null; then
        echo "zapret is running as pid $(cat ${PIDFILE})"
    else
        echo "zapret is not running"
    fi
}

reconfigure_service() {
    /usr/local/sbin/configctl template reload OPNsense/Zapret

    load_config

    if [ "${ZAPRET_ENABLED}" = "1" ]; then
        stop_service > /dev/null 2>&1
        sleep 1
        start_service
    else
        stop_service
    fi
}

case "$1" in
    start)       start_service ;;
    stop)        stop_service ;;
    restart)     stop_service > /dev/null 2>&1; sleep 1; start_service ;;
    status)      status_service ;;
    reconfigure) reconfigure_service ;;
    *)
        echo "usage: zapret_service.sh {start|stop|restart|status|reconfigure}" >&2
        exit 1
        ;;
esac
