#!/bin/sh

# zapret_service.sh — Service management for zapret2 on OPNsense
# Called by configd via actions_zapret.conf

ZAPRET_DIR="/usr/local/etc/zapret2"
CONFIG="${ZAPRET_DIR}/zapret.conf"
PIDFILE="/var/run/dvtws2.pid"
SUPERVISOR_PIDFILE="/var/run/dvtws2-supervisor.pid"
DVTWS_BIN="${ZAPRET_DIR}/binaries/my/dvtws2"
HOSTLIST="${ZAPRET_DIR}/hostlist.txt"
HOSTLIST_EXCLUDE="${ZAPRET_DIR}/hostlist-exclude.txt"
AUTOHOSTLIST="${ZAPRET_DIR}/autohostlist.txt"
LUA_LIB="${ZAPRET_DIR}/lua/zapret-lib.lua"
LUA_ANTIDPI="${ZAPRET_DIR}/lua/zapret-antidpi.lua"

# ipfw rule numbers reserved for zapret (use high range to avoid conflicts)
RULE_BASE=19000

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
    # so we extract the .device field with jq. (jq is a declared pkg dep.)
    local dev=""
    if [ -x /usr/local/bin/jq ]; then
        dev=$(/usr/local/sbin/pluginctl -4 "${iface}" 2>/dev/null \
            | /usr/local/bin/jq -r --arg if "${iface}" '.[$if][0].device // empty')
    fi
    if [ -n "${dev}" ]; then
        echo "${dev}"
        return
    fi

    # Last resort: hand the original string back to the caller. ipfw will
    # reject an invalid device, which is preferable to silently constructing
    # a malformed rule.
    echo "${iface}"
}

remove_divert_rules() {
    local r=${RULE_BASE}
    while [ ${r} -le $((RULE_BASE + 10)) ]; do
        ipfw -q delete ${r} 2>/dev/null
        r=$((r + 1))
    done
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

    # Load required kernel modules
    kldstat -q -m ipfw     || kldload ipfw
    kldstat -q -m ipdivert || kldload ipdivert

    # Enable ipfw enforcement at the kernel level. The module being loaded
    # is not enough — net.inet.ip.fw.enable must also be 1, otherwise our
    # divert rules sit in the table but match zero packets. This was the
    # root cause of "bypass stopped working after reboot" — on default
    # OPNsense the sysctl is 0 and nothing turns it on for us.
    # Both v4 and v6 enabled to match FreeBSD's default chain registration.
    sysctl net.inet.ip.fw.enable=1  >/dev/null 2>&1
    sysctl net.inet6.ip6.fw.enable=1 >/dev/null 2>&1

    # NOTE: do NOT call `pfctl -d ; pfctl -e` here, do NOT call
    # /usr/local/opnsense/scripts/shaper/sync_fw_hooks.py. Both alter the
    # pfil chain order so that ipfw runs *before* pf on outbound (pre-NAT
    # divert). On real hardware that turns reinjected packets into an
    # infinite loop because the lua-marked sockarg gets stripped by the
    # netgraph PPPoE encap. The natural chain order (pf-then-ipfw on out,
    # which is what you get from just sysctl-enabling ipfw) keeps divert
    # post-NAT and lua's sockarg marker is preserved across reinjection,
    # so `not sockarg` properly breaks the loop. Verified empirically on
    # the live box: with lua scripts + `not sockarg`, counter caps at the
    # actual packet count (no runaway).

    # Safety: ensure default policy is accept (FreeBSD with
    # IPFIREWALL_DEFAULT_TO_ACCEPT, which OPNsense uses, satisfies this).
    local default_accept=$(sysctl -n net.inet.ip.fw.default_to_accept 2>/dev/null)
    if [ "${default_accept}" != "1" ]; then
        ipfw -q add 65534 allow all from any to any
    fi

    local wan_dev=$(resolve_interface "${WAN_IF}")

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

    # IMPORTANT: dvtws2 must be reliably listening on the divert socket for
    # the lifetime of the divert rules. If the listener dies while rules
    # remain, FreeBSD silently drops the matching packets — that's the
    # household-internet-is-down failure mode.
    #
    # Solution: run dvtws2 under daemon(8) with -r so a crash auto-restarts
    # within R seconds. We also write supervisor + child pidfiles so
    # stop_service can take both down cleanly.
    #
    # Note: dvtws2 runs in foreground (no --daemon flag) so daemon(8) keeps
    # supervising it; --pidfile is also dropped because daemon -p handles it.
    /usr/sbin/daemon \
        -P "${SUPERVISOR_PIDFILE}" \
        -p "${PIDFILE}" \
        -r -R 1 \
        -t zapret2 \
        -f \
        ${DVTWS_BIN} ${args} --sockarg=0x200

    # Wait for daemon(8) to fork+exec dvtws2
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

    # Replace any stale divert rules
    remove_divert_rules

    # Outbound divert rules — one per port.
    # `not sockarg` excludes packets dvtws2 has already touched (its lua
    # scripts mark reinjections with SO_USER_COOKIE=0x200), so reinjected
    # traffic skips the divert and continues out — this is what breaks
    # what would otherwise be an infinite re-divert loop.
    # `xmit ${wan_dev}` scopes to outbound on the WAN device only — LAN
    # traffic and traffic on other interfaces is left alone.
    # NOTE: do NOT add `not diverted`. On FreeBSD's PPPoE setup the
    # `diverted` mbuf flag is stripped during netgraph encap on egress, so
    # `not diverted` matches nothing useful and just adds rule overhead.
    local rulenum=${RULE_BASE}
    local IFS_OLD="${IFS}"
    IFS=","
    for port in ${PORTS}; do
        ipfw -qf add ${rulenum} divert ${DIVERT_PORT} \
            tcp from any to any ${port} out not sockarg xmit ${wan_dev}
        rulenum=$((rulenum + 1))
    done
    IFS="${IFS_OLD}"

    echo "zapret is running as pid $(cat ${PIDFILE}) (supervisor pid $(cat ${SUPERVISOR_PIDFILE}))"
}

stop_service() {
    # Remove divert rules FIRST so the gap between supervisor-kill and
    # daemon respawn doesn't drop traffic.
    remove_divert_rules

    # Kill the supervisor so daemon -r doesn't respawn dvtws2
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
    # Anything else falls through to "unknown" and the page-header
    # service-status icons stay hidden.
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
