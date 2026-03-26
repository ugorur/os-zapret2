#!/bin/sh

# zapret_service.sh — Service management for zapret2 on OPNsense
# Called by configd via actions_zapret.conf

ZAPRET_DIR="/usr/local/etc/zapret2"
CONFIG="${ZAPRET_DIR}/zapret.conf"
PIDFILE="/var/run/dvtws2.pid"
DVTWS_BIN="${ZAPRET_DIR}/nfq/dvtws2"
TPWS_BIN="${ZAPRET_DIR}/nfq/tpws2"
HOSTLIST="${ZAPRET_DIR}/hostlist.txt"

# ipfw rule numbers reserved for zapret
RULE_BASE=19000

load_config() {
    if [ ! -f "${CONFIG}" ]; then
        echo '{"status": "error", "message": "Configuration file not found. Save settings first."}'
        exit 1
    fi
    . "${CONFIG}"
}

resolve_interface() {
    # OPNsense stores interface names like "opt1", "wan", etc.
    # Resolve to the actual device name using ifconfig
    local iface="$1"

    # Try direct match first (e.g., pppoe2, igc0)
    if ifconfig "${iface}" > /dev/null 2>&1; then
        echo "${iface}"
        return
    fi

    # Try OPNsense interface mapping via config.xml
    local dev=$(grep -A3 "<if>${iface}</if>" /conf/config.xml 2>/dev/null | grep '<if>' | sed 's/.*<if>\(.*\)<\/if>.*/\1/' | head -1)
    if [ -n "${dev}" ] && ifconfig "${dev}" > /dev/null 2>&1; then
        echo "${dev}"
        return
    fi

    # Fallback: use the value as-is
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
        # Add explicit allow-all rule as safety net
        ipfw -q add 65534 allow all from any to any
    fi

    # Resolve WAN interface name
    local wan_dev=$(resolve_interface "${WAN_IF}")

    # Build dvtws2 arguments
    local args="--port=${DIVERT_PORT}"
    args="${args} --dpi-desync=${DESYNC_MODE}"

    if [ -n "${DESYNC_TTL}" ] && [ "${DESYNC_TTL}" != "0" ]; then
        args="${args} --dpi-desync-ttl=${DESYNC_TTL}"
    fi

    if [ -n "${DESYNC_SPLIT_POS}" ] && [ "${DESYNC_SPLIT_POS}" != "0" ]; then
        args="${args} --dpi-desync-split-pos=${DESYNC_SPLIT_POS}"
    fi

    if [ -n "${DESYNC_FOOLING}" ] && [ "${DESYNC_FOOLING}" != "none" ]; then
        args="${args} --dpi-desync-fooling=${DESYNC_FOOLING}"
    fi

    # Add fake TLS payload if available and mode uses it
    local fake_tls="${ZAPRET_DIR}/files/fake/tls_clienthello_www_google_com.bin"
    case "${DESYNC_MODE}" in
        fake|fakedsplit|fakeddisorder)
            if [ -f "${fake_tls}" ]; then
                args="${args} --dpi-desync-fake-tls=${fake_tls}"
            fi
            ;;
    esac

    # Add hostlist if configured
    if [ "${HOSTLIST_MODE}" = "list" ] && [ -f "${HOSTLIST}" ] && [ -s "${HOSTLIST}" ]; then
        args="${args} --hostlist=${HOSTLIST}"
    fi

    # Add custom arguments
    if [ -n "${CUSTOM_ARGS}" ]; then
        args="${args} ${CUSTOM_ARGS}"
    fi

    # Add ipfw divert rules
    ipfw -q delete ${RULE_BASE} ${RULE_BASE}1 ${RULE_BASE}2 ${RULE_BASE}3 2>/dev/null
    ipfw -q add ${RULE_BASE} divert ${DIVERT_PORT} tcp from any to any ${PORTS} out xmit ${wan_dev}
    ipfw -q add ${RULE_BASE}1 divert ${DIVERT_PORT} tcp from any ${PORTS} to any tcpflags syn,ack in recv ${wan_dev}
    ipfw -q add ${RULE_BASE}2 divert ${DIVERT_PORT} tcp from any ${PORTS} to any tcpflags fin in recv ${wan_dev}
    ipfw -q add ${RULE_BASE}3 divert ${DIVERT_PORT} tcp from any ${PORTS} to any tcpflags rst in recv ${wan_dev}

    # Start dvtws2 as daemon
    ${DVTWS_BIN} ${args} --daemon --pidfile=${PIDFILE}

    if [ -f "${PIDFILE}" ] && kill -0 "$(cat ${PIDFILE})" 2>/dev/null; then
        echo '{"status": "started", "pid": "'$(cat ${PIDFILE})'", "interface": "'${wan_dev}'"}'
    else
        # Cleanup on failure
        ipfw -q delete ${RULE_BASE} ${RULE_BASE}1 ${RULE_BASE}2 ${RULE_BASE}3 2>/dev/null
        echo '{"status": "error", "message": "dvtws2 failed to start. Check arguments."}'
        exit 1
    fi
}

stop_service() {
    # Stop dvtws2
    if [ -f "${PIDFILE}" ]; then
        kill "$(cat ${PIDFILE})" 2>/dev/null
        rm -f "${PIDFILE}"
    fi

    # Also try killall as fallback
    killall dvtws2 2>/dev/null

    # Remove ipfw rules
    ipfw -q delete ${RULE_BASE} ${RULE_BASE}1 ${RULE_BASE}2 ${RULE_BASE}3 2>/dev/null

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
    # Regenerate templates
    /usr/local/sbin/configctl template reload OPNsense/Zapret

    load_config

    if [ "${ZAPRET_ENABLED}" = "1" ]; then
        stop_service > /dev/null 2>&1
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
