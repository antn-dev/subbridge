// Result rendering.
//
// JSON mode keeps stdout machine-readable: progress goes to stderr and the
// single JSON document is written to stdout or to --result-file. Console mode
// prints a short report that is convenient over SSH.

let fs = require("fs");
let util = require("util");

function display_name(name) {
	return name == null || name == "" ? "(unnamed)" : name;
}

function summary(results) {
	let online = 0;
	let offline = 0;

	for (let result in results) {
		if (result.status == "healthy")
			online++;
		else
			offline++;
	}

	return { online: online, offline: offline };
}

function build(results, profiles, best, elapsed_ms, meta) {
	let counts = summary(results);
	let json_results = [];

	for (let result in results) {
		let item = {
			name: result.name,
			type: result.type,
			address: result.address,
			port: result.port,
			status: result.status,
			latency_ms: result.latency_ms == null ? 0 : result.latency_ms
		};

		if (result.url != null && result.url != "")
			item.url = result.url;

		if (result.error != null && result.error != "")
			item.error = result.error;

		push(json_results, item);
	}

	let output = {};

	if (meta != null) {
		if (meta.subscription_url != null && meta.subscription_url != "")
			output.subscription_url = meta.subscription_url;
		if (meta.header_preset != null && meta.header_preset != "")
			output.header_preset = meta.header_preset;
		if (meta.header_lines != null && length(meta.header_lines) > 0)
			output.header_lines = meta.header_lines;
		if (meta.profile_items != null && length(meta.profile_items) > 0)
			output.profile_items = meta.profile_items;
	}

	output.profiles = profiles;
	output.endpoints = length(results);
	output.online = counts.online;
	output.offline = counts.offline;
	output.elapsed_ms = elapsed_ms;

	if (best != null) {
		output.best = {
			name: best.name,
			type: best.type,
			address: best.address,
			port: best.port,
			latency_ms: best.latency_ms,
			url: best.url
		};
	}

	output.results = json_results;

	return output;
}

function write_json(value, path, compact) {
	let text = sprintf(compact ? "%J\n" : "%.4J\n", value);

	if (path != null && path != "") {
		let dir = util.dirname(path);
		if (dir != "" && dir != ".")
			util.ensure_dir(dir, 0700);

		let tmp = path + ".tmp." + int(clock()[1] % 1000000);
		if (!util.write_file(tmp, text, 0600))
			die("cannot write result file " + path);

		if (fs.rename(tmp, path) != true) {
			fs.unlink(tmp);
			die("cannot write result file " + path);
		}

		return;
	}

	printf("%s", text);
}

function print_result(result) {
	if (result.status == "healthy")
		printf("✓ %-35s %dms\n", display_name(result.name), result.latency_ms);
	else
		printf("✗ %-35s %s\n", display_name(result.name), result.error == null ? "" : result.error);
}

function print_console(results, profiles, best, elapsed_ms) {
	for (let result in results)
		print_result(result);

	let counts = summary(results);

	printf("\nSummary\n");
	printf("-------\n");
	printf("Profiles : %d\n", profiles);
	printf("Endpoints: %d\n", length(results));
	printf("Online   : %d\n", counts.online);
	printf("Offline  : %d\n", counts.offline);

	if (best != null)
		printf("Best     : %s (%dms)\n", display_name(best.name), best.latency_ms);

	printf("Elapsed  : %dms\n", elapsed_ms);
	printf("\nDone.\n");
}

return {
	display_name,
	summary,
	build,
	write_json,
	print_result,
	print_console
};
