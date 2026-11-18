#!/bin/sh
# Build both packages, refresh the "latest" aliases and write SHA256SUMS.
#
# The installer fetches subbridge_latest_all.ipk / .apk, so the aliases have to
# point at the current build. SHA256SUMS is written last: a checksum that
# disagrees with the file it names makes the installer refuse the package.
#
# Signing is a separate step (scripts/sign.sh) because it needs the secret key,
# which is kept outside the repository.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DIST="$ROOT/dist"
VERSION=$(cat "$ROOT/VERSION")
RELEASE=${RELEASE:-1}

IPK="subbridge_${VERSION}-r${RELEASE}_all.ipk"
APK="subbridge_${VERSION}-r${RELEASE}_all.apk"

mkdir -p "$DIST"

sh "$ROOT/scripts/build.sh"

# apk mkpkg is a host tool that ships with OpenWrt 25.12 / apk-tools 3.
APK_TOOL=${APK_TOOL:-apk}
if "$APK_TOOL" --version 2>/dev/null | grep -q '^apk-tools 3\.'; then
	APK_TOOL="$APK_TOOL" sh "$ROOT/scripts/build-apk.sh"
else
	echo "skipping the apk: set APK_TOOL to an apk-tools 3 binary" >&2
fi

[ -f "$DIST/$IPK" ] || { echo "missing $DIST/$IPK" >&2; exit 1; }

cp "$DIST/$IPK" "$DIST/subbridge_latest_all.ipk"
chmod 0644 "$DIST/subbridge_latest_all.ipk"

# Only publish an apk alias that belongs to this build. The versioned file name
# already pins the version, so an existing one is safe to reuse; an alias from
# a previous build is not.
if [ -f "$DIST/$APK" ]; then
	cp "$DIST/$APK" "$DIST/subbridge_latest_all.apk"
	chmod 0644 "$DIST/subbridge_latest_all.apk"
else
	rm -f "$DIST/subbridge_latest_all.apk"
fi

# A stale signature would describe the previous SHA256SUMS, so it is removed
# here and created again by scripts/sign.sh.
rm -f "$DIST/SHA256SUMS" "$DIST/SHA256SUMS.sig" "$DIST/SHA256SUMS.pub"

cd "$DIST"

sums() {
	for name in "$@"; do
		if command -v sha256sum >/dev/null 2>&1; then
			sha256sum "$name"
		else
			shasum -a 256 "$name"
		fi
	done
}

# Both names go in: the installer asks for subbridge_latest_all.*, while a
# pinned download (or a mirror script) uses the versioned file. They point at
# the same bytes, so each pair carries the same hash.
files="$IPK subbridge_latest_all.ipk"
[ -f subbridge_latest_all.apk ] && files="$files $APK subbridge_latest_all.apk"

sums $files >SHA256SUMS

echo "dist: $VERSION-r$RELEASE"
cat SHA256SUMS
