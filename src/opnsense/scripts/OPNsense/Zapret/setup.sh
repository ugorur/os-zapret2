#!/bin/sh

# setup.sh — Download and compile zapret2 for OPNsense/FreeBSD
# Run once after plugin installation or to update zapret2.

ZAPRET_DIR="/usr/local/etc/zapret2"
ZAPRET_REPO="https://github.com/bol-van/zapret2.git"

set -e

echo "=== zapret2 setup ==="

# Install build dependencies if missing
pkg info -q pkgconf || pkg install -y pkgconf
pkg info -q luajit || pkg install -y luajit
pkg info -q git-lite || pkg install -y git-lite

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
if [ -x "${ZAPRET_DIR}/nfq/dvtws2" ]; then
    echo "dvtws2 compiled successfully: ${ZAPRET_DIR}/nfq/dvtws2"
else
    echo "ERROR: dvtws2 compilation failed!" >&2
    exit 1
fi

if [ -x "${ZAPRET_DIR}/nfq/tpws2" ]; then
    echo "tpws2 compiled successfully: ${ZAPRET_DIR}/nfq/tpws2"
fi

# Ensure config directory exists
mkdir -p "${ZAPRET_DIR}"

echo "=== zapret2 setup complete ==="
