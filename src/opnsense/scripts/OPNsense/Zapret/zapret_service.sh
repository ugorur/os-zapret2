#!/bin/sh

# zapret_service.sh — Service management for zapret2 on OPNsense
# Called by configd via actions_zapret.conf

ZAPRET_DIR="/usr/local/etc/zapret2"
CONFIG="${ZAPRET_DIR}/zapret.conf"
PIDFILE="/var/run/dvtws2.pid"
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
        echo '{"status": "error", "message": "Configuration file not found. Save settings first."}'
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

start_service() {
    load_config

    if [ "${ZAPRET_ENABLED}" != "1" ]; then
        echo '{"status": "disabled"}'
        exit 0
    fi

    # Check if already running
    if [ -f "${PIDFILE}" ] && kill -0 "$(cat ${PIDFILE})" 2>/dev/null; then
        echo '{"status": "already_running"}'
        exit 0
    fi

    # Verify binary exists
    if [ ! -x "${DVTWS_BIN}" ]; then
        echo '{"status": "error", "message": "dvtws2 binary not found. Run setup first."}'
        exit 1
    fi

    # Load kernel modules
    kldstat -q -m ipfw || kldload ipfw
    kldstat -q -m ipdivert || kldload ipdivert

    # Verify ipfw default-accept (safety check)
    local default_accept=$(sysctl -n net.inet.ip.fw.default_to_accept 2>/dev/null)
    if [ "${default_accept}" != "1" ]; then
        ipfw -q add 65534 allow all from any to any
    fi

    # Resolve WAN interface name
    local wan_dev=$(resolve_interface "${WAN_IF}")

    # Build dvtws2 arguments
    local args="--port=${DIVERT_PORT}"

    # Load Lua libraries (lib must come before antidpi)
    if [ -f "${LUA_LIB}" ]; then
        args="${args} --lua-init=@${LUA_LIB}"
    fi
    if [ -f "${LUA_ANTIDPI}" ]; then
        args="${args} --lua-init=@${LUA_ANTIDPI}"
    fi

    # Add strategy arguments directly
    # Users paste the full dvtws2 args from blockcheck2 results
    if [ -n "${HTTP_ARGS}" ]; then
        args="${args} ${HTTP_ARGS}"
    fi
    if [ -n "${HTTPS_ARGS}" ]; then
        args="${args} ${HTTPS_ARGS}"
    fi

    # Add hostlist if configured
    if [ "${HOSTLIST_MODE}" = "list" ] && [ -f "${HOSTLIST}" ] && [ -s "${HOSTLIST}" ]; then
        args="${args} --hostlist=${HOSTLIST}"
    elif [ "${HOSTLIST_MODE}" = "auto" ]; then
        touch "${AUTOHOSTLIST}" 2>/dev/null
        args="${args} --hostlist-auto=${AUTOHOSTLIST}"
    fi

    # Add exclude list (domains that should NOT be modified by zapret)
    if [ -f "${HOSTLIST_EXCLUDE}" ] && [ -s "${HOSTLIST_EXCLUDE}" ]; then
        args="${args} --hostlist-exclude=${HOSTLIST_EXCLUDE}"
    fi

    # Add extra arguments
    if [ -n "${EXTRA_ARGS}" ]; then
        args="${args} ${EXTRA_ARGS}"
    fi

    # IMPORTANT: Start dvtws2 BEFORE adding ipfw rules
    # If dvtws2 is not listening on the divert port, diverted packets are dropped
    # --sockarg marks reinjected packets so ipfw "not sockarg" skips them
    ${DVTWS_BIN} ${args} --sockarg=0x200 --daemon --pidfile=${PIDFILE}

    # Verify dvtws2 started successfully
    sleep 1
    if [ ! -f "${PIDFILE}" ] || ! kill -0 "$(cat ${PIDFILE})" 2>/dev/null; then
        echo '{"status": "error", "message": "dvtws2 failed to start. Check strategy arguments."}'
        exit 1
    fi

    # Delete old rules first
    local r=${RULE_BASE}
    while [ ${r} -le $((RULE_BASE + 10)) ]; do
        ipfw -q delete ${r} 2>/dev/null
        r=$((r + 1))
    done

    # Outbound-only divert rules — one per port
    # "not sockarg" prevents re-diverting packets already processed by dvtws2
    # dvtws2 marks reinjected packets with sockarg so they skip the divert rule
    local rulenum=${RULE_BASE}
    local IFS_OLD="${IFS}"
    IFS=","
    for port in ${PORTS}; do
        ipfw -qf add ${rulenum} divert ${DIVERT_PORT} tcp from any to any ${port} out not sockarg xmit ${wan_dev}
        rulenum=$((rulenum + 1))
    done
    IFS="${IFS_OLD}"

    echo '{"status": "started", "pid": "'$(cat ${PIDFILE})'", "interface": "'${wan_dev}'"}'
}

stop_service() {
    # IMPORTANT: Remove ipfw rules BEFORE stopping dvtws2
    # This prevents packets from being diverted to a dead socket
        # Delete rule range 19000-19010
    local r=${RULE_BASE}
    while [ ${r} -le $((RULE_BASE + 10)) ]; do
        ipfw -q delete ${r} 2>/dev/null
        r=$((r + 1))
    done

    # Stop dvtws2
    if [ -f "${PIDFILE}" ]; then
        kill "$(cat ${PIDFILE})" 2>/dev/null
        rm -f "${PIDFILE}"
    fi
    killall dvtws2 2>/dev/null

    echo '{"status": "stopped"}'
}

status_service() {
    if [ -f "${PIDFILE}" ] && kill -0 "$(cat ${PIDFILE})" 2>/dev/null; then
        local pid=$(cat ${PIDFILE})
        local rules=$(ipfw show ${RULE_BASE} 2>/dev/null | wc -l | tr -d ' ')
        echo '{"status": "running", "pid": "'${pid}'", "ipfw_rules": '${rules}'}'
    else
        echo '{"status": "stopped"}'
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
    start)
        start_service
        ;;
    stop)
        stop_service
        ;;
    restart)
        stop_service > /dev/null 2>&1
        sleep 1
        start_service
        ;;
    status)
        status_service
        ;;
    reconfigure)
        reconfigure_service
        ;;
    *)
        echo '{"status": "error", "message": "Usage: zapret_service.sh {start|stop|restart|status|reconfigure}"}'
        exit 1
        ;;
esac
