// Temporary sing-box engine.
//
// SubBridge ships no engine of its own. It reuses the sing-box that Podkop,
// Forkop or the stock package already installed, starts it with a minimal
// configuration (outbounds plus the Clash API, no inbounds, no routes, no
// DNS), measures every endpoint through the Clash API and stops it again.
//
// The engine is never registered as a service and never touches nftables,
// dnsmasq or an existing tunnel.

let fs = require("fs");
let socket = require("socket");
let util = require("util");
let url = require("url");
let fetch = require("fetch");
let limits = require("limits");

const START_TIMEOUT_MS = 8000;
const STOP_TIMEOUT_MS = 3000;
const MAX_LOG_TAIL = 4096;

function pause(ms) {
	socket.poll(ms);
}

function strip_ansi(text) {
	let s = "" + (text == null ? "" : text);
	let out = "";
	let i = 0;

	while (i < length(s)) {
		if (ord(substr(s, i, 1)) != 27) {
			out += substr(s, i, 1);
			i++;
			continue;
		}

		while (i < length(s) && substr(s, i, 1) != "m")
			i++;

		i++;
	}

	return out;
}

function clean_log_line(line) {
	let text = strip_ansi(util.trim(line));
	let open = index(text, "[");

	if (open <= 0 || open > 10)
		return text;

	let close = index(substr(text, open), "]");
	if (close <= 0)
		return text;

	let level = substr(text, 0, open);
	if (level != "TRACE" && level != "DEBUG" && level != "INFO" &&
	    level != "WARN" && level != "ERROR" && level != "FATAL" && level != "PANIC")
		return text;

	let rest = util.trim(substr(text, open + close + 1));
	return rest == "" ? text : rest;
}

function tail(path, limit) {
	let data = util.read_file(path);
	if (data == null)
		return "";

	let text = strip_ansi(util.trim(data));
	if (length(text) > limit)
		text = substr(text, length(text) - limit, limit);

	return text;
}

function first_error_line(output) {
	for (let line in util.split_lines(output)) {
		line = util.trim(line);
		if (line != "")
			return clean_log_line(line);
	}

	return "";
}

function find(custom) {
	if (custom != null && custom != "") {
		if (index(custom, "/") >= 0)
			return util.is_executable(custom) ? custom : null;

		return util.find_in_path(custom);
	}

	let found = util.find_in_path("sing-box");
	if (found != null)
		return found;

	for (let path in [
		"/usr/bin/sing-box",
		"/usr/local/bin/sing-box",
		"/opt/bin/sing-box",
		"/usr/libexec/sing-box"
	]) {
		if (util.is_executable(path))
			return path;
	}

	return null;
}

function find_error() {
	return "no sing-box engine found: install podkop-engine (recommended, provides sing-box) or sing-box";
}

function normalize_flow(flow) {
	if (flow == "xtls-rprx-vision-udp443")
		return "xtls-rprx-vision";

	return flow == null ? "" : flow;
}

function build_tls(endpoint) {
	if (endpoint.security != "reality" && endpoint.security != "tls")
		return null;

	let tls = {
		enabled: true
	};

	if (endpoint.server_name != "")
		tls.server_name = endpoint.server_name;

	if (endpoint.insecure)
		tls.insecure = true;

	if (length(endpoint.alpn) > 0)
		tls.alpn = endpoint.alpn;

	let fingerprint = endpoint.fingerprint;
	if (endpoint.security == "reality" && fingerprint == "")
		fingerprint = "chrome";

	if (fingerprint != "") {
		tls.utls = {
			enabled: true,
			fingerprint: fingerprint
		};
	}

	if (endpoint.security == "reality") {
		tls.reality = {
			enabled: true,
			public_key: endpoint.public_key
		};

		if (endpoint.short_id != "")
			tls.reality.short_id = endpoint.short_id;
	}

	return tls;
}

function build_transport(endpoint) {
	let t = endpoint.transport;
	if (t == null || t.type == null || t.type == "")
		return null;

	switch (t.type) {
	case "ws":
		let ws = {
			type: "ws",
			path: t.path == "" ? "/" : t.path
		};

		if (t.host != "")
			ws.headers = { "Host": t.host };

		return ws;

	case "grpc":
		return {
			type: "grpc",
			service_name: t.service_name == null ? "" : t.service_name
		};

	case "httpupgrade":
		return {
			type: "httpupgrade",
			path: t.path == "" ? "/" : t.path,
			host: t.host == null ? "" : t.host
		};

	case "xhttp":
		return {
			type: "xhttp",
			path: t.path == "" ? "/" : t.path,
			host: t.host == null ? "" : t.host,
			mode: t.mode == null ? "" : t.mode
		};

	case "http":
		return {
			type: "http",
			path: t.path == "" ? "/" : t.path,
			host: t.host == null ? "" : t.host
		};

	default:
		die("unsupported transport \"" + t.type + "\"");
	}
}

function build_outbound(endpoint, tag) {
	if (endpoint.address == "" || endpoint.port < 1 || endpoint.port > 65535)
		die("invalid address or port");

	if (endpoint.uuid == "")
		die("missing UUID");

	if (endpoint.security == "reality" && endpoint.public_key == "")
		die("REALITY endpoint without public key");

	let outbound = {
		type: "vless",
		tag: tag,
		server: endpoint.address,
		server_port: endpoint.port,
		uuid: endpoint.uuid
	};

	let flow = normalize_flow(endpoint.flow);
	if (flow != "")
		outbound.flow = flow;

	let tls = build_tls(endpoint);
	if (tls != null)
		outbound.tls = tls;

	let transport = build_transport(endpoint);
	if (transport != null)
		outbound.transport = transport;

	return outbound;
}

function build_config(endpoints, api_address) {
	let outbounds = [];
	let tags = [];

	for (let i = 0; i < length(endpoints); i++) {
		let tag = "e" + i;
		push(outbounds, build_outbound(endpoints[i], tag));
		push(tags, tag);
	}

	let config = {
		log: { level: "error" },
		outbounds: outbounds
	};

	if (api_address != "")
		config.experimental = { clash_api: { external_controller: api_address } };

	return { config: config, tags: tags };
}

function write_config(path, config) {
	let f = fs.open(path, "w", 0600);
	if (!f)
		die("cannot write engine config");

	f.write(sprintf("%J", config));
	f.close();
}

function check_config(binary, path) {
	let result = util.command_argv([binary, "check", "-c", path]);
	return { ok: result.code == 0, output: result.output };
}

function parse_rejected_index(output) {
	let text = strip_ansi(output);
	let index = -1;
	let marker_len = 0;

	for (let marker in ["outbounds[", "outbound["]) {
		let found = index(text, marker);
		if (found >= 0 && (index < 0 || found < index)) {
			index = found;
			marker_len = length(marker);
		}
	}

	if (index < 0)
		return -1;

	let rest = substr(text, index + marker_len);
	let end = index(rest, "]");
	if (end < 0)
		return -1;

	let value = util.to_int(substr(rest, 0, end), -1);
	return value;
}

function free_port() {
	let s = socket.create(socket.AF_INET, socket.SOCK_STREAM);
	if (!s)
		return 0;

	let ok = s.bind({ address: "127.0.0.1", port: 0 });
	if (ok != true) {
		s.close();
		return 0;
	}

	let address = s.sockname();
	s.close();

	return address == null ? 0 : util.to_int(address.port, 0);
}

function local_status(port, path, timeout_ms) {
	let s = socket.create(socket.AF_INET, socket.SOCK_STREAM);
	if (!s)
		return 0;

	try {
		if (s.connect("127.0.0.1", port) != true) {
			s.close();
			return 0;
		}

		s.send("GET " + path + " HTTP/1.0\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");

		let data = "";
		for (let i = 0; i < 20; i++) {
			let events = socket.poll(timeout_ms, s);
			if (events == null || length(events) == 0)
				break;

			let chunk = s.recv(65536);
			if (chunk == null || chunk == "")
				break;

			data += chunk;
			if (index(data, "\r\n") >= 0)
				break;
		}

		s.close();

		let line = split(data, "\r\n")[0];
		if (line == null)
			return 0;

		let parts = split(line, " ");
		return parts != null && length(parts) >= 2 ? util.to_int(parts[1], 0) : 0;
	}
	catch (e) {
		s.close();
		return 0;
	}
}

function process_alive(pid) {
	return pid > 0 && fs.stat("/proc/" + pid) != null;
}

function stop_process(pid) {
	if (pid <= 0)
		return;

	util.command("kill -TERM " + pid + " 2>/dev/null");

	let deadline = util.now_ms() + STOP_TIMEOUT_MS;
	while (util.now_ms() < deadline) {
		if (!process_alive(pid))
			return;
		pause(50);
	}

	util.command("kill -9 " + pid + " 2>/dev/null");
	pause(50);
}

function launch(binary, config_path, log_path) {
	let command = "( exec " + util.shell_quote(binary) + " run -c " + util.shell_quote(config_path) +
		" >" + util.shell_quote(log_path) + " 2>&1 ) & echo $!";

	let p = fs.popen(command);
	if (!p)
		die("cannot start sing-box");

	let pid = util.to_int(util.trim(p.read("all")), 0);
	p.close();

	if (pid <= 0)
		die("cannot start sing-box: no process id");

	return pid;
}

function wait_ready(port, pid, log_path) {
	let deadline = util.now_ms() + START_TIMEOUT_MS;

	while (util.now_ms() < deadline) {
		if (!process_alive(pid))
			die("sing-box exited during startup: " + tail(log_path, MAX_LOG_TAIL));

		if (local_status(port, "/proxies", 500) == 200)
			return;

		pause(50);
	}

	die("sing-box did not expose the Clash API in " + (START_TIMEOUT_MS / 1000) + "s: " + tail(log_path, MAX_LOG_TAIL));
}

function start(binary, support, endpoints) {
	let dir = util.temp_dir("subbridge-check");
	let config_path = dir + "/config.json";
	let log_path = dir + "/engine.log";

	let port = free_port();
	if (port <= 0) {
		util.command("rm -rf " + util.shell_quote(dir));
		die("cannot pick a Clash API port");
	}

	let kept = [];
	for (let i = 0; i < length(endpoints); i++)
		push(kept, i);

	let dropped = {};
	let tags = [];

	for (let attempt = 0; attempt <= length(endpoints); attempt++) {
		if (length(kept) == 0) {
			util.command("rm -rf " + util.shell_quote(dir));
			return { kept: [], tags: [], dropped: dropped, port: 0, pid: 0, dir: dir, binary: binary };
		}

		let subset = [];
		for (let index in kept)
			push(subset, endpoints[index]);

		let built = build_config(subset, "127.0.0.1:" + port);
		write_config(config_path, built.config);

		let checked = check_config(binary, config_path);
		if (checked.ok) {
			let pid = 0;

			try {
				pid = launch(binary, config_path, log_path);
				wait_ready(port, pid, log_path);
			}
			catch (e) {
				if (pid > 0)
					stop_process(pid);

				util.command("rm -rf " + util.shell_quote(dir));
				die(e);
			}

			return {
				kept: kept,
				tags: built.tags,
				dropped: dropped,
				port: port,
				pid: pid,
				dir: dir,
				binary: binary
			};
		}

		let rejected = parse_rejected_index(checked.output);
		if (rejected < 0 || rejected >= length(kept)) {
			util.command("rm -rf " + util.shell_quote(dir));
			die("engine rejected the configuration: " + first_error_line(checked.output));
		}

		let original = kept[rejected];
		dropped[original] = "engine rejected the endpoint: " + first_error_line(checked.output);

		// Rebuilding the whole configuration for every rejected endpoint is
		// expensive; a broken subscription must not turn into an O(N^2) loop.
		if (length(keys(dropped)) > limits.MAX_REJECTED_ENDPOINTS) {
			util.command("rm -rf " + util.shell_quote(dir));
			die("engine rejected too many endpoints (limit " + limits.MAX_REJECTED_ENDPOINTS + ")");
		}

		// Remove the rejected entry; the next config uses the remaining ones.
		let next = [];
		for (let i = 0; i < length(kept); i++) {
			if (i != rejected)
				push(next, kept[i]);
		}

		kept = next;
	}

	for (let index in kept)
		dropped[index] = "engine kept rejecting this endpoint";

	util.command("rm -rf " + util.shell_quote(dir));

	return { kept: [], tags: [], dropped: dropped, port: 0, pid: 0, dir: dir, binary: binary };
}

function close(engine) {
	if (engine == null)
		return;

	if (engine.pid > 0)
		stop_process(engine.pid);

	if (engine.dir != null && engine.dir != "")
		util.command("rm -rf " + util.shell_quote(engine.dir));
}

function delay_path(tag, target, timeout_ms) {
	return "/proxies/" + url.percent_encode(tag, false) + "/delay?url=" +
		url.percent_encode(target, true) + "&timeout=" + timeout_ms;
}

function delay_url(port, tag, target, timeout_ms) {
	return "http://127.0.0.1:" + port + delay_path(tag, target, timeout_ms);
}

function parse_delay(path) {
	let data = util.read_file(path);
	if (data == null || util.trim(data) == "")
		return { error: "engine did not respond" };

	let value = null;
	try {
		value = json(data);
	}
	catch (e) {
		return { error: "invalid engine response" };
	}

	if (value == null)
		return { error: "invalid engine response" };

	let message = type(value.message) == "string" ? value.message : "";
	if (message != "")
		return { error: message };

	let delay = util.to_int(value.delay, 0);
	if (delay <= 0)
		return { error: "no delay reported" };

	return { delay: delay };
}

function run_sequential(binary, jobs, port, target, timeout_ms, dir) {
	let out = {};

	for (let i = 0; i < length(jobs); i++) {
		let path = dir + "/r" + i;
		let argv = [binary, "-q", "-O", path, "--timeout=" + (timeout_ms + 2000), delay_url(port, jobs[i].tag, target, timeout_ms)];
		util.command_argv(argv);
		out[jobs[i].tag] = parse_delay(path);
	}

	return out;
}

function run_parallel(transport, jobs, port, target, timeout_ms, dir, workers) {
	let argv = [
		transport,
		"-sS",
		"--parallel",
		"--parallel-max", "" + workers,
		"--max-time", "" + int(timeout_ms / 1000 + 3)
	];

	for (let i = 0; i < length(jobs); i++)
		push(argv, "-o", dir + "/r" + i, delay_url(port, jobs[i].tag, target, timeout_ms));

	util.command_argv(argv);

	let out = {};
	let missing = 0;

	for (let i = 0; i < length(jobs); i++) {
		let result = parse_delay(dir + "/r" + i);
		out[jobs[i].tag] = result;
		if (result.error == "engine did not respond")
			missing++;
	}

	// Very old curl builds lack --parallel. Fall back to one request at a
	// time so the check still completes, just slower.
	if (missing == length(jobs) && length(jobs) > 1) {
		let fallback = fetch.transport();
		if (fallback != null && fallback == transport)
			fallback = util.find_in_path("uclient-fetch");

		if (fallback != null && fallback != transport)
			return run_sequential(fallback, jobs, port, target, timeout_ms, dir);
	}

	return out;
}

function measure(port, jobs, target, timeout_ms, workers, dir) {
	let transport = fetch.transport();
	if (transport == null)
		die("neither curl nor uclient-fetch is installed");

	if (workers < 1)
		workers = 1;

	if (index(transport, "curl") >= 0)
		return run_parallel(transport, jobs, port, target, timeout_ms, dir, workers);

	return run_sequential(transport, jobs, port, target, timeout_ms, dir);
}

// Probe checks which transports and security types this particular sing-box
// build accepts. Only features that the subscription actually uses are
// tested, so a plain subscription costs one extra `sing-box check` run.
function probe_endpoint(probe) {
	let endpoint = {
		name: "probe",
		protocol: "vless",
		address: "127.0.0.1",
		port: 1,
		uuid: "11111111-1111-1111-1111-111111111111",
		encryption: "none",
		flow: "",
		network: "",
		security: "",
		server_name: "",
		fingerprint: "",
		public_key: "",
		short_id: "",
		spider_x: "",
		alpn: [],
		insecure: false,
		transport: { type: "" }
	};

	switch (probe) {
	case "ws":
		endpoint.transport = { type: "ws", path: "/" };
		break;
	case "grpc":
		endpoint.transport = { type: "grpc", service_name: "probe" };
		break;
	case "http":
		endpoint.transport = { type: "http", path: "/" };
		break;
	case "httpupgrade":
		endpoint.transport = { type: "httpupgrade", path: "/" };
		break;
	case "xhttp":
		endpoint.transport = { type: "xhttp", path: "/", mode: "auto" };
		break;
	case "tls":
		endpoint.security = "tls";
		endpoint.server_name = "example.com";
		break;
	case "reality":
		endpoint.security = "reality";
		endpoint.server_name = "example.com";
		endpoint.fingerprint = "chrome";
		endpoint.public_key = "whQ-i5BTbwJZR96IdTsX-GcvV6nUyBVQGVTY3eioP1I";
		endpoint.short_id = "01";
		break;
	}

	return endpoint;
}


function probe(binary, endpoints) {
	let version = util.command_argv([binary, "version"]);
	let first_line = util.first_line(version.output);

	let needed = { "": true };

	for (let endpoint in endpoints) {
		let transport = endpoint.transport == null ? "" : endpoint.transport.type;
		if (transport != "")
			needed[transport] = true;

		if (endpoint.security == "tls")
			needed.tls = true;
		else if (endpoint.security == "reality")
			needed.reality = true;
	}

	let support = {
		binary: binary,
		version: first_line,
		transports: {},
		tls: false,
		reality: false
	};

	let dir = util.temp_dir("subbridge-probe");
	let path = dir + "/config.json";

	for (let name in ["", "ws", "grpc", "http", "httpupgrade", "xhttp", "tls", "reality"]) {
		if (needed[name] != true)
			continue;

		let endpoint = probe_endpoint(name);
		let built = build_config([endpoint], "");
		write_config(path, built.config);

		if (check_config(binary, path).ok) {
			if (name == "tls")
				support.tls = true;
			else if (name == "reality")
				support.reality = true;
			else
				support.transports[name] = true;
		}
	}

	util.command("rm -rf " + util.shell_quote(dir));

	return support;
}

function unsupported_reason(endpoint, support) {
	if (endpoint.protocol != "vless")
		return "protocol \"" + endpoint.protocol + "\" is not supported yet";

	let transport = endpoint.transport == null ? "" : endpoint.transport.type;

	if (support.transports[transport] != true) {
		if (transport == "")
			return "installed sing-box cannot build a plain VLESS outbound";

		return "installed sing-box does not support the \"" + transport + "\" transport";
	}

	if (endpoint.security == "reality" && !support.reality)
		return "installed sing-box is not able to build this REALITY outbound (needs with_utls)";

	if (endpoint.security == "tls" && !support.tls)
		return "installed sing-box cannot build this TLS outbound";

	return "";
}

return {
	START_TIMEOUT_MS,
	pause,
	strip_ansi,
	clean_log_line,
	tail,
	first_error_line,
	find,
	find_error,
	normalize_flow,
	build_tls,
	build_transport,
	build_outbound,
	build_config,
	write_config,
	check_config,
	parse_rejected_index,
	free_port,
	local_status,
	process_alive,
	stop_process,
	launch,
	wait_ready,
	start,
	close,
	delay_path,
	delay_url,
	parse_delay,
	measure,
	probe,
	probe_endpoint,
	unsupported_reason
};
