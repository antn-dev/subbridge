#!/bin/sh
# Build dist/subbridge_<version>-r<release>_all.apk for OpenWrt 25.12+ (apk-tools v3).
#
# The package is architecture-independent: it contains ucode sources, a shell
# wrapper, LuCI JS, the rpcd backend and UCI defaults. No compiler is needed.
#
# apk mkpkg is a host tool. Use either the host binary from an OpenWrt 25.12 SDK
#   APK_TOOL=/path/to/sdk/staging_dir/host/bin/apk ./scripts/build-apk.sh
# or any apk-tools 3 host build in PATH. The script refuses apk-tools v2.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VERSION=$(cat "$ROOT/VERSION")
RELEASE=${RELEASE:-1}
APK_TOOL=${APK_TOOL:-apk}

DIST="$ROOT/dist"
NAME="subbridge_${VERSION}-r${RELEASE}_all.apk"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/subbridge-apk.XXXXXX")
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

DATA="$WORK/root"
SCRIPTS="$WORK/scripts"
mkdir -p "$DATA" "$SCRIPTS" "$DIST"

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
install_file "$ROOT/package/files/usr/lib/subbridge/stop.sh" /usr/lib/subbridge/stop.sh 0755
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

# --- apk package index ------------------------------------------------------
#
# OpenWrt's include/package-pack.mk keeps these three files in the package
# itself.  The .list is generated before the metadata files are created, so it
# does not list itself.  default_prerm uses .list to find /etc/init.d scripts.

PKGDIR="$DATA/lib/apk/packages"
mkdir -p "$PKGDIR"

(
	cd "$DATA"
	find . \( -type f -o -type l \) -print | sed 's|^\./|/|' | sort
) >"$PKGDIR/subbridge.list"

printf '/etc/config/subbridge\n' >"$PKGDIR/subbridge.conffiles"

sha256_file() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{ print $1 }'
	else
		shasum -a 256 "$1" | awk '{ print $1 }'
	fi
}

printf '/etc/config/subbridge %s\n' "$(sha256_file "$DATA/etc/config/subbridge")" \
	>"$PKGDIR/subbridge.conffiles_static"

# --- maintainer scripts -----------------------------------------------------
#
# apk-tools has no opkg-style postinst/prerm; it calls the scripts below.  The
# bodies come from package/control so the opkg and apk packages behave the same
# way: default_postinst/default_prerm handle the procd service, the package
# scripts add the SubBridge-specific steps.

strip_shebang() {
	sed '1{/^#!/d;}' "$1"
}

{
	printf '#!/bin/sh\n'
	printf '[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0\n'
	printf '[ -s "${IPKG_INSTROOT}/lib/functions.sh" ] || exit 0\n'
	printf '. ${IPKG_INSTROOT}/lib/functions.sh\n'
	printf 'export root="${IPKG_INSTROOT}"\n'
	printf 'export pkgname="subbridge"\n'
	printf 'add_group_and_user\n'
	printf 'default_postinst\n'
	strip_shebang "$ROOT/package/control/postinst"
} >"$SCRIPTS/post-install"

{
	printf '#!/bin/sh\n'
	printf 'export PKG_UPGRADE=1\n'
	tail -n +2 "$SCRIPTS/post-install"
} >"$SCRIPTS/post-upgrade"

# package/control/prerm only stops the service through default_prerm, so the
# apk script calls it directly instead of running it twice.
{
	printf '#!/bin/sh\n'
	printf '[ -s "${IPKG_INSTROOT}/lib/functions.sh" ] || exit 0\n'
	printf '. ${IPKG_INSTROOT}/lib/functions.sh\n'
	printf 'export root="${IPKG_INSTROOT}"\n'
	printf 'export pkgname="subbridge"\n'
	printf 'default_prerm\n'
	printf 'exit 0\n'
} >"$SCRIPTS/pre-deinstall"

{
	printf '#!/bin/sh\n'
	strip_shebang "$ROOT/package/control/postrm"
} >"$SCRIPTS/post-deinstall"

chmod 0755 "$SCRIPTS/post-install" "$SCRIPTS/post-upgrade" \
	"$SCRIPTS/pre-deinstall" "$SCRIPTS/post-deinstall"

# --- archive ----------------------------------------------------------------

# OpenWrt 25.12 ships apk-tools 3.  apk-tools 2 cannot create v3 packages.
case "$("$APK_TOOL" --version 2>&1 | head -1)" in
apk-tools\ 3.*) ;;
*)
	echo "error: $APK_TOOL is not apk-tools 3; set APK_TOOL to the OpenWrt 25.12 host apk" >&2
	exit 1
	;;
esac

SOURCE_DATE_EPOCH=0 "$APK_TOOL" mkpkg \
	--info "name:subbridge" \
	--info "version:${VERSION}-r${RELEASE}" \
	--info "arch:noarch" \
	--info "license:Apache-2.0" \
	--info "origin:subbridge" \
	--info "url:https://github.com/antn-dev/subbridge" \
	--info "maintainer:SubBridge contributors" \
	--info "description:Compact subscription checker for OpenWrt, written in ucode. Downloads a provider subscription with the expected client headers, resolves handoff pages, parses JSON profiles or vless:// links and measures every endpoint through the installed sing-box. It starts a temporary sing-box with only outbounds and the Clash API and never touches routing, DNS, nftables or an existing Podkop/Forkop service." \
	--info "tags:openwrt:section=net" \
	--info "depends:ucode ucode-mod-fs ucode-mod-socket ucode-mod-uci ucode-mod-ubus uclient-fetch luci-base ca-bundle" \
	--info "replaces:luci-app-subbridge" \
	--script "post-install:$SCRIPTS/post-install" \
	--script "post-upgrade:$SCRIPTS/post-upgrade" \
	--script "pre-deinstall:$SCRIPTS/pre-deinstall" \
	--script "post-deinstall:$SCRIPTS/post-deinstall" \
	--files "$DATA" \
	--output "$DIST/$NAME"

echo "built: dist/$NAME"
