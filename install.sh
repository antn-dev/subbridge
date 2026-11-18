#!/bin/sh
# SubBridge installer for OpenWrt.
#
# One-liner:
#   wget -qO- https://antn-dev.github.io/subbridge/install.sh | sh
#
# The script detects apk (OpenWrt 25.12+) or opkg (24.10) and installs the
# matching package from the first reachable mirror after checking its SHA-256.
#
# Environment overrides:
#   SUBBRIDGE_BASE_URL  use only this download base
#   SUBBRIDGE_ASSET     force one asset name instead of auto-detection
set -eu

# GitHub itself is unreachable from some networks, while its Pages/CDN
# endpoints are not. Try the known mirrors in order; SHA256SUMS is fetched
# first, so a blocked host is skipped after a short timeout.
DEFAULT_BASES="
https://antn-dev.github.io/subbridge
https://cdn.jsdelivr.net/gh/antn-dev/subbridge@gh-pages
https://raw.githack.com/antn-dev/subbridge/gh-pages
https://github.com/antn-dev/subbridge/releases/latest/download
"

if [ -n "${SUBBRIDGE_BASE_URL:-}" ]; then
	BASES="$SUBBRIDGE_BASE_URL"
else
	BASES="$DEFAULT_BASES"
fi

log() { printf '%s\n' "$*"; }
die() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "запустите установщик от root"

if [ -n "${SUBBRIDGE_ASSET:-}" ]; then
	ASSET="$SUBBRIDGE_ASSET"
elif [ -f /etc/opkg.conf ] && command -v opkg >/dev/null 2>&1; then
	ASSET="subbridge_latest_all.ipk"
elif command -v apk >/dev/null 2>&1; then
	ASSET="subbridge_latest_all.apk"
elif command -v opkg >/dev/null 2>&1; then
	ASSET="subbridge_latest_all.ipk"
else
	die "не найден ни apk, ни opkg — это не OpenWrt 24.10/25.12+"
fi

if command -v uclient-fetch >/dev/null 2>&1; then
	FETCHER="uclient-fetch"
elif command -v curl >/dev/null 2>&1; then
	FETCHER="curl"
elif command -v wget >/dev/null 2>&1; then
	FETCHER="wget"
else
	die "не найден uclient-fetch, curl или wget"
fi

# A blocked mirror must fail quickly instead of hanging the updater forever.
fetch() {
	url="$1"
	out="$2"

	rm -f "$out"

	case "$FETCHER" in
	uclient-fetch)
		uclient-fetch -q -T 15 -O "$out" "$url" && [ -s "$out" ] && return 0
		;;
	curl)
		curl -fsSL --connect-timeout 15 --max-time 180 -o "$out" "$url" &&
			[ -s "$out" ] && return 0
		;;
	wget)
		wget -q -T 15 -O "$out" "$url" && [ -s "$out" ] && return 0
		;;
	esac

	rm -f "$out"
	return 1
}

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{ print $1 }'
	elif command -v sha256 >/dev/null 2>&1; then
		sha256 -q "$1" | awk '{ print $1 }'
	elif command -v openssl >/dev/null 2>&1; then
		openssl dgst -sha256 "$1" | awk '{ print $NF }'
	else
		return 1
	fi
}

tmp="$(mktemp -d /tmp/subbridge-install.XXXXXX)" || die "не удалось создать временный каталог"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

pkg="$tmp/$ASSET"
sums="$tmp/SHA256SUMS"
sig="$tmp/SHA256SUMS.sig"
pub="$tmp/subbridge.pub"

# The public key is embedded here on purpose. SHA256SUMS and the package are
# served from the same mirror, so a checksum alone proves nothing if that
# mirror is compromised; usign verifies that the sums were signed with the
# release key. The key is also in the README for out-of-band comparison.
PUBKEY_BODY="RWT0QqF55t8RovTA18CszEqopajki6Do6snM8GoKiec0DU9S1a7iFOAR"

printf 'untrusted comment: SubBridge release key\n%s\n' "$PUBKEY_BODY" >"$pub"

# usign ships in both 24.10 and 25.12 base systems. When it is missing the
# script says so once and falls back to checksum-only verification, which is
# weaker but still catches a corrupted download.
have_usign=0
if command -v usign >/dev/null 2>&1; then
	have_usign=1
else
	log "SubBridge: usign не найден — подпись не будет проверена"
fi

found=0
for base in $BASES; do
	log "SubBridge: проверяю $base"

	if ! fetch "$base/SHA256SUMS" "$sums"; then
		continue
	fi

	if [ "$have_usign" = "1" ]; then
		if ! fetch "$base/SHA256SUMS.sig" "$sig"; then
			log "SubBridge: нет подписи на $base"
			rm -f "$sums"
			continue
		fi

		if ! usign -V -q -p "$pub" -m "$sums" -x "$sig"; then
			log "SubBridge: подпись не прошла проверку на $base"
			rm -f "$sums" "$sig"
			continue
		fi

		log "SubBridge: подпись OK ($base)"
	fi

	want="$(awk -v name="$ASSET" '$2 == name { print $1; exit }' "$sums")"
	[ -n "$want" ] || continue

	if ! fetch "$base/$ASSET" "$pkg"; then
		continue
	fi

	got="$(sha256_of "$pkg")" || die "не найден sha256sum, sha256 или openssl"
	if [ "$want" = "$got" ]; then
		found=1
		log "SubBridge: sha256 OK ($base)"
		break
	fi

	log "SubBridge: контрольная сумма не совпала на $base"
	rm -f "$pkg" "$sums" "$sig"
done

[ "$found" = "1" ] || die "не удалось скачать $ASSET ни с одного зеркала"

# A stale package list makes the dependency install fail on a fresh router.
if [ "$ASSET" = "subbridge_latest_all.apk" ]; then
	apk update >/dev/null 2>&1 || true
	apk add --allow-untrusted --force-non-repository "$pkg" || die "apk add завершился с ошибкой"
else
	opkg update >/dev/null 2>&1 || true
	opkg install "$pkg" || die "opkg install завершился с ошибкой"
fi

log ""
log "SubBridge установлен: $(subbridge version 2>/dev/null || echo 'версия неизвестна')"
log "Откройте LuCI: Services → SubBridge"
