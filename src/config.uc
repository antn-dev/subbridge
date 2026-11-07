// Configuration and command line parsing.
//
// The LuCI page stores settings in /etc/config/subbridge. The same values can
// be overridden from the command line, which keeps the CLI usable for scripts
// and for the rpcd background job.

let util = require("util");

const DEFAULTS = {
	test_url: "http://cp.cloudflare.com/generate_204",
	timeout_ms: 3000,
	concurrency: 8,
	hwid_file: "/etc/subbridge/hwid",
	status_file: "/tmp/subbridge/status.json",
	result_file: "/tmp/subbridge/result.json",
	ua_mode: "auto",
	ua_user_agent: "Happ/6.1.0/linux catalyst/2610091518671",
	ua_device_os: "Linux",
	ua_ver_os: "6.6.0",
	ua_app_version: "6.1.0",
	ua_device_model: "Linux PC",
	ua_device_locale: "ru",
	ua_hwid: "",
	engine: ""
};

const USAGE = "Usage: subbridge [check|daemon|status|info|version|help] [options]\n" +
	"  --url URL            subscription address\n" +
	"  --engine PATH        sing-box binary (empty: autodetect)\n" +
	"  --test-url URL       URL fetched through every endpoint\n" +
	"  --timeout MS         per-endpoint timeout (default 3000)\n" +
	"  --workers N          parallel checks (default 8)\n" +
	"  --hwid-file PATH     persistent X-HWID location\n" +
	"  --status-file PATH   progress document for LuCI\n" +
	"  --result-file PATH   write the JSON result to this file\n" +
	"  --json               print the result as JSON\n" +
	"  --compact            keep JSON on one line (for scripts)\n" +
	"  --verbose            print progress in JSON mode too\n" +
	"  --help               show this help";

function uci_get(cursor, name) {
	let value = cursor.get("subbridge", "main", name);
	return value == null ? "" : "" + value;
}

function load_uci() {
	let uci = require("uci");
	let cursor = uci.cursor();

	return {
		enabled: uci_get(cursor, "enabled") == "1" || uci_get(cursor, "enabled") == "",
		subscription: uci_get(cursor, "subscription"),
		engine: uci_get(cursor, "engine"),
		test_url: uci_get(cursor, "test_url"),
		timeout_ms: uci_get(cursor, "timeout_ms"),
		concurrency: uci_get(cursor, "concurrency"),
		hwid_file: uci_get(cursor, "hwid_file"),
		status_file: uci_get(cursor, "status_file"),
		result_file: uci_get(cursor, "result_file"),
		ua_mode: uci_get(cursor, "ua_mode"),
		ua_user_agent: uci_get(cursor, "ua_user_agent"),
		ua_device_os: uci_get(cursor, "ua_device_os"),
		ua_ver_os: uci_get(cursor, "ua_ver_os"),
		ua_app_version: uci_get(cursor, "ua_app_version"),
		ua_device_model: uci_get(cursor, "ua_device_model"),
		ua_device_locale: uci_get(cursor, "ua_device_locale"),
		ua_hwid: uci_get(cursor, "ua_hwid")
	};
}

// split_arg accepts both "--name value" and "--name=value".
function split_arg(arg) {
	let pos = index(arg, "=");
	if (pos < 0)
		return { name: arg, value: null };

	return { name: substr(arg, 0, pos), value: substr(arg, pos + 1) };
}

function parse_args(argv) {
	let args = {
		command: "check",
		json: false,
		compact: false,
		verbose: false,
		overrides: {}
	};

	let values = ARGV;
	let first = true;

	for (let i = 0; i < length(values); i++) {
		let arg = "" + values[i];

		if (first && (arg == "check" || arg == "daemon" || arg == "status" ||
		    arg == "info" || arg == "version" || arg == "help" ||
		    arg == "--help" || arg == "-h")) {
			args.command = arg == "--help" || arg == "-h" ? "help" : arg;
			first = false;
			continue;
		}

		first = false;

		if (arg == "--json") {
			args.json = true;
			continue;
		}

		if (arg == "--compact") {
			args.compact = true;
			continue;
		}

		if (arg == "--verbose") {
			args.verbose = true;
			continue;
		}

		if (substr(arg, 0, 2) != "--")
			die("unknown argument \"" + arg + "\"\n" + USAGE);

		let parsed = split_arg(arg);
		let name = substr(parsed.name, 2);
		let value = parsed.value;

		if (value == null) {
			if (i + 1 >= length(values))
				die("option " + parsed.name + " needs a value");

			value = "" + values[++i];
		}

		switch (name) {
		case "url":
			args.overrides.subscription = value;
			break;
		case "engine":
			args.overrides.engine = value;
			break;
		case "test-url":
			args.overrides.test_url = value;
			break;
		case "timeout":
			args.overrides.timeout_ms = value;
			break;
		case "workers":
			args.overrides.concurrency = value;
			break;
		case "hwid-file":
			args.overrides.hwid_file = value;
			break;
		case "status-file":
			args.overrides.status_file = value;
			break;
		case "result-file":
			args.overrides.result_file = value;
			break;
		case "help":
			args.command = "help";
			break;
		default:
			die("unknown option " + parsed.name + "\n" + USAGE);
		}
	}

	return args;
}

function load(args) {
	let stored = load_uci();
	let cfg = {};

	cfg.enabled = stored.enabled;
	cfg.subscription = stored.subscription;
	cfg.engine = stored.engine;
	cfg.test_url = stored.test_url == "" ? DEFAULTS.test_url : stored.test_url;
	cfg.timeout_ms = util.to_int(stored.timeout_ms, DEFAULTS.timeout_ms);
	cfg.concurrency = util.to_int(stored.concurrency, DEFAULTS.concurrency);
	cfg.hwid_file = stored.hwid_file == "" ? DEFAULTS.hwid_file : stored.hwid_file;
	cfg.status_file = stored.status_file == "" ? DEFAULTS.status_file : stored.status_file;
	cfg.result_file = stored.result_file == "" ? DEFAULTS.result_file : stored.result_file;

	cfg.ua_mode = stored.ua_mode == "custom" ? "custom" : "auto";
	cfg.ua_user_agent = stored.ua_user_agent == "" ? DEFAULTS.ua_user_agent : stored.ua_user_agent;
	cfg.ua_device_os = stored.ua_device_os == "" ? DEFAULTS.ua_device_os : stored.ua_device_os;
	cfg.ua_ver_os = stored.ua_ver_os == "" ? DEFAULTS.ua_ver_os : stored.ua_ver_os;
	cfg.ua_app_version = stored.ua_app_version == "" ? DEFAULTS.ua_app_version : stored.ua_app_version;
	cfg.ua_device_model = stored.ua_device_model == "" ? DEFAULTS.ua_device_model : stored.ua_device_model;
	cfg.ua_device_locale = stored.ua_device_locale == "" ? DEFAULTS.ua_device_locale : stored.ua_device_locale;
	cfg.ua_hwid = stored.ua_hwid;

	for (let key in keys(args.overrides)) {
		let value = args.overrides[key];

		switch (key) {
		case "timeout_ms":
		case "concurrency":
			cfg[key] = util.to_int(value, DEFAULTS[key]);
			break;
		default:
			cfg[key] = value;
			break;
		}
	}

	cfg.json = args.json;
	cfg.compact = args.compact;
	cfg.verbose = args.verbose;
	cfg.command = args.command;
	cfg.result_explicit = args.overrides.result_file != null;

	if (cfg.timeout_ms < 500)
		cfg.timeout_ms = 500;
	if (cfg.timeout_ms > 60000)
		cfg.timeout_ms = 60000;
	if (cfg.concurrency < 1)
		cfg.concurrency = 1;
	if (cfg.concurrency > 32)
		cfg.concurrency = 32;

	return cfg;
}

function valid_subscription(value) {
	return substr(lc("" + value), 0, 7) == "http://" || substr(lc("" + value), 0, 8) == "https://";
}

return {
	DEFAULTS,
	USAGE,
	load_uci,
	parse_args,
	load,
	valid_subscription
};
