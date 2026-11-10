// Subscription parser.
//
// Two shapes are supported, exactly like the Go implementation:
//
//   * a JSON array (or a single object) of Xray profiles with VLESS outbounds;
//   * a plain list of vless:// URIs, one per line.
//
// Endpoints are flattened: one VLESS outbound becomes one checkable endpoint.
// Profile payloads are kept so the LuCI page can copy the provider's original
// JSON or link without asking the provider again.

let util = require("util");
let url = require("url");
let limits = require("limits");

function get(obj, key) {
	if (obj == null)
		return null;

	let t = type(obj);
	if (t != "object" && t != "array")
		return null;

	return obj[key];
}

function str(value) {
	return type(value) == "string" ? value : "";
}

function first_nonempty(value) {
	if (type(value) == "array") {
		for (let item in value) {
			if (str(item) != "")
				return item;
		}

		return "";
	}

	return str(value);
}

function header_value(headers, name) {
	if (type(headers) != "object")
		return "";

	for (let key in keys(headers)) {
		if (lc(key) == lc(name))
			return str(headers[key]);
	}

	return "";
}

function split_list(value) {
	if (type(value) == "array")
		return value;

	let out = [];
	for (let part in split(str(value), ",")) {
		part = util.trim(part);
		if (part != "")
			push(out, part);
	}

	return out;
}

function transport_from_json(stream) {
	let network = lc(str(get(stream, "network")));

	switch (network) {
	case "":
	case "tcp":
	case "raw":
		return { type: "" };

	case "ws":
		return {
			type: "ws",
			path: str(get(get(stream, "wsSettings"), "path")),
			host: header_value(get(get(stream, "wsSettings"), "headers"), "Host")
		};

	case "grpc":
		return {
			type: "grpc",
			service_name: str(get(get(stream, "grpcSettings"), "serviceName"))
		};

	case "httpupgrade":
		return {
			type: "httpupgrade",
			path: str(get(get(stream, "httpupgradeSettings"), "path")),
			host: str(get(get(stream, "httpupgradeSettings"), "host"))
		};

	case "xhttp":
	case "splithttp":
		return {
			type: "xhttp",
			path: str(get(get(stream, "xhttpSettings"), "path")),
			host: str(get(get(stream, "xhttpSettings"), "host")),
			mode: str(get(get(stream, "xhttpSettings"), "mode"))
		};

	case "h2":
	case "http":
		return {
			type: "http",
			path: str(get(get(stream, "httpSettings"), "path")),
			host: first_nonempty(get(get(stream, "httpSettings"), "host"))
		};

	default:
		return { type: network };
	}
}

function endpoint_from_outbound(name, outbound) {
	if (lc(str(get(outbound, "protocol"))) != "vless")
		return null;

	let settings = get(outbound, "settings");
	let vnext = get(get(settings, "vnext"), 0);
	if (vnext == null)
		return null;

	let user = get(get(vnext, "users"), 0);
	if (user == null)
		return null;

	let stream = get(outbound, "streamSettings");
	let security = lc(str(get(stream, "security")));

	let endpoint = {
		name: name,
		protocol: "vless",
		address: str(get(vnext, "address")),
		port: util.to_int(get(vnext, "port"), 0),
		uuid: str(get(user, "id")),
		encryption: str(get(user, "encryption")),
		flow: str(get(user, "flow")),
		network: str(get(stream, "network")),
		security: security,
		server_name: "",
		fingerprint: "",
		public_key: "",
		short_id: "",
		spider_x: "",
		alpn: [],
		insecure: false,
		transport: transport_from_json(stream)
	};

	if (security == "reality") {
		let reality = get(stream, "realitySettings");
		endpoint.server_name = str(get(reality, "serverName"));
		endpoint.fingerprint = str(get(reality, "fingerprint"));
		endpoint.public_key = str(get(reality, "publicKey"));
		endpoint.short_id = str(get(reality, "shortId"));
		endpoint.spider_x = str(get(reality, "spiderX"));
	}
	else if (security == "tls") {
		let tls = get(stream, "tlsSettings");
		endpoint.server_name = str(get(tls, "serverName"));
		endpoint.fingerprint = str(get(tls, "fingerprint"));
		endpoint.alpn = split_list(get(tls, "alpn"));
		endpoint.insecure = get(tls, "allowInsecure") == true || get(tls, "skip-cert-verify") == true;
	}

	return endpoint;
}

function endpoints_from_profile(profile) {
	let out = [];
	let name = str(get(profile, "remarks"));
	let outbounds = get(profile, "outbounds");

	if (type(outbounds) != "array")
		return out;

	for (let outbound in outbounds) {
		let endpoint = endpoint_from_outbound(name, outbound);
		if (endpoint != null)
			push(out, endpoint);
	}

	return out;
}

function transport_from_query(q) {
	let network = lc(str(get(q, "type")));

	switch (network) {
	case "":
	case "tcp":
	case "raw":
		return { type: "" };

	case "ws":
		return { type: "ws", path: str(get(q, "path")), host: str(get(q, "host")) };

	case "grpc":
		let service = str(get(q, "serviceName"));
		if (service == "")
			service = str(get(q, "path"));
		return { type: "grpc", service_name: service };

	case "httpupgrade":
		return { type: "httpupgrade", path: str(get(q, "path")), host: str(get(q, "host")) };

	case "xhttp":
	case "splithttp":
		return {
			type: "xhttp",
			path: str(get(q, "path")),
			host: str(get(q, "host")),
			mode: str(get(q, "mode"))
		};

	case "h2":
	case "http":
		return { type: "http", path: str(get(q, "path")), host: str(get(q, "host")) };

	default:
		return { type: network };
	}
}

function parse_vless_uri(raw) {
	let parsed = url.parse(raw);

	if (parsed.scheme != "vless")
		die("unsupported scheme " + parsed.scheme);

	if (parsed.host == "")
		die("VLESS URL has no address");

	let port = util.to_int(parsed.port, 0);
	if (port < 1 || port > 65535)
		die("invalid VLESS port");

	let uuid = url.percent_decode(parsed.userinfo, false);
	if (uuid == "")
		die("VLESS URL has no UUID");

	let q = parsed.query;
	let security = lc(str(get(q, "security")));

	let alpn = split_list(get(q, "alpn"));
	let insecure = str(get(q, "allowInsecure")) == "1" ||
		lc(str(get(q, "allowInsecure"))) == "true" ||
		str(get(q, "insecure")) == "1" ||
		lc(str(get(q, "insecure"))) == "true";

	let endpoint = {
		name: parsed.fragment,
		protocol: "vless",
		address: parsed.host,
		port: port,
		uuid: uuid,
		encryption: str(get(q, "encryption")),
		flow: str(get(q, "flow")),
		network: str(get(q, "type")),
		security: security == "none" ? "" : security,
		server_name: str(get(q, "sni")),
		fingerprint: str(get(q, "fp")),
		public_key: str(get(q, "pbk")),
		short_id: str(get(q, "sid")),
		spider_x: str(get(q, "spx")),
		alpn: alpn,
		insecure: insecure,
		transport: transport_from_query(q)
	};

	return endpoint;
}

// endpoint_url renders an endpoint back into a VLESS URI for the report's
// copy button. The query order is fixed instead of sorted; every client
// accepts either.
function endpoint_url(endpoint) {
	if (endpoint.address == "" || endpoint.port <= 0)
		return "";

	let q = {};
	q.encryption = endpoint.encryption == "" ? "none" : endpoint.encryption;
	q.security = endpoint.security == "" ? "none" : endpoint.security;
	q.type = endpoint.transport.type == "" ? "tcp" : endpoint.transport.type;

	if (endpoint.flow != "")
		q.flow = endpoint.flow;

	if (endpoint.security == "reality") {
		if (endpoint.server_name != "")
			q.sni = endpoint.server_name;
		if (endpoint.fingerprint != "")
			q.fp = endpoint.fingerprint;
		if (endpoint.public_key != "")
			q.pbk = endpoint.public_key;
		if (endpoint.short_id != "")
			q.sid = endpoint.short_id;
		if (endpoint.spider_x != "")
			q.spx = endpoint.spider_x;
		if (length(endpoint.alpn) > 0)
			q.alpn = join(",", endpoint.alpn);
	}
	else if (endpoint.security == "tls") {
		if (endpoint.server_name != "")
			q.sni = endpoint.server_name;
		if (endpoint.fingerprint != "")
			q.fp = endpoint.fingerprint;
		if (length(endpoint.alpn) > 0)
			q.alpn = join(",", endpoint.alpn);
		if (endpoint.insecure)
			q.allowInsecure = "1";
	}

	switch (endpoint.transport.type) {
	case "ws":
	case "httpupgrade":
	case "http":
		if (endpoint.transport.path != "")
			q.path = endpoint.transport.path;
		if (endpoint.transport.host != "")
			q.host = endpoint.transport.host;
		break;

	case "grpc":
		if (endpoint.transport.service_name != "")
			q.serviceName = endpoint.transport.service_name;
		break;

	case "xhttp":
		if (endpoint.transport.path != "")
			q.path = endpoint.transport.path;
		if (endpoint.transport.host != "")
			q.host = endpoint.transport.host;
		if (endpoint.transport.mode != "")
			q.mode = endpoint.transport.mode;
		break;
	}

	let host = endpoint.address;
	if (index(host, ":") >= 0 && substr(host, 0, 1) != "[")
		host = "[" + host + "]";

	let link = "vless://" + endpoint.uuid + "@" + host + ":" + endpoint.port;

	if (length(keys(q)) > 0)
		link += "?" + url.query_encode(q);

	if (endpoint.name != "")
		link += "#" + url.percent_encode(endpoint.name, false);

	return link;
}

function placeholder_reason(endpoints) {
	if (length(endpoints) == 0)
		return "";

	for (let endpoint in endpoints) {
		let address = endpoint.address;
		if (address != "0.0.0.0" && address != "::")
			return "";
	}

	let messages = [];

	for (let endpoint in endpoints) {
		let name = util.trim(endpoint.name);
		if (name == "")
			continue;

		let seen = false;
		for (let existing in messages) {
			if (existing == name) {
				seen = true;
				break;
			}
		}

		if (!seen)
			push(messages, name);
	}

	if (length(messages) > 0)
		return "provider returned a placeholder subscription: " + join("; ", messages);

	return "provider returned a placeholder subscription (servers point at 0.0.0.0)";
}

function profile_name(name, index) {
	if (util.trim(name) != "")
		return name;

	return "Профиль " + (index + 1);
}

function parse(decoded) {
	let text = util.trim(decoded);
	let endpoints = [];
	let profiles = [];

	if (substr(text, 0, 1) == "{" || substr(text, 0, 1) == "[") {
		let value = json(text);
		let items = substr(text, 0, 1) == "{" ? [value] : value;

		if (type(items) != "array")
			die("parse subscription: expected an array of profiles");

		if (length(items) > limits.MAX_PROFILES)
			die("subscription contains too many profiles (limit " + limits.MAX_PROFILES + ")");

		let index = 0;

		for (let profile in items) {
			let profile_endpoints = endpoints_from_profile(profile);

			for (let endpoint in profile_endpoints)
				push(endpoints, endpoint);

			if (length(endpoints) > limits.MAX_ENDPOINTS)
				die("subscription contains too many endpoints (limit " + limits.MAX_ENDPOINTS + ")");

			let payload = sprintf("%J", profile);
			if (length(payload) > limits.MAX_PROFILE_BYTES)
				die("profile is too large (limit " + limits.MAX_PROFILE_BYTES + " bytes)");

			push(profiles, {
				name: profile_name(str(get(profile, "remarks")), index),
				payload: payload
			});

			index++;
		}
	}
	else if (substr(lc(text), 0, 8) == "vless://") {
		for (let line in util.split_lines(text)) {
			line = util.trim(line);
			if (line == "")
				continue;

			if (substr(lc(line), 0, 8) != "vless://")
				continue;

			try {
				let endpoint = parse_vless_uri(line);
				push(endpoints, endpoint);
				push(profiles, {
					name: profile_name(endpoint.name, length(profiles)),
					payload: endpoint_url(endpoint)
				});
			}
			catch (e) {
				// One malformed line must not discard the subscription.
			}

			if (length(endpoints) > limits.MAX_ENDPOINTS)
				die("subscription contains too many endpoints (limit " + limits.MAX_ENDPOINTS + ")");
		}

		if (length(endpoints) == 0)
			die("no VLESS endpoints found");
	}
	else {
		die("unsupported decoded subscription format");
	}

	let reason = placeholder_reason(endpoints);
	if (reason != "")
		die("" + reason);

	return { endpoints: endpoints, profiles: profiles };
}

return {
	get,
	str,
	header_value,
	split_list,
	transport_from_json,
	transport_from_query,
	endpoint_from_outbound,
	endpoints_from_profile,
	parse_vless_uri,
	endpoint_url,
	placeholder_reason,
	profile_name,
	parse
};
