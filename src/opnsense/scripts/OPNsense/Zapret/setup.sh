#!/bin/sh

# setup.sh — Download and compile zapret2 for OPNsense/FreeBSD
# Run once after plugin installation or to update zapret2.

ZAPRET_DIR="/usr/local/etc/zapret2"
ZAPRET_REPO="https://github.com/bol-van/zapret2.git"

set -e

echo "=== zapret2 setup ==="

# Install build + runtime dependencies if missing.
# These come from FreeBSD's main pkg repo (not OPNsense's). OPNsense ships
# with that repo *disabled* by default via an override at
# /usr/local/etc/pkg/repos/FreeBSD.conf containing { enabled: no }. We
# enable it here for the duration of the install if it's currently off.
FREEBSD_REPO_OVERRIDE=/usr/local/etc/pkg/repos/FreeBSD.conf
ENABLED_FREEBSD_REPO=0
if [ -f "${FREEBSD_REPO_OVERRIDE}" ] && grep -q 'enabled: no' "${FREEBSD_REPO_OVERRIDE}"; then
    echo "Temporarily enabling FreeBSD pkg repo to fetch luajit/jq/git-lite/pkgconf..."
    cp "${FREEBSD_REPO_OVERRIDE}" "${FREEBSD_REPO_OVERRIDE}.bak"
    cat > "${FREEBSD_REPO_OVERRIDE}" <<'EOF'
FreeBSD: { enabled: yes }
FreeBSD-kmods: { enabled: yes }
EOF
    ENABLED_FREEBSD_REPO=1
fi

# Refresh package catalogues (fast no-op if already up to date)
pkg update -q -f

pkg info -q pkgconf  || pkg install -y pkgconf
pkg info -q luajit   || pkg install -y luajit
pkg info -q git-lite || pkg install -y git-lite

# jq is required at runtime by zapret_service.sh to parse pluginctl JSON
# when resolving the WAN interface name.
pkg info -q jq       || pkg install -y jq

# Restore the original repo state if we changed it. The packages we just
# installed remain — pkg upgrades can be controlled separately.
if [ "${ENABLED_FREEBSD_REPO}" = "1" ] && [ -f "${FREEBSD_REPO_OVERRIDE}.bak" ]; then
    mv "${FREEBSD_REPO_OVERRIDE}.bak" "${FREEBSD_REPO_OVERRIDE}"
fi

# Clone or update zapret2
if [ -d "${ZAPRET_DIR}/.git" ]; then
    echo "Updating existing zapret2 installation..."
    cd "${ZAPRET_DIR}"
    git pull --ff-only
else
    echo "Cloning zapret2..."
    rm -rf "${ZAPRET_DIR}"
    git clone --depth 1 "${ZAPRET_REPO}" "${ZAPRET_DIR}"
fi

# Compile
echo "Compiling zapret2..."
cd "${ZAPRET_DIR}"
make clean 2>/dev/null || true
make

# Verify binaries
if [ -x "${ZAPRET_DIR}/binaries/my/dvtws2" ]; then
    echo "dvtws2 compiled successfully: ${ZAPRET_DIR}/binaries/my/dvtws2"
else
    echo "ERROR: dvtws2 compilation failed!" >&2
    exit 1
fi

if [ -x "${ZAPRET_DIR}/binaries/my/tpws2" ]; then
    echo "tpws2 compiled successfully: ${ZAPRET_DIR}/binaries/my/tpws2"
fi

# Ensure config directory exists
mkdir -p "${ZAPRET_DIR}"

echo "=== zapret2 setup complete ==="
