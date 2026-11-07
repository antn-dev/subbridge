// Minimal URL helpers. ucode has no URL parser, and the subscription handoff
// logic needs query values, fragments and relative links.

let util = require("util");

function percent_decode(value, plus_as_space) {
	let s = "" + (value == null ? "" : value);
	let out = "";

	for (let i = 0; i < length(s); i++) {
		let ch = substr(s, i, 1);

		if (ch == "%" && i + 2 < length(s)) {
			let code = hex(substr(s, i + 1, 2));
			if (code != null) {
				out += chr(code);
				i += 2;
				continue;
			}
		}

		if (plus_as_space && ch == "+") {
			out += " ";
			continue;
		}

		out += ch;
	}

	return out;
}

function percent_encode(value, plus_as_space) {
	let s = "" + (value == null ? "" : value);
	let unreserved = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~";
	let out = "";

	for (let i = 0; i < length(s); i++) {
		let ch = substr(s, i, 1);

		if (index(unreserved, ch) >= 0) {
			out += ch;
			continue;
		}

		if (plus_as_space && ch == " ") {
			out += "+";
			continue;
		}

		out += sprintf("%%%02X", ord(ch));
	}

	return out;
}

function query_encode(params) {
	let parts = [];

	for (let key in keys(params)) {
		let value = params[key];
		if (value == null)
			continue;

		push(parts, percent_encode(key, true) + "=" + percent_encode("" + value, true));
	}

	return join("&", parts);
}

function parse_query(value) {
	let params = {};

	for (let pair in split("" + (value == null ? "" : value), "&")) {
		if (pair == "")
			continue;

		let pos = index(pair, "=");
		let key = pos < 0 ? pair : substr(pair, 0, pos);
		let val = pos < 0 ? "" : substr(pair, pos + 1);

		params[percent_decode(key, true)] = percent_decode(val, true);
	}

	return params;
}

function authority_of(parsed) {
	let value = parsed.host;

	if (parsed.port != null && parsed.port != "")
		value += ":" + parsed.port;

	return value;
}

function parse(value) {
	let raw = "" + (value == null ? "" : value);
	let result = {
		raw: raw,
		scheme: "",
		userinfo: "",
		host: "",
		port: "",
		path: "",
		query: {},
		fragment: ""
	};

	let m = match(raw, /^([a-zA-Z][a-zA-Z0-9+.-]*):\/\/(.*)$/);
	if (m == null)
		return result;

	result.scheme = lc(m[1]);
	let rest = m[2];

	let hash = index(rest, "#");
	if (hash >= 0) {
		result.fragment = percent_decode(substr(rest, hash + 1), false);
		rest = substr(rest, 0, hash);
	}

	let question = index(rest, "?");
	if (question >= 0) {
		result.query = parse_query(substr(rest, question + 1));
		rest = substr(rest, 0, question);
	}

	let slash = index(rest, "/");
	let authority = slash < 0 ? rest : substr(rest, 0, slash);
	result.path = slash < 0 ? "" : substr(rest, slash);

	let at = -1;
	for (let i = 0; i < length(authority); i++) {
		if (substr(authority, i, 1) == "@")
			at = i;
	}

	if (at >= 0) {
		result.userinfo = substr(authority, 0, at);
		authority = substr(authority, at + 1);
	}

	if (substr(authority, 0, 1) == "[") {
		let close = index(authority, "]");
		if (close >= 0) {
			result.host = substr(authority, 0, close + 1);
			if (substr(authority, close + 1, 1) == ":")
				result.port = substr(authority, close + 2);
		}
		else {
			result.host = authority;
		}
	}
	else {
		let colon = -1;
		for (let i = 0; i < length(authority); i++) {
			if (substr(authority, i, 1) == ":")
				colon = i;
		}

		if (colon >= 0) {
			result.host = substr(authority, 0, colon);
			result.port = substr(authority, colon + 1);
		}
		else {
			result.host = authority;
		}
	}

	return result;
}

function resolve_relative(base_value, ref_value) {
	let base = type(base_value) == "object" ? base_value : parse(base_value);
	let ref = "" + (ref_value == null ? "" : ref_value);

	if (ref == "")
		return "";

	if (match(ref, /^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//) != null)
		return ref;

	if (substr(ref, 0, 2) == "//")
		return base.scheme + ":" + ref;

	if (substr(ref, 0, 1) == "/")
		return base.scheme + "://" + authority_of(base) + ref;

	let dir = base.path;
	let slash = -1;
	for (let i = 0; i < length(dir); i++) {
		if (substr(dir, i, 1) == "/")
			slash = i;
	}

	if (slash >= 0)
		dir = substr(dir, 0, slash + 1);
	else
		dir = "/";

	let joined = dir + ref;
	let parts = [];

	for (let part in split(joined, "/")) {
		if (part == "" || part == ".")
			continue;

		if (part == "..") {
			if (length(parts) > 0)
				pop(parts);
			continue;
		}

		push(parts, part);
	}

	let path = "/" + join("/", parts);
	if (substr(joined, length(joined) - 1, 1) == "/" && substr(path, length(path) - 1, 1) != "/")
		path += "/";

	return base.scheme + "://" + authority_of(base) + path;
}

function without_fragment(parsed) {
	let value = parsed.scheme + "://" + authority_of(parsed) + parsed.path;
	if (length(keys(parsed.query)) > 0)
		value += "?" + query_encode(parsed.query);

	return value;
}

function host_matches(host, suffix) {
	host = lc("" + (host == null ? "" : host));
	suffix = lc("" + (suffix == null ? "" : suffix));

	return host == suffix || (length(host) > length(suffix) && substr(host, length(host) - length(suffix), length(suffix)) == suffix);
}

return {
	percent_decode,
	percent_encode,
	parse_query,
	query_encode,
	parse,
	resolve_relative,
	without_fragment,
	authority_of,
	host_matches
};
