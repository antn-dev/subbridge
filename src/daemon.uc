// Background daemon for the procd service.
//
// Checks are started explicitly from LuCI or the command line, so this daemon
// has no scheduled work. It exists so the service is real: the page power and
// restart buttons control procd, and the process stays alive until it is
// stopped.
//
// The daemon never starts a check on its own, so boot and restart do not
// generate surprise traffic.

const TICK_SECONDS = 60;

function run() {
	warn("SubBridge daemon started\n");

	// ucode's sleep() takes milliseconds; passing 60 here would busy-loop at
	// roughly 16 wakeups per second and waste CPU on the router.
	while (true)
		sleep(TICK_SECONDS * 1000);
}

return {
	run
};
