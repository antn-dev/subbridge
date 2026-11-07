#!/bin/sh
# Build dist/subbridge_<version>-r<release>_all.ipk from this repository.
#
# The package is architecture-independent: it contains ucode sources, a shell
# wrapper, LuCI JS, the rpcd backend and UCI defaults. No compiler is needed.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VERSION=$(cat "$ROOT/VERSION")
RELEASE=${RELEASE:-1}
EPOCH=${SOURCE_DATE_EPOCH:-0}

DIST="$ROOT/dist"
NAME="subbridge_${VERSION}-r${RELEASE}_all.ipk"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/subbridge-build.XXXXXX")
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

DATA="$WORK/data"
CTRL="$WORK/control"
mkdir -p "$DATA" "$CTRL" "$DIST"

# --- ucode implementation ---------------------------------------------------

mkdir -p "$DATA/usr/lib/subbridge"
for file in "$ROOT"/src/*.uc; do
	cp "$file" "$DATA/usr/lib/subbridge/"
	chmod 0644 "$DATA/usr/lib/subbridge/$(basename "$file")"
done

# --- executable and data files ---------------------------------------------

install_file() {
	src="$1"
	dst="$2"
	mode="$3"

	mkdir -p "$DATA$(dirname "$dst")"
	cp "$src" "$DATA$dst"
	chmod "$mode" "$DATA$dst"
}

install_file "$ROOT/package/files/usr/bin/subbridge" /usr/bin/subbridge 0755
install_file "$ROOT/package/files/usr/share/rpcd/ucode/subbridge" /usr/share/rpcd/ucode/subbridge 0644
install_file "$ROOT/package/files/usr/share/rpcd/acl.d/luci-app-subbridge.json" /usr/share/rpcd/acl.d/luci-app-subbridge.json 0644
install_file "$ROOT/package/files/usr/share/luci/menu.d/luci-app-subbridge.json" /usr/share/luci/menu.d/luci-app-subbridge.json 0644
install_file "$ROOT/package/files/www/luci-static/resources/view/subbridge/main.js" /www/luci-static/resources/view/subbridge/main.js 0644
install_file "$ROOT/package/files/etc/init.d/subbridge" /etc/init.d/subbridge 0755
install_file "$ROOT/package/files/etc/uci-defaults/90_luci-app-subbridge" /etc/uci-defaults/90_luci-app-subbridge 0755
install_file "$ROOT/package/files/etc/config/subbridge" /etc/config/subbridge 0600
install_file "$ROOT/LICENSE" /usr/share/licenses/subbridge/LICENSE 0644

# The version file is generated from VERSION so it can never drift from the
# package metadata.
mkdir -p "$DATA/usr/share/subbridge"
printf '%s\n' "$VERSION" >"$DATA/usr/share/subbridge/version"
chmod 0644 "$DATA/usr/share/subbridge/version"

# --- control ---------------------------------------------------------------

cp "$ROOT/package/control/prerm" "$CTRL/prerm"
cp "$ROOT/package/control/postinst" "$CTRL/postinst"
cp "$ROOT/package/control/postrm" "$CTRL/postrm"
chmod 0755 "$CTRL/prerm" "$CTRL/postinst" "$CTRL/postrm"

printf '/etc/config/subbridge\n' >"$CTRL/conffiles"

INSTALLED_SIZE=$(du -sk "$DATA" | awk '{ print $1 }')

cat >"$CTRL/control" <<EOF
Package: subbridge
Version: ${VERSION}-r${RELEASE}
Depends: ucode, ucode-mod-fs, ucode-mod-socket, ucode-mod-uci, ucode-mod-ubus, uclient-fetch, luci-base, ca-bundle
Conflicts: luci-app-subbridge
Replaces: luci-app-subbridge
Source: subbridge
SourceName: subbridge
License: Apache-2.0
LicenseFiles: LICENSE
Section: net
Category: Network
Architecture: all
Installed-Size: ${INSTALLED_SIZE}
Maintainer: SubBridge contributors
Description: Compact subscription checker for OpenWrt, written in ucode.
 Downloads a provider subscription with the expected client headers, resolves
 handoff pages, parses JSON profiles or vless:// links and measures every
 endpoint through the installed sing-box. It starts a temporary sing-box with
 only outbounds and the Clash API and never touches routing, DNS, nftables or
 an existing Podkop/Forkop service. Includes a LuCI page and a JSON CLI.
EOF

# --- archive ---------------------------------------------------------------

python3 "$ROOT/scripts/make-ipk.py" "$CTRL" "$DATA" "$DIST/$NAME" "$EPOCH"

echo "built: dist/$NAME"
