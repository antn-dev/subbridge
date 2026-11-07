#!/bin/sh
# SubBridge installer for OpenWrt.
#
# One-liner:
#   wget -qO- https://github.com/antn-dev/subbridge/releases/latest/download/install.sh | sh
#
# The script detects apk (OpenWrt 25.12+) or opkg (24.10) and installs the
# matching package from the latest GitHub release after checking its SHA-256.
#
# Environment overrides:
#   SUBBRIDGE_BASE_URL  download base, defaults to the latest release assets
#   SUBBRIDGE_ASSET     force one asset name instead of auto-detection
set -eu

REPO="antn-dev/subbridge"
BASE="${SUBBRIDGE_BASE_URL:-https://github.com/$REPO/releases/latest/download}"

log() { printf '%s\n' "$*"; }
die() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "запустите установщик от root"

if [ -n "${SUBBRIDGE_ASSET:-}" ]; then
	ASSET="$SUBBRIDGE_ASSET"
elif command -v apk >/dev/null 2>&1; then
	ASSET="subbridge_latest_all.apk"
elif command -v opkg >/dev/null 2>&1; then
	ASSET="subbridge_latest_all.ipk"
else
	die "не найден ни apk, ни opkg — это не OpenWrt 24.10/25.12+"
fi

fetch() {
	url="$1"
	out="$2"

	if command -v uclient-fetch >/dev/null 2>&1; then
		uclient-fetch -q -O "$out" "$url"
	elif command -v curl >/dev/null 2>&1; then
		curl -fsSL -o "$out" "$url"
	elif command -v wget >/dev/null 2>&1; then
		wget -q -O "$out" "$url"
	else
		return 1
	fi
}

tmp="$(mktemp -d /tmp/subbridge-install.XXXXXX)" || die "не удалось создать временный каталог"
trap 'rm -rf "$tmp"' EXIT INT TERM
pkg="$tmp/$ASSET"

log "SubBridge: скачиваю $ASSET"
fetch "$BASE/$ASSET" "$pkg" || die "не удалось скачать $ASSET"
fetch "$BASE/SHA256SUMS" "$tmp/SHA256SUMS" || die "не удалось скачать SHA256SUMS"

want="$(awk -v name="$ASSET" '$2 == name { print $1; exit }' "$tmp/SHA256SUMS")"
[ -n "$want" ] || die "в SHA256SUMS нет записи для $ASSET"

if command -v sha256sum >/dev/null 2>&1; then
	got="$(sha256sum "$pkg" | awk '{ print $1 }')"
else
	got="$(sha256 -q "$pkg")"
fi
[ "$want" = "$got" ] || die "контрольная сумма не совпала: ожидалось $want, получено $got"
log "SubBridge: sha256 OK"

if [ "$ASSET" = "subbridge_latest_all.apk" ]; then
	apk add --allow-untrusted "$pkg" || die "apk add завершился с ошибкой"
else
	opkg install "$pkg" || die "opkg install завершился с ошибкой"
fi

log ""
log "SubBridge установлен: $(subbridge version 2>/dev/null || echo 'версия неизвестна')"
log "Откройте LuCI: Services → SubBridge"
