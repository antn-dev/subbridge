#!/usr/bin/ucode
// SubBridge command line entry point.
//
// The LuCI page uses the same binary through rpcd; there is no second code
// path for the web UI.

let fs = require("fs");
let util = require("util");
let config = require("config");
let check = require("check");
let status = require("status");
let engine = require("engine");
let output = require("output");
let daemon = require("daemon");

const VERSION_FILE = "/usr/share/subbridge/version";
const FALLBACK_VERSION = "0.4.14";

function version() {
	if (getenv("SUBBRIDGE_VERSION") != null && getenv("SUBBRIDGE_VERSION") != "")
		return getenv("SUBBRIDGE_VERSION");

	let value = util.trim(util.read_file(VERSION_FILE));
	return value == "" ? FALLBACK_VERSION : value;
}

function info(cfg) {
	let binary = engine.find(cfg.engine);
	let engine_version = "";

	if (binary != null) {
		let result = util.command_argv([binary, "version"]);
		engine_version = util.first_line(result.output);
	}

	return {
		version: version(),
		engine: {
			path: binary == null ? "" : binary,
			version: engine_version
		},
		enabled: cfg.enabled,
		subscription: cfg.subscription,
		test_url: cfg.test_url,
		timeout_ms: cfg.timeout_ms,
		concurrency: cfg.concurrency,
		hwid_file: cfg.hwid_file,
		status_file: cfg.status_file
	};
}

function main() {
	let args = config.parse_args(ARGV);

	switch (args.command) {
	case "help":
		printf("%s\n", config.USAGE);
		return;

	case "version":
		printf("SubBridge %s\n", version());
		return;

	case "status":
		let status_cfg = config.load(args);
		printf(status_cfg.compact ? "%J\n" : "%.4J\n", status.read(status_cfg.status_file));
		return;

	case "info":
		let info_cfg = config.load(args);
		printf(info_cfg.compact ? "%J\n" : "%.4J\n", info(info_cfg));
		return;

	case "check":
		let cfg = config.load(args);
		check.run(cfg);
		return;

	case "daemon":
		daemon.run();
		return;

	default:
		die("unknown command\n" + config.USAGE);
	}
}

try {
	main();
}
catch (e) {
	warn("SubBridge: " + e + "\n");
	exit(1);
}
