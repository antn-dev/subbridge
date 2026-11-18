#!/bin/sh
# Sign dist/SHA256SUMS with the release key.
#
# The installer trusts SHA256SUMS only when this signature verifies, so the key
# has to be applied before the files are published to the mirrors.
#
# Key location (never committed):
#   ~/.subbridge-signing/subbridge.sec   secret key
#   ~/.subbridge-signing/subbridge.pub   public key
#
# usign ships in OpenWrt base images, not on macOS. To run it in a container,
# mount the tree and pass a command that keeps paths relative:
#   SUBBRIDGE_USIGN_CMD="docker run --rm -v $PWD:/w -w /w openwrt-25.12-rootfs:latest usign" \
#     ./scripts/sign.sh
# In that mode the key directory must also live under the current directory,
# for example ~/.subbridge-signing copied to ./.keys (excluded from git).
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DIST="${SUBBRIDGE_DIST:-$ROOT/dist}"
KEYDIR="${SUBBRIDGE_KEYDIR:-$HOME/.subbridge-signing}"
USIGN="${SUBBRIDGE_USIGN_CMD:-usign}"

[ -f "$DIST/SHA256SUMS" ] || { echo "dist/SHA256SUMS is missing; build first" >&2; exit 1; }
[ -f "$KEYDIR/subbridge.sec" ] || { echo "secret key not found: $KEYDIR/subbridge.sec" >&2; exit 1; }
[ -f "$KEYDIR/subbridge.pub" ] || { echo "public key not found: $KEYDIR/subbridge.pub" >&2; exit 1; }

# Work with paths relative to one directory so a containerised usign can see
# them. usign writes the signature next to the message by default.
cd "$DIST"

distance() {
	# Relative path from $PWD (== $DIST) to an absolute path. Only the common
	# case of a sibling or nested directory is handled; anything else is
	# returned unchanged, which works for a native usign.
	case "$1" in
	"$PWD"/*) printf '%s' "${1#"$PWD"/}"; return ;;
	esac

	parent=$(CDPATH= cd -- "$PWD/.." && pwd)
	case "$1" in
	"$parent"/*) printf '../%s' "${1#"$parent"/}"; return ;;
	esac

	printf '%s' "$1"
}

SEC=$(distance "$KEYDIR/subbridge.sec")
PUB=$(distance "$KEYDIR/subbridge.pub")

$USIGN -S -s "$SEC" -m SHA256SUMS -x SHA256SUMS.sig

# The public key is published so the key inside install.sh can be compared
# out-of-band rather than trusted because it arrived from the same host.
cp "$PUB" SHA256SUMS.pub

# A signature that does not verify is worse than no signature: refuse to finish.
if ! $USIGN -V -q -p SHA256SUMS.pub -m SHA256SUMS -x SHA256SUMS.sig; then
	echo "signature verification failed" >&2
	exit 1
fi

echo "signed: $DIST/SHA256SUMS.sig"
echo "key: $(tail -1 SHA256SUMS.pub)"
