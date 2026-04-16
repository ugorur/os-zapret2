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

# How long to let blockcheck run before aborting (seconds). Heavily
# blocked domains can take 15+ min for a full HTTP+TLS12+TLS13 sweep
# (each curl test that fails sits at curl's 5-10s timeout, and there
# are 50+ strategies per protocol). Cap at 25 min by default; user can
# override via env (BLOCKCHECK_TIMEOUT=1800 in front of the call).
TIMEOUT="${BLOCKCHECK_TIMEOUT:-1500}"

DOMAIN="$1"

# Wall-clock timestamps for the JSON output. ISO-8601 UTC for human
# readability; epoch for cheap duration math. We capture STARTED at
# script entry (before any work) and FINISHED right before the JSON
# is emitted, so duration_seconds reflects the full wrapper runtime
# including the configd-stop, ipfw-setup, blockcheck2, and the trap
# cleanup that runs before exit (well, mostly — trap fires AFTER
# this jq emits, but the duration is captured already).
STARTED_EPOCH=$(date -u +%s)
STARTED_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Emit an error JSON. Always includes timing so the caller can
# distinguish "instant validation rejection" (duration ~0s) from
# "blockcheck ran for 25 min then timed out" (duration ~1500s).
emit_error() {
    finished_epoch=$(date -u +%s)
    finished_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    duration=$((finished_epoch - STARTED_EPOCH))
    /usr/local/bin/jq -nc \
        --arg msg "$1" \
        --arg started "${STARTED_ISO}" \
        --arg finished "${finished_iso}" \
        --argjson duration "${duration}" \
        '{status:"error", message:$msg, started:$started, finished:$finished, duration_seconds:$duration}'
}

# Argument validation
if [ -z "${DOMAIN}" ]; then
    emit_error "no domain specified"
    exit 0
fi
if ! echo "${DOMAIN}" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9.\-]+[a-zA-Z]{2,}$'; then
    emit_error "invalid domain format"
    exit 0
fi
if [ ! -x "${BLOCKCHECK}" ]; then
    emit_error "blockcheck2.sh not found — run setup.sh first"
    exit 0
fi
if [ ! -f "${CONFIG}" ]; then
    emit_error "zapret config not found — save plugin settings first"
    exit 0
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

# blockcheck2 wants ipfw enabled to install its own divert rules. Save
# the previous state so the trap can restore exactly what we found.
#
# Safety story (two distinct hazards, both must be handled):
#
#  (1) ipfw default-deny. OPNsense uses pf, so ipfw normally has no
#      rules. `kldload ipfw` loads the module with implicit rule
#      65535 = deny ip from any to any. The instant we
#      `sysctl ...enable=1` the box drops every packet. We add a
#      baseline `allow ip from any to any` at slot 65000 BEFORE
#      enabling. blockcheck2 picks per-PID divert rule numbers via
#      `IPFW_RULE_NUM = ($$ % IPFW_RULE_MAX) + 1` (range 1..999), so
#      its divert rules match first; 65000 just catches everything
#      else and stops the default-deny from killing the network.
#
#  (2) blockcheck2 disables pf. Inside `pktws_ipt_prepare()` the
#      upstream script does `pf_is_avail && pfctl -qd` so its ipfw
#      divert rules don't conflict with pf. On OPNsense disabling pf
#      kills NAT, stateful filtering, and every existing TCP session
#      — SSH dies, configd's connection drops, the box appears
#      wedged. blockcheck2 itself re-enables pf in its `_unprepare`
#      cleanup, but only if we let it finish. If we get killed first,
#      the trap below re-enables pf and reloads OPNsense's ruleset.
WAS_IPFW_LOADED=0
/sbin/kldstat -q -m ipfw && WAS_IPFW_LOADED=1
PREV_IPFW=$(/sbin/sysctl -n net.inet.ip.fw.enable 2>/dev/null || echo 0)
PREV_IPFW6=$(/sbin/sysctl -n net.inet6.ip6.fw.enable 2>/dev/null || echo 0)

# cleanup() runs unconditionally on exit (normal exit, SIGTERM from
# configd timeout, SSH disconnect, ^C). Without this trap, a kill
# midway through blockcheck2 would leave ipfw enabled AND pf disabled
# — both fatal. blockcheck2 itself calls `pfctl -qd` to disable pf
# before each test (so its ipfw divert rules don't fight with pf
# rules), and only re-enables pf in its own cleanup which won't run
# if we get killed first. Disabling pf on OPNsense kills NAT,
# stateful filtering, and every existing TCP session.
#
# The trap is the only thing standing between the user and a wedged
# firewall. We re-enable pf, reload OPNsense's full ruleset (which
# rebuilds NAT and per-interface state), and restore ipfw to the
# state we found it in.
cleanup() {
    # Re-enable pf and rebuild the OPNsense ruleset. `pfctl -e` is a
    # no-op if pf is already enabled. `pfctl -f /tmp/rules.debug`
    # reloads the last-generated OPNsense ruleset; if for any reason
    # that file is gone, fall back to `configctl filter reload` which
    # regenerates it from config.xml.
    /sbin/pfctl -e   >/dev/null 2>&1
    if [ -f /tmp/rules.debug ]; then
        /sbin/pfctl -f /tmp/rules.debug >/dev/null 2>&1
    else
        /usr/local/sbin/configctl filter reload >/dev/null 2>&1
    fi

    # ipfw teardown
    /sbin/sysctl net.inet.ip.fw.enable=${PREV_IPFW}   >/dev/null 2>&1
    /sbin/sysctl net.inet6.ip6.fw.enable=${PREV_IPFW6} >/dev/null 2>&1
    /sbin/ipfw -q delete 65000 2>/dev/null
    [ "${WAS_IPFW_LOADED}" = "0" ] && /sbin/kldunload ipfw 2>/dev/null

    # Bring zapret back if it was running
    [ "${WAS_RUNNING}" = "1" ] && /usr/local/sbin/configctl zapret start >/dev/null 2>&1
    # Note: we deliberately do NOT delete ${LOG} here. It lives at
    # /var/log/zapret/blockcheck-*.log and is part of the persistent
    # archive (rotated by the next run, not by us).
}
trap cleanup EXIT INT TERM HUP

/sbin/kldstat -q -m ipdivert || /sbin/kldload ipdivert
/sbin/kldstat -q -m ipfw     || /sbin/kldload ipfw

# Add baseline allow BEFORE enabling. Rules can be added while ipfw is
# disabled — they just don't take effect until enable=1. Using a fixed
# high slot (65000) means we can find and delete it again on cleanup
# without grepping the ruleset.
/sbin/ipfw -q add 65000 allow ip from any to any 2>/dev/null

/sbin/sysctl net.inet.ip.fw.enable=1   >/dev/null 2>&1
/sbin/sysctl net.inet6.ip6.fw.enable=1 >/dev/null 2>&1

# Persistent per-run log so the user can review the full blockcheck2
# output after the fact (the JSON-embedded log field is truncated to
# the last 2000 bytes for transport size). Filename pattern includes
# timestamp + domain so `ls -t` shows runs in order, and the file
# itself survives the cleanup trap (unlike the old mktemp approach).
LOG_DIR=/var/log/zapret
mkdir -p "${LOG_DIR}" 2>/dev/null
# Sanitize domain for filesystem safety. Limited to chars our regex
# already allows + a colon-collapse, so this is paranoia not necessity.
# Use printf (not echo) so we don't pick up a trailing newline that
# `tr` would convert to a stray "_" in the filename.
LOG_DOMAIN=$(printf '%s' "${DOMAIN}" | tr -c 'a-zA-Z0-9.-' '_')
LOG="${LOG_DIR}/blockcheck-$(date -u +%Y%m%d-%H%M%S)-${LOG_DOMAIN}.log"
: > "${LOG}" 2>/dev/null || {
    emit_error "could not create log file at ${LOG}"
    exit 0
}

# Prune old logs — keep most recent 50 runs to bound disk usage.
# A typical run is 50-500KB; 50 runs ≈ 25MB. tail -n +51 selects the
# 51st onward (oldest), xargs deletes them. Failures are silent.
ls -1t "${LOG_DIR}"/blockcheck-*.log 2>/dev/null | tail -n +51 | xargs rm -f 2>/dev/null

# blockcheck2 has a BATCH=1 env mode that suppresses every interactive
# prompt; combined with DOMAINS/IPVS/ENABLE_*/REPEATS/PARALLEL/SCANLEVEL
# vars, the whole flow is fully non-interactive (no stdin piping needed).
#
# We also set DOMAINS_DEFAULT to the user's domain. blockcheck2 has a
# hard-coded `DOMAINS_DEFAULT=rutracker.org` and falls back to it if
# DOMAINS is empty for any reason. Keeping the default in sync with the
# requested domain means the user can never silently get rutracker
# results when they asked for something else.
cd "${ZAPRET_DIR}"
env \
    BATCH=1 \
    IFACE_WAN="${WAN_DEV}" \
    DOMAINS="${DOMAIN}" \
    DOMAINS_DEFAULT="${DOMAIN}" \
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

# ipfw teardown, log cleanup, and zapret restart all happen in the
# trap handler installed above — no manual cleanup needed here.

FINISHED_EPOCH=$(date -u +%s)
FINISHED_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
DURATION=$((FINISHED_EPOCH - STARTED_EPOCH))

# Try the proper SUMMARY first. blockcheck2 emits `* SUMMARY` only at
# the end of a complete run; everything from that line to EOF is what
# we want.
SUMMARY=$(awk '/^\* SUMMARY/,0' "${LOG}" 2>/dev/null)

# Fallback for timed-out / interrupted runs:
# blockcheck2 prints `!!!!! <test>: working strategy found for ipv<X>
# <domain> : <strategy> !!!!!` INLINE, the moment it confirms each
# protocol's first winner — well before the final SUMMARY. So even on
# `timeout`-induced kills we have actionable per-protocol picks. We
# build a synthetic SUMMARY from those lines + any
# "working without bypass" notes that were already recorded.
#
# This is what makes a 25-min run usable when the full sweep would
# need 45+. The user gets HTTP+TLS12 winners even if TLS13 didn't
# finish.
PARTIAL=0
if [ -z "${SUMMARY}" ]; then
    PARTIAL=1
    INLINE_WINNERS=$(grep -E '^!!!!! curl_test_.*working strategy found' "${LOG}" 2>/dev/null \
        | sed -E 's/^!!!!! ([^:]+): working strategy found for (ipv[46]) ([^ ]+) : (.+) !!!!!$/\1 \2 \3 : \4/' \
        | head -10)
    BASELINE_WINNERS=$(grep -E 'working without bypass' "${LOG}" 2>/dev/null | head -10)

    # Combine into a SUMMARY-shaped block so downstream code paths see
    # the same format as a real SUMMARY.
    SUMMARY="* SUMMARY (partial — blockcheck did not finish, exit=${EXIT})"
    [ -n "${INLINE_WINNERS}" ]   && SUMMARY="${SUMMARY}
${INLINE_WINNERS}"
    [ -n "${BASELINE_WINNERS}" ] && SUMMARY="${SUMMARY}
${BASELINE_WINNERS}"

    # If neither path produced anything, we truly have no signal —
    # surface as an error with the tail of the log so the user can
    # see what blockcheck2 was doing when it died.
    if [ -z "${INLINE_WINNERS}" ] && [ -z "${BASELINE_WINNERS}" ]; then
        /usr/local/bin/jq -nc \
            --arg msg "blockcheck did not produce a summary or any inline winners (exit=${EXIT})" \
            --arg started "${STARTED_ISO}" \
            --arg finished "${FINISHED_ISO}" \
            --argjson duration "${DURATION}" \
            --arg log_file "${LOG}" \
            --rawfile log "${LOG}" \
            '{status:"error", message:$msg, started:$started, finished:$finished, duration_seconds:$duration, log_file:$log_file, log:$log[-2000:]}'
        exit 0
    fi
fi

# Extract useful lines from the summary. blockcheck2 produces:
#   "working without bypass"  → site was never blocked; no strategy needed
#   "<strategy> : works"      → a strategy that defeated the DPI
#   "curl_test_* : ok"        → specific test that passed
# Anything else is noise.
WINNING=$(echo "${SUMMARY}" | grep -iE 'works|^[^ ]+ : ok|without bypass|working strategy found' | head -30)

/usr/local/bin/jq -nc \
    --arg domain "${DOMAIN}" \
    --arg summary "${SUMMARY}" \
    --arg winning "${WINNING}" \
    --arg started "${STARTED_ISO}" \
    --arg finished "${FINISHED_ISO}" \
    --argjson duration "${DURATION}" \
    --arg log_file "${LOG}" \
    --argjson partial "${PARTIAL}" \
    '{status:"ok", domain:$domain, partial:($partial==1), started:$started, finished:$finished, duration_seconds:$duration, log_file:$log_file, summary:$summary, winning:($winning|split("\n"))}'

exit 0
