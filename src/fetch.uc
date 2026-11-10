// Subscription download and handoff resolution.
//
// Providers no longer hand out a plain subscription URL. They give an "app"
// link (for example https://provider/config.php?...&domen=sub.example#macos-happ)
// that opens a page with an "Добавить подписку" button. This module follows
// those pages until it reaches the real payload.
//
// curl is used when present (it exposes the status line and Location header,
// which makes app-link redirects resolvable). uclient-fetch is the fallback;
// it follows redirects on its own and is enough for ordinary handoff pages.

let util = require("util");
let url = require("url");
let presets = require("presets");
let hwid = require("hwid");
let limits = require("limits");
let fs = require("fs");

const MAX_HANDOFF_DEPTH = 5;
const MAX_REDIRECTS = 5;
const MAX_BODY_BYTES = limits.MAX_BODY_BYTES;

let transport_cache = null;

function transport() {
	if (transport_cache != null)
		return transport_cache;

	transport_cache = util.find_in_path("curl");
	if (transport_cache == null)
		transport_cache = util.find_in_path("uclient-fetch");

	return transport_cache;
}

function ends_with(value, suffix) {
	value = "" + (value == null ? "" : value);
	suffix = "" + (suffix == null ? "" : suffix);

	if (length(value) < length(suffix))
		return false;

	return substr(value, length(value) - length(suffix), length(suffix)) == suffix;
}

function utf8_chr(code) {
	if (code < 0x80)
		return chr(code);

	let out = "";

	if (code < 0x800) {
		out += chr(0xC0 | (code >> 6));
		out += chr(0x80 | (code & 0x3F));
		return out;
	}

	if (code < 0x10000) {
		out += chr(0xE0 | (code >> 12));
		out += chr(0x80 | ((code >> 6) & 0x3F));
		out += chr(0x80 | (code & 0x3F));
		return out;
	}

	out += chr(0xF0 | (code >> 18));
	out += chr(0x80 | ((code >> 12) & 0x3F));
	out += chr(0x80 | ((code >> 6) & 0x3F));
	out += chr(0x80 | (code & 0x3F));

	return out;
}

function html_unescape(value) {
	let s = "" + (value == null ? "" : value);

	s = replace(s, /&quot;/g, "\"");
	s = replace(s, /&#39;/g, "'");
	s = replace(s, /&apos;/g, "'");
	s = replace(s, /&lt;/g, "<");
	s = replace(s, /&gt;/g, ">");
	s = replace(s, /&nbsp;/g, " ");

	// Numeric entities are rare in handoff pages but cheap to support.
	let out = "";
	let i = 0;

	while (i < length(s)) {
		let ch = substr(s, i, 2);
		if (ch != "&#") {
			out += substr(s, i, 1);
			i++;
			continue;
		}

		let end = index(substr(s, i), ";");
		if (end < 0) {
			out += substr(s, i, 1);
			i++;
			continue;
		}

		let body = substr(s, i + 2, end - 2);
		let code = null;

		if (substr(lc(body), 0, 1) == "x")
			code = hex(substr(body, 1));
		else
			code = int(body);

		if (code != null && code > 0 && code < 1114112) {
			out += utf8_chr(code);
			i += end + 1;
			continue;
		}

		out += substr(s, i, 1);
		i++;
	}

	return replace(out, /&amp;/g, "&");
}

function normalize_embedded_url(raw) {
	let s = html_unescape(raw);

	try {
		s = url.percent_decode(s, false);
	}
	catch (e) {
	}

	let m = match(s, /(https?:\/\/[^[:space:]"'<>\\)]+)/i);
	if (m == null)
		return "";

	return replace(m[1], /[.,;]+$/, "");
}

function unwrap_app_link(raw) {
	let parsed = url.parse(raw);

	if ((parsed.scheme == "http" || parsed.scheme == "https") && parsed.host != "")
		return raw;

	let inner = normalize_embedded_url(raw);
	if (inner != "")
		return inner;

	return raw;
}

function looks_like_html(body) {
	let s = lc(util.trim(body));
	if (s == "")
		return false;

	if (length(s) > 1024)
		s = substr(s, 0, 1024);

	return substr(s, 0, 15) == "<!doctype html" ||
		substr(s, 0, 5) == "<html" ||
		index(s, "<html") >= 0 ||
		index(s, "<head") >= 0 ||
		index(s, "<body") >= 0;
}

function header_lines(headers) {
	let order = [
		"User-Agent",
		"X-HWID",
		"X-Device-OS",
		"X-Ver-OS",
		"X-App-Version",
		"X-Device-model",
		"X-Device-Locale"
	];

	let lines = [];
	let used = {};

	for (let name in order) {
		for (let key in keys(headers)) {
			if (lc(key) != lc(name))
				continue;

			push(lines, name + ": " + headers[key]);
			used[key] = true;
			break;
		}
	}

	let rest = [];
	for (let key in keys(headers)) {
		if (used[key] != true)
			push(rest, key);
	}

	sort(rest);
	for (let key in rest)
		push(lines, key + ": " + headers[key]);

	return lines;
}

function prepare_headers(headers, hwid_path) {
	let out = {};

	for (let key in keys(headers)) {
		let value = headers[key];

		if (lc(key) == "x-hwid" && lc("" + value) == "random")
			value = hwid.get_or_create(hwid_path);

		out[key] = value;
	}

	return out;
}

// A redirect or handoff link can point at a different host. Identity headers
// (X-HWID and any custom X-*) belong to the subscription origin only; sending
// them to an arbitrary host would leak the device identity. A plain
// User-Agent is enough for CDN-like hops.
function public_headers(headers) {
	let out = {};

	for (let key in keys(headers)) {
		if (lc(key) == "user-agent")
			out[key] = headers[key];
	}

	return out;
}

function trusted_headers(headers, host, trusted) {
	if (trusted == null || trusted[lc(host)] == true)
		return headers;

	return public_headers(headers);
}

function check_body_size(path) {
	let st = fs.stat(path);
	if (st != null && st.type == "file" && st.size > MAX_BODY_BYTES)
		die("subscription is too large (limit " + MAX_BODY_BYTES + " bytes)");
}

function resolve_url(raw) {
	let parsed = url.parse(raw);

	if (parsed.path != "/happ")
		return raw;

	let key = "";
	let value = "";

	if (type(parsed.query.token) == "string" && parsed.query.token != "") {
		key = "token";
		value = parsed.query.token;
	}
	else if (type(parsed.query.id) == "string" && parsed.query.id != "") {
		key = "id";
		value = parsed.query.id;
	}
	else {
		return raw;
	}

	return parsed.scheme + "://" + url.authority_of(parsed) + "/api/sub?" + key + "=" + url.percent_encode(value, true);
}

function first_header(headers, name) {
	for (let line in headers) {
		let pos = index(line, ":");
		if (pos < 0)
			continue;

		if (lc(util.trim(substr(line, 0, pos))) == lc(name))
			return util.trim(substr(line, pos + 1));
	}

	return "";
}

function read_text(path) {
	let value = util.read_file(path);
	return value == null ? "" : value;
}

function http_once(target, headers, timeout, workdir) {
	let binary = transport();
	if (binary == null)
		die("neither curl nor uclient-fetch is installed");

	let body_path = workdir + "/body";
	let header_path = workdir + "/headers";

	// Remove leftovers: a failed request must not return the previous body.
	util.command("rm -f " + util.shell_quote(body_path) + " " + util.shell_quote(header_path));

	if (ends_with(binary, "/curl") || binary == "curl") {
		let argv = [
			binary,
			"-sS",
			"--http1.1",
			"--max-time", "" + timeout,
			"--max-filesize", "" + MAX_BODY_BYTES,
			"-D", header_path,
			"-o", body_path,
			"-w", "%{http_code}"
		];

		for (let key in keys(headers))
			push(argv, "-H", key + ": " + headers[key]);

		push(argv, unwrap_app_link(target));

		let result = util.command_argv(argv);
		let status = util.to_int(util.trim(result.output), 0);

		if (result.code != 0) {
			die("download failed: " + (util.first_line(result.output) == "" ? "curl exited with " + result.code : util.first_line(result.output)));
		}

		check_body_size(body_path);

		let header_text = read_text(header_path);
		let lines = util.split_lines(header_text);
		let location = first_header(lines, "location");

		return {
			status: status,
			body: read_text(body_path),
			location: location,
			url: target
		};
	}

	let argv = [
		binary,
		"-q",
		"-O", body_path,
		"--timeout=" + timeout
	];

	for (let key in keys(headers))
		push(argv, "--header=" + key + ": " + headers[key]);

	push(argv, unwrap_app_link(target));

	let result = util.command_argv(argv);

	if (result.code != 0) {
		let message = util.first_line(result.output);
		die("download failed: " + (message == "" ? "uclient-fetch exited with " + result.code : message));
	}

	check_body_size(body_path);

	return {
		status: 200,
		body: read_text(body_path),
		location: "",
		url: target
	};
}

function fetch_follow(raw, headers, timeout, workdir, trusted) {
	let current = unwrap_app_link(raw);

	for (let depth = 0; depth <= MAX_REDIRECTS; depth++) {
		let host = lc(url.parse(current).host);
		let response = http_once(current, trusted_headers(headers, host, trusted), timeout, workdir);

		if (response.status >= 300 && response.status < 400) {
			if (response.location == "")
				die("redirect from " + current + " without a Location header");

			current = unwrap_app_link(url.resolve_relative(current, response.location));
			continue;
		}

		if (response.status != 200)
			die("unexpected status " + response.status + ": " + substr(util.trim(response.body), 0, 200));

		return { body: response.body, url: current };
	}

	die("too many redirects: " + raw);
}

function is_blocked_host(host) {
	host = lc("" + (host == null ? "" : host));

	if (host == "")
		return true;

	let blocked = [
		"apps.apple.com",
		"play.google.com",
		"telegram.org",
		"t.me",
		"yandex.ru",
		"google.com",
		"googleapis.com"
	];

	for (let suffix in blocked) {
		if (host == suffix || ends_with(host, suffix))
			return true;
	}

	return false;
}

function extract_domain_subscription(parsed) {
	let id = "";
	let host = "";

	if (type(parsed.query.subscription) == "string" && parsed.query.subscription != "")
		id = parsed.query.subscription;
	else if (type(parsed.query.sub) == "string" && parsed.query.sub != "")
		id = parsed.query.sub;

	if (type(parsed.query.domen) == "string" && parsed.query.domen != "")
		host = parsed.query.domen;
	else if (type(parsed.query.domain) == "string" && parsed.query.domain != "")
		host = parsed.query.domain;

	if (id == "" || host == "")
		return "";

	let clean_id = replace(id, /^\/+/, "");

	if (index(host, "://") >= 0) {
		let target = url.parse(host);
		if (target.host == "")
			return "";

		if (index(target.host, ".") < 0 && index(target.host, ":") < 0)
			return "";

		return target.scheme + "://" + url.authority_of(target) + "/" + clean_id;
	}

	if (index(host, ".") < 0 && index(host, ":") < 0)
		return "";

	return "https://" + host + "/" + clean_id;
}

function extract_legacy(parsed) {
	for (let key in ["token", "id"]) {
		let value = parsed.query[key];
		if (type(value) != "string" || value == "")
			continue;

		return parsed.scheme + "://" + url.authority_of(parsed) + "/api/sub?" + key + "=" + url.percent_encode(value, true);
	}

	return "";
}

function first_group(re, body, index) {
	let m = match(body, re);
	if (m == null || length(m) <= index)
		return "";

	return html_unescape(util.trim(m[index]));
}

function normalize_handoff_value(base_url, raw) {
	let value = html_unescape(util.trim(raw));
	if (value == "")
		return "";

	let parsed = url.parse(value);
	if ((parsed.scheme == "http" || parsed.scheme == "https") && parsed.host != "")
		return value;

	let inner = normalize_embedded_url(value);
	if (inner != "")
		return inner;

	let absolute = url.resolve_relative(base_url, value);
	if (absolute == "")
		return "";

	let check = url.parse(absolute);
	if (check.scheme != "http" && check.scheme != "https")
		return "";

	return absolute;
}

function extract_deep_link(body) {
	let re = /[a-z][a-z0-9+.\-]*:\/\/(import-remote-profile|import|install|add)[\/?=]([^[:space:]"'<>]+)/i;
	let matches = match(body, re);

	// match() returns only the first match; scan the body in chunks so a page
	// with several deep links still finds a usable one.
	let offset = 0;
	while (offset < length(body)) {
		let m = match(substr(body, offset), re);
		if (m == null)
			break;

		let inner = normalize_embedded_url(m[2]);
		if (inner != "")
			return inner;

		let full = m[0];
		let at = index(substr(body, offset), full);
		if (at < 0)
			break;

		offset += at + length(full);
	}

	return "";
}

function extract_redirect(body) {
	let m = match(body, /(deep\s*link|deeplink|sub(scription)?[_a-z]*(url|uri|link))\s*[:=]\s*["']([^"']+)["']/i);
	if (m != null) {
		let inner = normalize_embedded_url(m[4]);
		if (inner != "")
			return inner;
	}

	m = match(body, /<meta[^>]+http-equiv\s*=\s*["']?refresh["']?[^>]+content\s*=\s*["'][^"']*?url\s*=\s*([^"';[:space:]]+)/i);
	if (m != null) {
		let inner = normalize_embedded_url(m[1]);
		if (inner != "")
			return inner;
	}

	return "";
}

function is_handoff_candidate(parsed) {
	if (parsed.scheme != "http" && parsed.scheme != "https")
		return false;

	if (is_blocked_host(parsed.host))
		return false;

	for (let key in ["subscription", "sub", "token", "id", "domen", "domain"]) {
		if (type(parsed.query[key]) == "string" && parsed.query[key] != "")
			return true;
	}

	return match(parsed.path, /(setup|install|download|handoff|\/dl\/)/i) != null;
}

function handoff_score(parsed, target) {
	let score = 0;
	let client = presets.normalize_client(lc(type(parsed.query.client) == "string" ? parsed.query.client : ""));
	let device = presets.normalize_device(lc(type(parsed.query.device) == "string" ? parsed.query.device : ""));

	if (target.client != "" && client == target.client)
		score += 4;

	if (target.device != "" && device == target.device)
		score += 2;

	if (client == "happ")
		score++;

	return score;
}

function extract_handoff_link(base_url, target, body) {
	let candidates = [];

	function add(raw, allow_plain) {
		if (raw == "")
			return;

		let absolute = url.resolve_relative(base_url, raw);
		if (absolute == "")
			return;

		let parsed = url.parse(absolute);
		if (!is_handoff_candidate(parsed)) {
			// A script redirect often points at a plain file such as
			// /profiles.json. Accept it when the name clearly belongs to a
			// subscription, but never follow an asset or a landing page.
			if (allow_plain != true || parsed.scheme != "http" && parsed.scheme != "https")
				return;

			if (is_blocked_host(parsed.host))
				return;

			if (match(parsed.path, /(\.json|\.txt|\.yaml|\.yml|sub|token|clash|config)/i) == null)
				return;
		}

		push(candidates, { url: absolute, score: handoff_score(parsed, target) });
	}

	let offset = 0;
	while (offset < length(body)) {
		let m = match(substr(body, offset), /href\s*=\s*["']([^"']+)["']/i);
		if (m == null)
			break;

		add(html_unescape(util.trim(m[1])), false);

		let full = m[0];
		let at = index(substr(body, offset), full);
		if (at < 0)
			break;

		offset += at + length(full);
	}

	offset = 0;
	while (offset < length(body)) {
		let m = match(substr(body, offset), /(location(\.href)?|window\.location)\s*=\s*["']([^"']+)["']/i);
		if (m == null)
			break;

		add(html_unescape(util.trim(m[3])), true);

		let full = m[0];
		let at = index(substr(body, offset), full);
		if (at < 0)
			break;

		offset += at + length(full);
	}

	if (length(candidates) == 0)
		return "";

	let best = candidates[0];

	for (let candidate in candidates) {
		if (candidate.score > best.score)
			best = candidate;
	}

	return best.url;
}

function extract_subscription_url(base_url, target, body) {
	let value = first_group(/id\s*=\s*["']?subLinkField["']?[^>]*?value\s*=\s*["']([^"']+)["']/i, body, 1);
	if (value != "") {
		let next = normalize_handoff_value(base_url, value);
		if (next != "")
			return next;
	}

	value = first_group(/value\s*=\s*["']([^"']+)["'][^>]*?id\s*=\s*["']?subLinkField["']?/i, body, 1);
	if (value != "") {
		let next = normalize_handoff_value(base_url, value);
		if (next != "")
			return next;
	}

	value = extract_deep_link(body);
	if (value != "")
		return value;

	value = extract_redirect(body);
	if (value != "")
		return value;

	value = extract_handoff_link(base_url, target, body);
	if (value != "")
		return value;

	let parsed = url.parse(base_url);

	value = extract_domain_subscription(parsed);
	if (value != "")
		return value;

	value = extract_legacy(parsed);
	if (value != "")
		return value;

	die("subscription handoff page does not contain a subscription URL");
}

// fetch_subscription downloads a subscription and returns the body together
// with the resolved URL and the headers that were actually sent.
function fetch_subscription(raw_url, headers, hwid_path, timeout, workdir) {
	let resolved = resolve_url(raw_url);
	let prepared = prepare_headers(headers, hwid_path);
	let target = presets.parse_target(url.parse(raw_url).fragment);
	let trusted = {};

	// Only the subscription origin (and the host named by the provider in
	// ?domen=) may receive X-HWID and custom identity headers.
	trusted[lc(url.parse(unwrap_app_link(resolved)).host)] = true;

	// A handoff link often carries the real subscription host in ?domen=... and
	// the id in ?subscription=.... The direct address is cleaner than the
	// per-app page, so try it first.
	let direct = extract_domain_subscription(url.parse(resolved));
	if (direct != "") {
		trusted[lc(url.parse(unwrap_app_link(direct)).host)] = true;

		if (direct != resolved) {
			try {
				let attempt = fetch_follow(direct, prepared, timeout, workdir, trusted);
				if (!looks_like_html(attempt.body)) {
					return { data: attempt.body, url: attempt.url, headers: prepared };
				}
			}
			catch (e) {
				// Fall through to the normal handoff flow.
			}
		}
	}

	let current = resolved;

	for (let depth = 0; depth < MAX_HANDOFF_DEPTH; depth++) {
		let response = fetch_follow(current, prepared, timeout, workdir, trusted);

		if (!looks_like_html(response.body))
			return { data: response.body, url: response.url, headers: prepared };

		let next = extract_subscription_url(response.url, target, response.body);

		if (next == "" || next == current)
			die("subscription handoff page does not expose a subscription URL");

		current = next;
	}

	die("subscription handoff did not resolve after " + MAX_HANDOFF_DEPTH + " pages");
}

return {
	transport,
	html_unescape,
	normalize_embedded_url,
	unwrap_app_link,
	looks_like_html,
	header_lines,
	prepare_headers,
	public_headers,
	trusted_headers,
	resolve_url,
	fetch_follow,
	is_blocked_host,
	extract_domain_subscription,
	extract_legacy,
	normalize_handoff_value,
	extract_deep_link,
	extract_redirect,
	extract_handoff_link,
	extract_subscription_url,
	fetch_subscription
};
