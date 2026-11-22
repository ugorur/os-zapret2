#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
script="${repo_root}/src/opnsense/scripts/OPNsense/Zapret/watchdog.sh"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/watchdog.XXXXXX")
bin_dir="${test_root}/bin"
tarpit_pid=""

cleanup()
{
    [ -n "${tarpit_pid}" ] && kill "${tarpit_pid}" 2>/dev/null || true
    rm -rf "${test_root}"
}
trap cleanup EXIT INT TERM HUP

mkdir -p "${bin_dir}" "${test_root}/zapret" "${test_root}/run"
echo $$ > "${test_root}/run/dvtws2.pid"

# Stub curl: answer by host name, record each URL.
cat > "${bin_dir}/curl" <<'EOF'
#!/bin/sh
for arg; do url="${arg}"; done
echo "${url}" >> "${CURL_LOG}"
case "${url}" in
    *ratelimited*) printf 429 ;;
    *ok*) printf 200 ;;
    *) printf 000; exit 28 ;;
esac
EOF
printf '#!/bin/sh\necho "$*" >> "%s"\n' "${test_root}/configctl.log" > "${bin_dir}/configctl"
printf '#!/bin/sh\necho "$*" >> "%s"\n' "${test_root}/logger.log" > "${bin_dir}/logger"
chmod +x "${bin_dir}/curl" "${bin_dir}/configctl" "${bin_dir}/logger"

state="${test_root}/run/zapret-watchdog.state"

run_watchdog()
{
    printf 'ZAPRET_ENABLED="1"\nWATCHDOG_DOMAINS="%s"\n' "$1" \
        > "${test_root}/zapret/zapret.conf"
    ZAPRET_DIR="${test_root}/zapret" \
    WATCHDOG_STATE_DIR="${test_root}/run" \
    CURL="${CURL_BIN:-${bin_dir}/curl}" \
    CURL_LOG="${test_root}/curl.log" \
    CONFIGCTL="${bin_dir}/configctl" \
    LOGGER="${bin_dir}/logger" \
        /bin/sh "${script}"
}

fail()
{
    echo "FAIL: $*" >&2
    exit 1
}

# A rate-limited target (HTTP 429) still proves the bypass works.
run_watchdog "ratelimited.test"
[ ! -f "${state}" ] || fail "HTTP 429 counted as a failure"

# One answering domain is enough; the list is tried in order.
: > "${test_root}/curl.log"
run_watchdog "down.test,ok.test,never.test"
[ ! -f "${state}" ] || fail "second domain answered but a failure was counted"
[ "$(cat "${test_root}/curl.log")" = "$(printf 'https://down.test\nhttps://ok.test')" ] \
    || fail "unexpected probe order: $(cat "${test_root}/curl.log")"

# Empty setting falls back to example.com.
: > "${test_root}/curl.log"
run_watchdog ""
[ "$(head -1 "${test_root}/curl.log")" = "https://example.com" ] \
    || fail "empty setting did not fall back to example.com"
rm -f "${state}"

# Three consecutive failures stop the service, and only then.
run_watchdog "down.test"
run_watchdog "down.test"
[ "$(cat "${state}")" = "2" ] || fail "failure counter not incremented"
[ ! -f "${test_root}/configctl.log" ] || fail "stopped before the third failure"
run_watchdog "down.test"
[ "$(cat "${test_root}/configctl.log")" = "zapret stop" ] || fail "service not stopped after 3 failures"
[ ! -f "${state}" ] || fail "counter not reset after the trip"

# Issue #14: a target that accepts TCP but never finishes the TLS handshake
# must not hang the probe. Real curl against a local tarpit.
python3 -c '
import socket, sys, time
s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen(4)
print(s.getsockname()[1], flush=True)
conns = []
while True:
    conns.append(s.accept())
' > "${test_root}/tarpit.port" &
tarpit_pid=$!
while [ ! -s "${test_root}/tarpit.port" ]; do sleep 0.1; done
port=$(cat "${test_root}/tarpit.port")
printf 'CONTROL_URL="https://127.0.0.1:%s"\nCONTROL_TIMEOUT=2\n' "${port}" \
    > "${test_root}/zapret/watchdog.conf"
start=$(date +%s)
CURL_BIN=$(command -v curl) run_watchdog "ignored.test"
elapsed=$(( $(date +%s) - start ))
[ "${elapsed}" -le 4 ] || fail "stalled TLS handshake held the probe for ${elapsed}s"
[ "$(cat "${state}")" = "1" ] || fail "stalled handshake was not counted as a failure"

echo "watchdog_test: OK"
