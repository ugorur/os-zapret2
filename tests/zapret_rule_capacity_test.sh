#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
service="${repo_root}/src/opnsense/scripts/OPNsense/Zapret/zapret_service.sh"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/zapret-rule-capacity.XXXXXX")
ipfw_log="${test_root}/ipfw.log"
fake_ipfw="${test_root}/ipfw"

cleanup()
{
    rm -rf "${test_root}"
}
trap cleanup EXIT INT TERM HUP

cat > "${fake_ipfw}" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "${ipfw_log}"
exit 0
EOF
chmod +x "${fake_ipfw}"

RULE_BASE=19000
RULE_MAX=19010
helpers=$(sed -n '/^validate_ipfw_rule_capacity()/,/^start_service()/p' \
    "${service}" | sed '$d' | sed "s#/sbin/ipfw#${fake_ipfw}#g")
eval "${helpers}"

# install_ipfw_rules() calls the real cleanup helper before adding anything.
# The fake ipfw log starts empty, so no cleanup is needed in this test.
remove_ipfw_rules()
{
    :
}

SOURCE_NETS=""
DIVERT_PORT=989

PORTS="1,2,3,4,5,6,7,8,9,10"
QUIC_ARGS=""
validate_ipfw_rule_capacity

PORTS="1,2,3,4,5,6,7,8,9"
QUIC_ARGS="--payload=quic_initial"
install_ipfw_rules igc0

test "$(grep -c ' add ' "${ipfw_log}")" -eq 13
grep -qF 'add 19009 divert 989 udp' "${ipfw_log}"
for flags in syn,ack fin rst; do
    grep -qF "add 19010 divert 989 tcp from any 1,2,3,4,5,6,7,8,9 to any tcpflags ${flags} out recv igc0 not diverted" "${ipfw_log}"
done

: > "${ipfw_log}"
SOURCE_NETS="10.0.30.0/24,10.0.40.0/24"
PORTS="80,443"
QUIC_ARGS=""
install_ipfw_rules igc0
grep -qF 'add 19002 divert 989 tcp from any 80,443 to 10.0.30.0/24,10.0.40.0/24 tcpflags rst out recv igc0 not diverted' "${ipfw_log}"
SOURCE_NETS=""

: > "${ipfw_log}"
PORTS="1,2,3,4,5,6,7,8,9,10"
QUIC_ARGS="--payload=quic_initial"
if install_ipfw_rules igc0 2>/dev/null; then
    echo 'TCP plus QUIC layout without room for reply rules was accepted' >&2
    exit 1
fi
test ! -s "${ipfw_log}"

: > "${ipfw_log}"
PORTS="1,2,3,4,5,6,7,8,9,10,11"
QUIC_ARGS="--payload=quic_initial"
if install_ipfw_rules igc0 2>/dev/null; then
    echo 'oversized TCP plus QUIC rule layout was accepted' >&2
    exit 1
fi

test ! -s "${ipfw_log}"

PORTS="1,2,3,4,5,6,7,8,9,10,11"
QUIC_ARGS=""
if validate_ipfw_rule_capacity 2>/dev/null; then
    echo 'oversized TCP rule layout was accepted' >&2
    exit 1
fi

echo 'zapret ipfw rule capacity tests: ok'
