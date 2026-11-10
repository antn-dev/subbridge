#!/bin/sh
# Single stop path for a background subscription check.
#
# Used by the procd init script (package upgrade/removal) and by the rpcd
# backend (LuCI stop/restart). A PID is signalled only when /proc/PID/cmdline
# still identifies the SubBridge check process, so a recycled PID cannot hurt
# an unrelated program.

STATE_DIR=/tmp/subbridge
PID_FILE=$STATE_DIR/check.pid
LOCK_DIR=/tmp/subbridge-check.lock
LOCK_PID=$LOCK_DIR/pid

is_check_pid() {
	pid="$1"
	[ -n "$pid" ] || return 1
	[ -d "/proc/$pid" ] || return 1
	cmd=$(tr '\000' ' ' <"/proc/$pid/cmdline" 2>/dev/null) || return 1
	case "$cmd" in
	*"/usr/lib/subbridge/main.uc"*" check"*) return 0 ;;
	esac
	return 1
}

check_pid() {
	for file in "$LOCK_PID" "$PID_FILE"; do
		[ -s "$file" ] || continue
		pid=$(cat "$file" 2>/dev/null) || continue
		case "$pid" in
		''|*[!0-9]*) continue ;;
		esac
		if is_check_pid "$pid"; then
			printf '%s\n' "$pid"
			return 0
		fi
	done
	return 1
}

pid=$(check_pid) || pid=
if [ -n "$pid" ]; then
	kill -TERM "$pid" 2>/dev/null
	i=0
	while [ "$i" -lt 3 ] && kill -0 "$pid" 2>/dev/null; do
		sleep 1
		i=$((i + 1))
	done
	kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
fi

# A TERM can leave the temporary sing-box behind.
for pattern in '[s]ing-box run -c /tmp/subbridge-check-' '[s]ing-box check -c /tmp/subbridge-probe-'; do
	pgrep -f "$pattern" 2>/dev/null | while read -r p; do
		kill -TERM "$p" 2>/dev/null
	done
done

rm -f "$PID_FILE" "$LOCK_PID" 2>/dev/null

# Never drop the lock while a check still runs: that would allow a second one.
if ! pgrep -f '[s]ubbridge/main.uc check' >/dev/null 2>&1; then
	rmdir "$LOCK_DIR" 2>/dev/null
fi

exit 0
