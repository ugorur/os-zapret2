#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
wrapper="${repo_root}/src/opnsense/scripts/OPNsense/Zapret/blockcheck.sh"
controller="${repo_root}/src/opnsense/scripts/OPNsense/Zapret/blockcheck_job.sh"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/blockcheck-process.XXXXXX")
test_pid=""

cleanup_test()
{
    if [ -n "${test_pid}" ]; then
        kill "${test_pid}" 2>/dev/null || true
        wait "${test_pid}" 2>/dev/null || true
    fi
    rm -rf "${test_root}"
}
trap cleanup_test EXIT INT TERM HUP

helpers=$(sed -n '/^process_matches()/,/^# cleanup()/p' "${wrapper}")
eval "${helpers}"

printf '#!/bin/sh\nwhile :; do sleep 1; done\n' > "${test_root}/dvtws2"
chmod +x "${test_root}/dvtws2"
"${test_root}/dvtws2" &
test_pid=$!
printf '%s\n' "${test_pid}" > "${test_root}/child.pid"

read_managed_pid "${test_root}/child.pid" dvtws2
test "${CHECKED_PID}" = "${test_pid}"

if read_managed_pid "${test_root}/child.pid" unexpected-marker; then
    echo 'wrong process marker was accepted' >&2
    exit 1
else
    test "$?" -eq 2
fi

ZAPRET_CHILD_PID="${test_pid}"
ZAPRET_SUPERVISOR_PID=""
zapret_processes_running

kill "${test_pid}"
wait "${test_pid}" 2>/dev/null || true
test_pid=""
if read_managed_pid "${test_root}/child.pid" dvtws2; then
    echo 'dead managed process was accepted' >&2
    exit 1
else
    test "$?" -eq 1
fi

printf '%s\n' \
    'rawsend_sendto_divert: sendto (648): Permission denied' \
    'rawsend: sendto_divert: Permission denied' \
    > "${test_root}/rawsend-denied.log"
blockcheck_packet_io_denied "${test_root}/rawsend-denied.log"

printf '%s\n' 'reinject sendto: Operation not permitted' \
    > "${test_root}/reinject-denied.log"
blockcheck_packet_io_denied "${test_root}/reinject-denied.log"

printf '%s\n' \
    'ping: sendto: Permission denied' \
    'curl: (28) Connection timed out after 2000 milliseconds' \
    > "${test_root}/dns-warning.log"
if blockcheck_packet_io_denied "${test_root}/dns-warning.log"; then
    echo 'public DNS warning was misclassified as dvtws2 packet I/O failure' >&2
    exit 1
fi

sed 's#^JQ=.*#JQ="/nonexistent/jq"#' "${wrapper}" > "${test_root}/wrapper-no-jq.sh"
response=$(/bin/sh "${test_root}/wrapper-no-jq.sh")
printf '%s\n' "${response}" | grep -qF '"status":"error"'
printf '%s\n' "${response}" | grep -qF 'jq is not installed'

sed 's#^JQ=.*#JQ="/nonexistent/jq"#' "${controller}" > "${test_root}/controller-no-jq.sh"
response=$(/bin/sh "${test_root}/controller-no-jq.sh" status)
printf '%s\n' "${response}" | grep -qF '"status":"error"'
printf '%s\n' "${response}" | grep -qF 'jq is not installed'

echo 'blockcheck process tests: ok'
