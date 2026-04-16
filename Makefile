PLUGIN_NAME=        zapret2
PLUGIN_VERSION=     1.6.2
PLUGIN_REVISION=    0
PLUGIN_COMMENT=     DPI bypass using zapret2 (anti-censorship)
PLUGIN_MAINTAINER=  mail@ugorur.com
# luajit, jq, git-lite, pkgconf are installed by setup.sh from FreeBSD's
# main pkg repo (not OPNsense's). They're not declared here because pkg-add
# would refuse to install our plugin on a fresh OPNsense where those ports
# aren't yet present and the FreeBSD repo isn't enabled by default.
PLUGIN_DEPENDS=
PLUGIN_LICENSE=     MIT

.include "../../Mk/plugins.mk"
