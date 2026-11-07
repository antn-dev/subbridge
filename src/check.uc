// Check pipeline: download, parse, probe, start the engine, measure, print.
//
// One check at a time: several sing-box processes on a 64-128 MB router are a
// good way to trigger the OOM killer. The lock is a directory so creation is
// atomic on every filesystem OpenWrt uses.

let fs = require("fs");
let util = require("util");
let urlmod = require("url");
let presets = require("presets");
let fetch = require("fetch");
let decode = require("decode");
let parse = require("parse");
let engine = require("engine");
let status = require("status");
let output = require("output");
let config = require("config");

const LOCK_DIR = "/tmp/subbridge-check.lock";
const STALE_LOCK_SECONDS = 900;

function acquire_lock() {
	let st = fs.stat(LOCK_DIR);
	if (st != null) {
		if (time() - st.mtime > STALE_LOCK_SECONDS) {
			fs.rmdir(LOCK_DIR);
		}
		else {
			die("A check is already running");
		}
	}

	if (fs.mkdir(LOCK_DIR, 0700) != true)
		die("Cannot create the check lock");
}

function release_lock() {
	fs.rmdir(LOCK_DIR);
}

function cleanup_dir(path) {
	if (path != null && path != "")
		util.command("rm -rf " + util.shell_quote(path));
}

/*
 * The lock guarantees that no other check is running, so any temporary
 * directory left in /tmp belongs to an interrupted run. Remove it before a new
 * check starts: these directories contain endpoint credentials.
 */
function sweep_stale() {
	util.command("rm -rf /tmp/subbridge-check-* /tmp/subbridge-fetch-* " +
		"/tmp/subbridge-delay-* /tmp/subbridge-probe-* 2>/dev/null");
}

function load_subscription(cfg, workdir) {
	let target = presets.parse_target(urlmod.parse(cfg.subscription).fragment);
	let candidates = cfg.ua_mode == "custom" ? [ presets.custom(cfg) ] : presets.candidates(target);
	let tried = [];
	let last_error = "";
	let placeholder_error = "";

	for (let preset in candidates) {
		push(tried, preset.label);

		try {
			let response = fetch.fetch_subscription(cfg.subscription, preset.headers, cfg.hwid_file, 30, workdir);
			let parsed = parse.parse(decode.decode(response.data));

			if (length(parsed.endpoints) == 0) {
				last_error = "subscription contains no endpoints";
				continue;
			}

			return {
				data: response.data,
				url: response.url,
				headers: response.headers,
				preset: preset,
				endpoints: parsed.endpoints,
				profiles: parsed.profiles
			};
		}
		catch (e) {
			last_error = "" + e;

			if (index(last_error, "placeholder") >= 0)
				placeholder_error = last_error;
		}
	}

	if (placeholder_error != "")
		last_error = placeholder_error;

	if (last_error == "")
		last_error = "no supported header presets";

	die("no header preset produced a working subscription (tried: " + join(", ", tried) + "): " + last_error);
}

function best_result(results) {
	let best = null;

	for (let result in results) {
		if (result.status != "healthy" || result.latency_ms <= 0)
			continue;

		if (best == null || result.latency_ms < best.latency_ms)
			best = result;
	}

	return best;
}

function run(cfg) {
	let st = status.writer(cfg.status_file);
	let started = util.now_ms();
	let locked = false;
	let process = null;
	let fetchdir = null;
	let delaydir = null;

	try {
		acquire_lock();
		locked = true;

		sweep_stale();

		if (!cfg.enabled)
			die("SubBridge is disabled");

		if (cfg.subscription == "")
			die("Subscription URL is not configured");

		if (!config.valid_subscription(cfg.subscription))
			die("Subscription URL must start with http:// or https://");

		if (!cfg.json || cfg.verbose) {
			printf("SubBridge\n");
			printf("==========\n\n");
			printf("Loading configuration... OK\n");
		}

		status.phase(st, "download");

		let binary = engine.find(cfg.engine);
		if (binary == null)
			die(engine.find_error());

		if (!cfg.json || cfg.verbose)
			printf("Downloading subscription...\n");

		fetchdir = util.temp_dir("subbridge-fetch");
		let loaded = load_subscription(cfg, fetchdir);

		status.phase(st, "parse");

		if (!cfg.json || cfg.verbose) {
			printf("Downloaded %d bytes\n", length(loaded.data));
			printf("Found %d profiles\n", length(loaded.profiles));
			printf("Found %d endpoints\n", length(loaded.endpoints));
			printf("Resolved: %s\n", loaded.url);
			printf("Header  : %s\n\n", loaded.preset.label);
		}

		if (length(loaded.endpoints) == 0)
			die("subscription contains no endpoints");

		status.phase(st, "probe");

		let support = engine.probe(binary, loaded.endpoints);

		if (!cfg.json || cfg.verbose) {
			printf("Engine: %s (%s)\n", binary, support.version);
			printf("Starting engine...\n");
		}

		let results = [];
		for (let endpoint in loaded.endpoints) {
			push(results, {
				name: endpoint.name,
				type: "vless",
				address: endpoint.address,
				port: endpoint.port,
				url: parse.endpoint_url(endpoint),
				status: "failed",
				latency_ms: 0,
				error: ""
			});
		}

		let supported = [];
		let origin = [];

		for (let i = 0; i < length(loaded.endpoints); i++) {
			let reason = engine.unsupported_reason(loaded.endpoints[i], support);
			if (reason != "") {
				results[i].error = reason;

				if (!cfg.json || cfg.verbose)
					printf("Skipping endpoint: %s\n", reason);

				continue;
			}

			push(supported, loaded.endpoints[i]);
			push(origin, i);
		}

		if (length(supported) > 0) {
			status.phase(st, "start");
			process = engine.start(binary, support, supported);

			for (let supported_index in keys(process.dropped)) {
				let position = util.to_int(supported_index, -1);
				if (position < 0 || position >= length(origin))
					continue;

				results[origin[position]].error = process.dropped[supported_index];

				if (!cfg.json || cfg.verbose)
					printf("Skipping endpoint: %s\n", process.dropped[supported_index]);
			}

			let jobs = [];
			for (let position = 0; position < length(process.kept); position++) {
				let supported_index = process.kept[position];
				if (supported_index < 0 || supported_index >= length(origin))
					continue;
				if (position >= length(process.tags))
					break;

				push(jobs, {
					tag: process.tags[position],
					original: origin[supported_index]
				});
			}

			if (length(jobs) > 0) {
				status.phase(st, "check");
				status.progress(st, length(jobs), 0);

				delaydir = util.temp_dir("subbridge-delay");

				let workers = cfg.concurrency;
				if (workers < 1)
					workers = 1;

				let completed = 0;
				let total = length(jobs);

				for (let offset = 0; offset < total; offset += workers) {
					let batch = slice(jobs, offset, offset + workers);
					let measured = engine.measure(process.port, batch, cfg.test_url, cfg.timeout_ms, workers, delaydir);

					for (let job in batch) {
						let result = measured[job.tag];
						let target = results[job.original];

						if (result == null || result.error != null) {
							target.error = result == null ? "engine did not respond" : result.error;
						}
						else {
							target.status = "healthy";
							target.latency_ms = result.delay;
						}
					}

					completed += length(batch);
					status.progress(st, total, completed);

					if (!cfg.json || cfg.verbose)
						printf("Checked %d/%d\n", completed, total);
				}

				cleanup_dir(delaydir);
				delaydir = null;
			}
		}

		let best = best_result(results);

		for (let result in results) {
			if (result.status != "healthy" && result.error == "") {
				result.error = "endpoint was not checked";
			}
		}

		cleanup_dir(fetchdir);
		fetchdir = null;

		if (process != null) {
			engine.close(process);
			process = null;
		}

		release_lock();
		locked = false;

		let document = output.build(
			results,
			length(loaded.profiles),
			best,
			util.now_ms() - started,
			{
				subscription_url: loaded.url,
				header_preset: loaded.preset.label,
				header_lines: fetch.header_lines(loaded.headers),
				profile_items: loaded.profiles
			}
		);

		if (cfg.json) {
			if (cfg.result_explicit)
				output.write_json(document, cfg.result_file, cfg.compact);
			else
				output.write_json(document, "", cfg.compact);
		}
		else {
			output.print_console(document.results, document.profiles, best, document.elapsed_ms);

			if (cfg.result_explicit)
				output.write_json(document, cfg.result_file, cfg.compact);
		}

		status.done(st);

		return document;
	}
	catch (e) {
		if (process != null)
			engine.close(process);

		cleanup_dir(delaydir);
		cleanup_dir(fetchdir);

		if (locked)
			release_lock();

		status.fail(st, "" + e);
		die(e);
	}
}

return {
	LOCK_DIR,
	acquire_lock,
	release_lock,
	load_subscription,
	best_result,
	run
};
