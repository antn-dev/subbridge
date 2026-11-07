// Client identities (Happ, Incy, v2rayTun) and the order in which they are
// tried. Many panels only hand out a subscription to a known app, so the
// fetcher imitates one identity at a time until it receives real servers.
//
// SubBridge runs on Linux, so Happ on Linux is the default identity. The
// other presets stay as fallbacks for links that were generated for another
// client. The User Agent tab can replace all of this with a user-supplied
// identity (for example a copy of a phone, to share its device slot).

let util = require("util");

function make_headers(user_agent, device_os, ver_os, app_version, model, locale, hwid) {
	return {
		"User-Agent": user_agent,
		"X-HWID": hwid == null || hwid == "" ? "random" : hwid,
		"X-Device-OS": device_os,
		"X-Ver-OS": ver_os,
		"X-App-Version": app_version,
		"X-Device-model": model,
		"X-Device-Locale": locale == null || locale == "" ? "ru" : locale
	};
}

const PRESETS = [
	{
		id: "happ-linux",
		label: "Happ на Linux",
		client: "happ",
		device: "linux",
		headers: make_headers("Happ/6.1.0/linux catalyst/2610091518671", "Linux", "6.6.0", "6.1.0", "Linux PC")
	},
	{
		id: "happ-macos",
		label: "Happ на macOS",
		client: "happ",
		device: "macos",
		headers: make_headers("Happ/6.1.0/macos catalyst/2610091518671", "macOS", "15.3.1", "6.1.0", "MacBook")
	},
	{
		id: "happ-ios",
		label: "Happ на iOS",
		client: "happ",
		device: "ios",
		headers: make_headers("Happ/6.1.0/ios catalyst/2610091518671", "iOS", "18.3.1", "6.1.0", "iPhone")
	},
	{
		id: "happ-android",
		label: "Happ на Android",
		client: "happ",
		device: "android",
		headers: make_headers("Happ/6.1.0/android catalyst/2610091518671", "Android", "14", "6.1.0", "Pixel 7")
	},
	{
		id: "incy-ios",
		label: "Incy на iOS",
		client: "incy",
		device: "ios",
		headers: make_headers("Incy/1.0", "iOS", "18.3.1", "1.0.0", "iPhone")
	},
	{
		id: "incy-android",
		label: "Incy на Android",
		client: "incy",
		device: "android",
		headers: make_headers("Incy/1.0", "Android", "14", "1.0.0", "Pixel 7")
	},
	{
		id: "v2raytun-ios",
		label: "v2rayTun на iOS",
		client: "v2raytun",
		device: "ios",
		headers: make_headers("v2rayTun/1.0", "iOS", "18.3.1", "1.10.0", "iPhone")
	},
	{
		id: "v2raytun-android",
		label: "v2rayTun на Android",
		client: "v2raytun",
		device: "android",
		headers: make_headers("v2rayTun/1.0", "Android", "14", "1.10.0", "Pixel 7")
	}
];

function normalize_device(value) {
	switch (value) {
	case "mac":
		return "macos";
	case "win":
		return "windows";
	default:
		return value;
	}
}

function normalize_client(value) {
	switch (value) {
	case "v2ray":
		return "v2raytun";
	case "singbox":
		return "sing-box";
	default:
		return value;
	}
}

// parse_target decodes the device/client hint from a URL fragment such as
// "#macos-happ" or "#ios-incy". The fragment is never sent to the server, but
// it tells us which handoff page the provider prepared.
function parse_target(fragment) {
	let target = { client: "", device: "" };
	let value = util.lower(util.trim("" + (fragment == null ? "" : fragment)));

	for (let part in split(replace(replace(replace(value, /^\/+/, ""), /\/+$/, ""), /[-_+ ]+/, " "), " ")) {
		if (part == "")
			continue;

		switch (part) {
		case "ios":
		case "android":
		case "androidtv":
		case "macos":
		case "mac":
		case "windows":
		case "win":
		case "linux":
		case "tv":
			if (target.device == "")
				target.device = normalize_device(part);
			break;

		case "happ":
		case "incy":
		case "v2raytun":
		case "v2ray":
		case "singbox":
			if (target.client == "")
				target.client = normalize_client(part);
			break;
		}
	}

	return target;
}

function by_id(id) {
	for (let preset in PRESETS) {
		if (preset.id == id)
			return preset;
	}

	return null;
}

function default_for_client(client) {
	switch (client) {
	case "happ":
		return "happ-linux";
	case "incy":
		return "incy-ios";
	case "v2raytun":
		return "v2raytun-ios";
	default:
		return "";
	}
}

// custom builds a single identity from the User Agent tab. An empty X-HWID
// keeps the normal persistent random value; a filled one is sent verbatim so
// the provider can see the same device id as the user's phone.
function custom(cfg) {
	return {
		id: "custom",
		label: "Свои заголовки",
		client: "",
		device: "",
		headers: make_headers(
			cfg.ua_user_agent,
			cfg.ua_device_os,
			cfg.ua_ver_os,
			cfg.ua_app_version,
			cfg.ua_device_model,
			cfg.ua_device_locale,
			cfg.ua_hwid
		)
	};
}

// candidates returns the presets to try, in order. A fragment hint wins, then
// the common Happ/Linux identity, then the other fallbacks.
function candidates(target) {
	let out = [];
	let seen = {};

	function add(id) {
		if (id == "" || seen[id] == true)
			return;

		let preset = by_id(id);
		if (preset == null)
			return;

		seen[id] = true;
		push(out, preset);
	}

	if (target.client != "") {
		if (target.device != "")
			add(target.client + "-" + target.device);

		add(default_for_client(target.client));
	}

	add("happ-linux");
	add("happ-macos");
	add("incy-ios");
	add("v2raytun-ios");

	return out;
}

return {
	PRESETS,
	make_headers,
	custom,
	normalize_device,
	normalize_client,
	parse_target,
	candidates,
	by_id,
	default_for_client
};
