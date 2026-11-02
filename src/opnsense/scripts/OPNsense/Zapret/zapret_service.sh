#!/bin/sh

# zapret_service.sh — Service management for zapret2 on OPNsense
# Called by configd via actions_zapret.conf.
#
# Architecture — ipfw divert + sockarg loop-guard (inherited from
# v1.1.0 which ran flawlessly for 3 weeks on bare-metal PPPoE and was
# verified to work for NAT'd LAN clients):
#
#   - `ipfw divert $DIVERT_PORT tcp from any to any $port out not sockarg
#     xmit $wan_dev` for each configured port (80, 443). Only matches
#     outbound on WAN and only when the packet DOESN'T already carry the
#     sockarg tag (so reinjected packets from dvtws2 sail past).
#   - dvtws2 is started with `--sockarg=0x200`, which makes it mark every
#     reinjected packet with that tag. Combined with `not sockarg` above,
#     this is the clean loop-prevention pair.
#   - daemon(8) -r supervision auto-respawns dvtws2 within ~1s on crash.
#   - safety watchdog probes a control URL every minute; 3 consecutive
#     failures → stop the service so a bad strategy can't kill household
#     internet for long.
#
# Why NOT pf divert-to (the v1.6.x approach): empirically broken for
# NAT'd LAN-client traffic on both virtio and bare-metal+PPPoE. See
# memory/feedback_v110_ipfw_works_pf_divert_broken.md for the diagnosis.

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

# ipfw rule numbers we own. Range 19000-19010 — high enough to avoid
# OPNsense's own rules, low enough to fire before the default-accept at
# 65534. TCP ports start at 19000; when QUIC is enabled, the next rule
# diverts UDP/443 (19002 with the default TCP ports 80,443). The next
# number holds the reply rules (SYN-ACK/FIN/RST), see install_ipfw_rules.
RULE_BASE=19000
RULE_MAX=$((RULE_BASE + 10))

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

remove_ipfw_rules() {
    # Delete anything in our reserved rule range. Silent if the rule
    # doesn't exist. Run on stop AND before adding on start (so a crashed
    # previous invocation doesn't leave stale rules around).
    local r=${RULE_BASE}
    while [ ${r} -le ${RULE_MAX} ]; do
        /sbin/ipfw -q delete ${r} 2>/dev/null
        r=$((r + 1))
    done
}

ensure_ipfw_default_accept() {
    # ipfw's default ruleset ends at 65535 with "deny ip from any to any"
    # UNLESS the kernel was built with IPFIREWALL_DEFAULT_TO_ACCEPT or
    # the sysctl is 1. On OPNsense neither is guaranteed, so we add an
    # explicit accept-all at 65534 (just inside the default-deny) the
    # first time we enable ipfw. Without this, loading the ipfw module
    # instantly drops every packet the box is handling.
    local default_accept=$(/sbin/sysctl -n net.inet.ip.fw.default_to_accept 2>/dev/null)
    if [ "${default_accept}" != "1" ]; then
        /sbin/ipfw -q add 65534 allow ip from any to any 2>/dev/null || true
    fi
}

configure_ipfw_reinject() {
    # Make ipfw's divert fire BEFORE pf on the outbound IPv4 path, so pf
    # builds correct state for dvtws2's reinjected/desynced packets instead
    # of dropping their return traffic. THE ORDER OF THESE STEPS MATTERS —
    # it was verified live on OPNsense 26.1 / FreeBSD 14 (bare-metal PPPoE):
    #
    #   - With pf ahead of ipfw, the blocked site's reinjected ClientHello
    #     goes out but the server's SYN-ACK is dropped by pf (no matching
    #     state) and the connection hangs — even general HTTPS breaks.
    #   - With ipfw ahead of pf, divert fires AND traffic completes: blocked
    #     domain bypasses, untouched domains keep working.
    #
    # The legacy `net.inet.ip.pfil.outbound=ipfw,pf` knob USED to set this
    # order but DOES NOT EXIST on FreeBSD 14 (the OID is gone), so it can't
    # be relied on. The working mechanism is pfil hook (re)registration order:
    #
    # 1) Enable ipfw FIRST. Enabling links ipfw's hook into the `inet` pfil
    #    head — but it appends AFTER pf (pf registered at boot). `kldload`
    #    alone is not enough: on OPNsense ipfw is usually already resident
    #    (e.g. blockcheck loads it then restores enable=0 on exit), so the
    #    `kldstat || kldload` guard short-circuits and enable stays 0 — then
    #    the divert rules are installed but ipfw evaluates NOTHING. Set it
    #    explicitly, and set it here so the hook is linked before step 2.
    /sbin/sysctl net.inet.ip.fw.one_pass=1 >/dev/null 2>&1
    /sbin/sysctl net.inet.ip.fw.enable=1   >/dev/null 2>&1

    # 2) THEN bounce pf. Disabling unlinks pf's hooks; re-enabling appends
    #    them to the BACK of the chain — i.e. AFTER ipfw, which is now
    #    already linked. Result on the outbound `inet` head:
    #        ipfw:default   (runs first → divert)
    #        pf:default-out (runs second → NAT/state on the final packets)
    #    Doing this bounce BEFORE enabling ipfw (as a previous revision did)
    #    leaves ipfw behind pf and silently breaks the bypass.
    /sbin/pfctl -d >/dev/null 2>&1
    /sbin/pfctl -e >/dev/null 2>&1
}

validate_ipfw_rule_capacity() {
    local rule_capacity=$((RULE_MAX - RULE_BASE + 1))
    local rule_count=0
    local IFS_SAVED="${IFS}"
    IFS=","

    for port in ${PORTS}; do
        rule_count=$((rule_count + 1))
    done

    IFS="${IFS_SAVED}"

    if [ -n "${QUIC_ARGS}" ]; then
        rule_count=$((rule_count + 1))
    fi

    # Reply rules (SYN-ACK/FIN/RST) share one number.
    rule_count=$((rule_count + 1))

    if [ "${rule_count}" -gt "${rule_capacity}" ]; then
        echo "configured TCP and QUIC profiles require ${rule_count} ipfw rules; reserved range ${RULE_BASE}-${RULE_MAX} has room for ${rule_capacity}" >&2
        return 1
    fi

    return 0
}

# Install ipfw divert rules — one per TCP port, plus one for UDP/443 when a
# QUIC strategy is configured. Exact form from upstream zapret's pfSense
# script (init.d/pfsense/zapret.sh:22):
#
#   divert 989 tcp from any to any 80,443 out not diverted not sockarg
#
# Loop-guard: `not diverted not sockarg` — BOTH conditions combined.
# - `not diverted` checks the M_IPFW_DIVERT mbuf flag (IPv4).
# - `not sockarg` checks SO_USER_COOKIE (IPv4 only; FreeBSD kernel
#   ignores sockarg on IPv6, which is why upstream uses a second
#   divert socket for IPv6 and falls back to `diverted`-only.)
#
# Either of these flags alone was insufficient in our virtio tests
# (million-packet loops). Combined with the `pfctl -d ; pfctl -e`
# bounce in configure_ipfw_reinject above, traffic flows correctly.
#
# `xmit $wan_dev` scopes to outbound on the WAN device so we only
# intercept traffic actually leaving the firewall.
#
# SOURCE_NETS (optional, comma-separated IPv4 hosts/CIDRs) narrows the
# divert to traffic FROM those networks. This works because ipfw is
# deliberately hooked AHEAD of pf on the outbound chain (see
# configure_ipfw_reinject) — the packet still carries the LAN client's
# pre-NAT source address when the rule is evaluated. Empty SOURCE_NETS
# keeps the historical match-everything behavior.
#
# When SOURCE_NETS is set we install a SECOND rule per port matching
# `from me`, so the firewall's own traffic (the safety watchdog's control
# probe) still goes through the bypass. It has to be a separate rule:
# ipfw's `me` is a standalone keyword and is NOT accepted inside a
# comma-separated address list — `from 10.0.30.0/24,me` fails to parse
# with `hostname "me" unknown` and the whole rule is silently skipped.
# Both rules share one rule number; ipfw allows duplicates and evaluates
# them in insertion order, and `ipfw delete N` removes both.
install_ipfw_rules() {
    local wan_dev="$1"
    local src_spec="any"

    validate_ipfw_rule_capacity || return 1

    if [ -n "${SOURCE_NETS}" ]; then
        src_spec="${SOURCE_NETS}"
    fi

    remove_ipfw_rules

    local rulenum=${RULE_BASE}
    local IFS_SAVED="${IFS}"
    IFS=","

    for port in ${PORTS}; do
        # src_spec is quoted: IFS is "," here and the address list must
        # reach ipfw as a single token.
        if ! /sbin/ipfw -f add ${rulenum} divert ${DIVERT_PORT} tcp \
            from "${src_spec}" to any ${port} \
            out not diverted not sockarg xmit ${wan_dev} >/dev/null 2>&1; then
            echo "failed to install ipfw divert rule for port ${port} from '${src_spec}' — check Source Networks syntax" >&2
        fi

        if [ -n "${SOURCE_NETS}" ]; then
            /sbin/ipfw -qf add ${rulenum} divert ${DIVERT_PORT} tcp \
                from me to any ${port} \
                out not diverted not sockarg xmit ${wan_dev}
        fi

        rulenum=$((rulenum + 1))
    done

    # QUIC / HTTP3 profile: UDP 443. Installed only when a QUIC strategy is
    # configured, so users who never fill in the QUIC field keep exactly the
    # pre-1.8.3 rule set. It takes the next free number after the TCP ports
    # (19002 with the default PORTS="80,443").
    if [ -n "${QUIC_ARGS}" ]; then
        if ! /sbin/ipfw -f add ${rulenum} divert ${DIVERT_PORT} udp \
            from "${src_spec}" to any 443 \
            out not diverted not sockarg xmit ${wan_dev} >/dev/null 2>&1; then
            echo "failed to install ipfw QUIC divert rule from '${src_spec}' — check Source Networks syntax" >&2
        fi

        if [ -n "${SOURCE_NETS}" ]; then
            /sbin/ipfw -qf add ${rulenum} divert ${DIVERT_PORT} udp \
                from me to any 443 \
                out not diverted not sockarg xmit ${wan_dev}
        fi

        rulenum=$((rulenum + 1))
    fi

    IFS="${IFS_SAVED}"

    # Replies: SYN-ACK, FIN and RST from the TCP ports. dvtws2 needs them
    # for conntrack and autottl, and the auto hostlist only notices an
    # ISP-injected RST if it sees it (issue #12). Upstream's FreeBSD
    # baseline diverts these `in recv $WAN`, but that does not work here:
    #
    # - pf runs before ipfw on the inbound pfil head. When dvtws2 reinjects
    #   a packet, pf sees the pf divert tag and deletes ipfw's
    #   MTAG_IPFW_RULE with it (sys/netpfil/pf/pf.c, pf_test), so
    #   `not diverted` never matches and the packet loops (seen live:
    #   ~100k passes of one SYN-ACK in 5 s).
    # - For LAN clients pf has already undone the NAT on the first pass,
    #   so on the second pass it finds no state and drops the reply.
    # - Moving ipfw ahead of pf on input stops the loop, but then dvtws2
    #   sees the WAN address and NAT port and cannot match the reply to
    #   the client's connection.
    #
    # So divert the reply on its way OUT to the LAN instead: `recv` still
    # names the WAN it arrived on, the addresses are already de-NATed, and
    # ipfw runs before pf on output, so its divert tag survives. dvtws2
    # matches the packet to its conntrack entry and treats it as incoming.
    # Costs: replies to the firewall's own traffic are not seen, and the
    # TTL dvtws2 learns is one lower (already decremented by forwarding).
    # Data packets stay in the kernel. All three rules share one number.
    local flags
    for flags in syn,ack fin rst; do
        /sbin/ipfw -qf add ${rulenum} divert ${DIVERT_PORT} tcp \
            from any ${PORTS} to "${src_spec}" tcpflags ${flags} \
            out recv ${wan_dev} not diverted
    done
}

start_service() {
    load_config

    if [ "${ZAPRET_ENABLED}" != "1" ]; then
        echo "zapret is not running (disabled in settings)"
        exit 0
    fi

    validate_ipfw_rule_capacity || exit 1

    # Already running?
    if [ -f "${SUPERVISOR_PIDFILE}" ] && kill -0 "$(cat ${SUPERVISOR_PIDFILE})" 2>/dev/null; then
        echo "zapret is already running as pid $(cat ${PIDFILE} 2>/dev/null || echo unknown)"
        exit 0
    fi

    if [ ! -x "${DVTWS_BIN}" ]; then
        echo "dvtws2 binary not found at ${DVTWS_BIN} — run setup.sh first" >&2
        exit 1
    fi

    # Load required kernel modules. ipdivert is the divert socket
    # backend; ipfw is the firewall that owns our divert rules.
    kldstat -q -m ipdivert || kldload ipdivert
    kldstat -q -m ipfw     || kldload ipfw
    ensure_ipfw_default_accept
    configure_ipfw_reinject

    local wan_dev=$(resolve_interface "${WAN_IF}")
    if [ -z "${wan_dev}" ]; then
        echo "could not resolve WAN interface '${WAN_IF}' to a kernel device" >&2
        exit 1
    fi

    # Build dvtws2 args
    local args="--port=${DIVERT_PORT}"
    [ -f "${LUA_LIB}" ]      && args="${args} --lua-init=@${LUA_LIB}"
    [ -f "${LUA_ANTIDPI}" ]  && args="${args} --lua-init=@${LUA_ANTIDPI}"

    # TCP profile: HTTP/HTTPS only.
    args="${args} --filter-tcp=${PORTS}"
    [ -n "${HTTP_ARGS}" ]    && args="${args} ${HTTP_ARGS}"
    [ -n "${HTTPS_ARGS}" ]   && args="${args} ${HTTPS_ARGS}"

    local hostlist_args=""
    local hostlist_noauto_args=""

    if [ "${HOSTLIST_MODE}" = "list" ] && [ -f "${HOSTLIST}" ] && [ -s "${HOSTLIST}" ]; then
        hostlist_args="${hostlist_args} --hostlist=${HOSTLIST}"
        hostlist_noauto_args="${hostlist_noauto_args} --hostlist=${HOSTLIST}"
    elif [ "${HOSTLIST_MODE}" = "auto" ]; then
        touch "${AUTOHOSTLIST}" 2>/dev/null
        hostlist_args="${hostlist_args} --hostlist-auto=${AUTOHOSTLIST}"
        hostlist_noauto_args="${hostlist_noauto_args} --hostlist=${AUTOHOSTLIST}"
    fi

    if [ -f "${HOSTLIST_EXCLUDE}" ] && [ -s "${HOSTLIST_EXCLUDE}" ]; then
        hostlist_args="${hostlist_args} --hostlist-exclude=${HOSTLIST_EXCLUDE}"
        hostlist_noauto_args="${hostlist_noauto_args} --hostlist-exclude=${HOSTLIST_EXCLUDE}"
    fi

    # Apply host filtering to the TCP profile.
    args="${args}${hostlist_args}"

    # QUIC is a separate UDP profile. Auto-hostlist entries are used as a
    # regular hostlist here, matching upstream <HOSTLIST_NOAUTO> semantics.
    if [ -n "${QUIC_ARGS}" ]; then
        args="${args} --new --filter-udp=443 --filter-l7=quic${hostlist_noauto_args} ${QUIC_ARGS}"
    fi

    [ -n "${EXTRA_ARGS}" ] && args="${args} ${EXTRA_ARGS}"

    # Run dvtws2 under daemon(8) -r so a crash auto-restarts within 1s.
    # No --daemon / --pidfile to dvtws2 — daemon(8) manages those.
    #
    # `--user=nobody` drops privs to UID 65534 AFTER dvtws2 has bound its
    # raw/divert sockets. This is what enables our `not uid 65534` ipfw
    # filter (see remove/install rules below) to skip dvtws2's reinjected
    # packets — without it, the reinjects re-enter our own divert rule
    # and produce the catastrophic million-packet loop observed on virtio.
    /usr/sbin/daemon \
        -P "${SUPERVISOR_PIDFILE}" \
        -p "${PIDFILE}" \
        -r -R 1 \
        -t zapret2 \
        -f \
        ${DVTWS_BIN} ${args} --sockarg=0x200 --user=nobody

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

    install_ipfw_rules "${wan_dev}" || exit 1

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
    # Remove ipfw divert rules FIRST so traffic flows normally during
    # the tear-down window. If we killed dvtws2 first, the rules would
    # still divert to a dead socket and packets would drop until we got
    # around to removing them.
    remove_ipfw_rules

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

repair_service() {
    load_config

    if [ "${ZAPRET_ENABLED}" != "1" ]; then
        echo "zapret repair skipped (disabled in settings)"
        exit 0
    fi

    validate_ipfw_rule_capacity || exit 1

    # Repair is intended for events such as WAN DHCP/PPPoE renew where
    # OPNsense may disable or rebuild ipfw while dvtws2 itself keeps running.
    # Do not restart the daemon here.
    if [ ! -f "${PIDFILE}" ] || ! kill -0 "$(cat ${PIDFILE})" 2>/dev/null; then
        echo "zapret repair skipped (dvtws2 is not running)"
        exit 0
    fi

    kldstat -q -m ipdivert || kldload ipdivert
    kldstat -q -m ipfw     || kldload ipfw

    ensure_ipfw_default_accept
    configure_ipfw_reinject

    local wan_dev=$(resolve_interface "${WAN_IF}")
    if [ -z "${wan_dev}" ]; then
        echo "could not resolve WAN interface '${WAN_IF}' to a kernel device" >&2
        exit 1
    fi

    install_ipfw_rules "${wan_dev}" || exit 1

    echo "zapret firewall state repaired on ${wan_dev}"
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
    repair)      repair_service ;;
    reconfigure) reconfigure_service ;;
    *)
        echo "usage: zapret_service.sh {start|stop|restart|status|repair|reconfigure}" >&2
        exit 1
        ;;
esac
