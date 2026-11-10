#!/bin/sh
# Integration test for the shared stop script and the check lock.
#
# Must run as root on Linux (it reads /proc and writes to /tmp):
#   docker run --rm -v "$PWD":/work -w /work \
#       openwrt-25.12-rootfs:latest sh tests/stop.sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LIB=/usr/lib/subbridge

mkdir -p "$LIB"
cp "$ROOT"/src/*.uc "$LIB"/
cp "$ROOT/package/files/usr/lib/subbridge/stop.sh" "$LIB/stop.sh"
chmod 0755 "$LIB/stop.sh"

# check.uc pulls in engine.uc, which imports the socket module. The minimal
# rootfs image used by this test does not ship ucode-mod-socket, and the lock
# tests never call into the engine, so a stub is enough.
STUB=$(mktemp -d)
printf 'return {};\n' >"$STUB/socket.uc"
MODULES="-L $STUB -L $ROOT/src"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok: %s\n' "$*"; }

rm -rf /tmp/subbridge /tmp/subbridge-check.lock

# --- pid/uid helpers -------------------------------------------------------

set -- $(ucode -L "$ROOT/src" -e 'let u = require("util"); printf("%d %d", u.process_id(), u.current_uid())')
[ "$1" -gt 0 ] || fail "process_id returned $1"
[ "$2" -ge 0 ] || fail "current_uid returned $2"
ok "process_id/current_uid"

# --- an unrelated PID must never be signalled ------------------------------

mkdir -p /tmp/subbridge
sleep 60 &
victim=$!
printf '%s\n' "$victim" > /tmp/subbridge/check.pid
"$LIB/stop.sh"
kill -0 "$victim" 2>/dev/null || fail "stop.sh killed an unrelated PID"
kill "$victim" 2>/dev/null || true
wait "$victim" 2>/dev/null || true
[ ! -e /tmp/subbridge/check.pid ] || fail "stale PID file was not removed"
ok "unrelated PID survives"

# --- a verified check is stopped and the lock is released ------------------

cat >"$LIB/main.uc" <<'EOF'
#!/usr/bin/ucode
sleep(60000);
EOF

ucode -L "$LIB" "$LIB/main.uc" check &
checkpid=$!
sleep 1
printf '%s\n' "$checkpid" > /tmp/subbridge/check.pid
mkdir -p /tmp/subbridge-check.lock
printf '%s\n' "$checkpid" > /tmp/subbridge-check.lock/pid
"$LIB/stop.sh"
sleep 1

if kill -0 "$checkpid" 2>/dev/null; then
	fail "check process survived stop.sh"
fi

[ ! -d /tmp/subbridge-check.lock ] || fail "lock was not removed"
[ ! -e /tmp/subbridge/check.pid ] || fail "PID file was not removed"
ok "verified check is stopped and lock removed"

# --- a stale lock with a dead PID is recoverable ---------------------------

cat >"$LIB/main.uc" <<'EOF'
#!/usr/bin/ucode
let check = require("check");
check.acquire_lock();
check.release_lock();
EOF

mkdir -p /tmp/subbridge-check.lock
printf '999999\n' > /tmp/subbridge-check.lock/pid
ucode $MODULES "$LIB/main.uc" check || fail "stale lock was not recovered"
[ ! -d /tmp/subbridge-check.lock ] || fail "stale lock left behind"
ok "stale lock recovered"

# --- a live unrelated PID in the lock must not block a new check -----------

sleep 60 &
victim=$!
mkdir -p /tmp/subbridge-check.lock
printf '%s\n' "$victim" > /tmp/subbridge-check.lock/pid
ucode $MODULES "$LIB/main.uc" check || fail "unrelated lock PID blocked acquire"
[ ! -d /tmp/subbridge-check.lock ] || fail "lock was not released"
kill "$victim" 2>/dev/null || true
wait "$victim" 2>/dev/null || true
ok "unrelated lock PID ignored"

rm -rf /tmp/subbridge /tmp/subbridge-check.lock "$STUB"
ok "all stop/lock tests passed"
