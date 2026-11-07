#!/bin/sh
# Run the ucode unit tests. ucode is the OpenWrt interpreter, so on a desktop
# host this must be run inside the router or an OpenWrt SDK container.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

if ! command -v ucode >/dev/null 2>&1; then
	echo "ucode is not installed on this host." >&2
	echo "Run this on the router or in an OpenWrt SDK container:" >&2
	echo "  ucode -L src tests/unit.uc" >&2
	exit 1
fi

exec ucode -L src tests/unit.uc
