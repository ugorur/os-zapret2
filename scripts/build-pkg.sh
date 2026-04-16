#!/bin/sh
# build-pkg.sh — build a proper FreeBSD .pkg for os-zapret2.
#
# Runs on FreeBSD (where pkg-static is available). In CI this is invoked
# inside a FreeBSD VM (vmactions/freebsd-vm). Local FreeBSD devs can run
# it directly; local non-FreeBSD devs can invoke via the same action.
#
# Output: os-zapret2-<version>.pkg in the repo root.

set -eu

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "${REPO_ROOT}"

# --- 1. Parse Makefile metadata ----------------------------------------------

get_var() {
    sed -n "s/^${1}=[[:space:]]*\(.*\)$/\1/p" Makefile | head -1 | sed 's/[[:space:]]*$//'
}

PLUGIN_NAME=$(get_var PLUGIN_NAME)
PLUGIN_VERSION=$(get_var PLUGIN_VERSION)
PLUGIN_REVISION=$(get_var PLUGIN_REVISION)
PLUGIN_COMMENT=$(get_var PLUGIN_COMMENT)
PLUGIN_MAINTAINER=$(get_var PLUGIN_MAINTAINER)
PLUGIN_DEPENDS=$(get_var PLUGIN_DEPENDS)
PLUGIN_LICENSE=$(get_var PLUGIN_LICENSE)

PKG_NAME="os-${PLUGIN_NAME}"
if [ -n "${PLUGIN_REVISION}" ] && [ "${PLUGIN_REVISION}" != "0" ]; then
    FULL_VERSION="${PLUGIN_VERSION}_${PLUGIN_REVISION}"
else
    FULL_VERSION="${PLUGIN_VERSION}"
fi

echo "==> Building ${PKG_NAME}-${FULL_VERSION}"

# --- 2. Stage files -----------------------------------------------------------

STAGE="${REPO_ROOT}/work/stage"
rm -rf "${REPO_ROOT}/work"
mkdir -p "${STAGE}/usr/local"

cp -R src/opnsense "${STAGE}/usr/local/opnsense"
if [ -d src/etc ]; then
    cp -R src/etc "${STAGE}/usr/local/etc"
fi

# Enforce executable bits (tar on macOS/Linux may not preserve them perfectly)
find "${STAGE}" -name "*.sh" -type f -exec chmod 755 {} +
find "${STAGE}" -name "zapret" -path "*/rc.d/*" -type f -exec chmod 755 {} +
if [ -d "${STAGE}/usr/local/etc/rc.syshook.d" ]; then
    find "${STAGE}/usr/local/etc/rc.syshook.d" -type f -exec chmod 755 {} +
fi

# --- 3. Generate plist (one file per line, absolute paths) --------------------

PLIST="${REPO_ROOT}/work/pkg-plist"
(cd "${STAGE}" && find usr -type f -o -type l) | sed 's|^|/|' | sort > "${PLIST}"

if [ ! -s "${PLIST}" ]; then
    echo "ERROR: empty plist — nothing was staged" >&2
    exit 1
fi

echo "==> plist: $(wc -l < "${PLIST}" | tr -d ' ') entries"

# --- 4. Generate +MANIFEST with inline lifecycle scripts ----------------------

# Read pkg-descr and escape for JSON. `jq -Rs .` reads raw input and emits
# it as a quoted JSON string with escapes.
DESC_JSON=$(jq -Rs . < pkg-descr)

POST_INSTALL_JSON=$(jq -Rs . < pkg/+POST_INSTALL)
PRE_DEINSTALL_JSON=$(jq -Rs . < pkg/+PRE_DEINSTALL)
POST_DEINSTALL_JSON=$(jq -Rs . < pkg/+POST_DEINSTALL)

# Dependency list — PLUGIN_DEPENDS is space-separated. Each entry is
# mapped to its FreeBSD ports origin and emitted as a JSON object that
# pkg-static can resolve at install time.
dep_origin() {
    case "$1" in
        luajit) echo "lang/luajit" ;;
        jq)     echo "textproc/jq" ;;
        git)    echo "devel/git" ;;
        *)      echo "$1" ;;  # best-effort; pkg will fail loudly if wrong
    esac
}

DEPS_ENTRIES=""
for dep in ${PLUGIN_DEPENDS}; do
    [ -z "${dep}" ] && continue
    origin=$(dep_origin "${dep}")
    if [ -n "${DEPS_ENTRIES}" ]; then
        DEPS_ENTRIES="${DEPS_ENTRIES},"
    fi
    DEPS_ENTRIES="${DEPS_ENTRIES}\"${dep}\":{\"origin\":\"${origin}\",\"version\":\"0\"}"
done
DEPS="{${DEPS_ENTRIES}}"
echo "==> deps: ${DEPS}"

MANIFEST="${REPO_ROOT}/work/+MANIFEST"
jq -n \
    --arg name "${PKG_NAME}" \
    --arg version "${FULL_VERSION}" \
    --arg origin "opnsense/${PKG_NAME}" \
    --arg comment "${PLUGIN_COMMENT}" \
    --arg maintainer "${PLUGIN_MAINTAINER}" \
    --arg www "https://github.com/ugorur/os-zapret2" \
    --arg license "${PLUGIN_LICENSE}" \
    --argjson desc "${DESC_JSON}" \
    --argjson deps "${DEPS}" \
    --argjson post_install "${POST_INSTALL_JSON}" \
    --argjson pre_deinstall "${PRE_DEINSTALL_JSON}" \
    --argjson post_deinstall "${POST_DEINSTALL_JSON}" \
    '{
        name: $name,
        version: $version,
        origin: $origin,
        comment: $comment,
        maintainer: $maintainer,
        www: $www,
        prefix: "/usr/local",
        desc: $desc,
        categories: ["opnsense", "security"],
        licenselogic: "single",
        licenses: [$license],
        deps: $deps,
        scripts: {
            "post-install": $post_install,
            "pre-deinstall": $pre_deinstall,
            "post-deinstall": $post_deinstall
        }
    }' > "${MANIFEST}"

echo "==> +MANIFEST written to ${MANIFEST}"

# --- 5. Hand off to pkg-static create -----------------------------------------

OUT="${REPO_ROOT}/dist"
rm -rf "${OUT}"
mkdir -p "${OUT}"

# pkg-static fills in files{} (with hashes), flatsize, abi, arch itself,
# merging our partial +MANIFEST.
pkg-static create \
    -M "${MANIFEST}" \
    -p "${PLIST}" \
    -r "${STAGE}" \
    -o "${OUT}"

echo "==> built:"
ls -lh "${OUT}"/*.pkg
