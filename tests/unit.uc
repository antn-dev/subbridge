#!/usr/bin/ucode
// Unit tests for the dependency-free ucode modules.
//
// Run from the repository root:
//   ucode -L src tests/unit.uc
//
// The tests deliberately avoid `throw`: ucode's statement is `die()` and the
// parser rejects the JavaScript spelling.

let fs = require("fs");
let util = require("util");
let url = require("url");
let decode = require("decode");
let parse = require("parse");
let presets = require("presets");
let config = require("config");

let failures = 0;
let checks = 0;

function check(name, condition) {
	checks++;

	if (condition == true)
		return;

	failures++;
	printf("FAIL: %s\n", name);
}

function equal(name, actual, expected) {
	check(name + " (got " + sprintf("%J", actual) + ", want " + sprintf("%J", expected) + ")",
		actual == expected);
}

function contains(name, haystack, needle) {
	check(name + " (" + needle + " not in " + haystack + ")", index(haystack, needle) >= 0);
}

// --- util ------------------------------------------------------------------

equal("trim", util.trim("  value \n"), "value");
equal("dirname absolute", util.dirname("/etc/config/subbridge"), "/etc/config");
equal("dirname bare", util.dirname("file"), ".");
equal("to_int", util.to_int("42", 0), 42);
equal("to_int fallback", util.to_int("not a number", 7), 7);
equal("to_bool yes", util.to_bool("yes"), true);
equal("to_bool off", util.to_bool("off"), false);
equal("shell_quote", util.shell_quote("a'b"), "'a'\\''b'");
equal("split_lines", sprintf("%J", util.split_lines("a\r\nb\n")), "[ \"a\", \"b\", \"\" ]");
contains("first_line", util.first_line("\n  sing-box version 1.14\n"), "sing-box version 1.14");

// --- url -------------------------------------------------------------------

let parsed = url.parse("https://user:pw@sub.example.com:8443/api/sub?token=a%20b&x=1#frag");

equal("url scheme", parsed.scheme, "https");
equal("url host", parsed.host, "sub.example.com");
equal("url port", parsed.port, "8443");
equal("url path", parsed.path, "/api/sub");
equal("url query token", parsed.query.token, "a b");
equal("url fragment", parsed.fragment, "frag");
equal("url userinfo", parsed.userinfo, "user:pw");
equal("authority", url.authority_of(parsed), "sub.example.com:8443");

equal("percent roundtrip", url.percent_decode(url.percent_encode("/a b?", false), false), "/a b?");
equal("resolve absolute", url.resolve_relative("https://a/b/c", "http://x/y"), "http://x/y");
equal("resolve app link", url.resolve_relative("https://a/b/c", "happ://add/https://x/y"), "happ://add/https://x/y");
equal("resolve root", url.resolve_relative("https://a/b/c", "/d"), "https://a/d");
equal("resolve relative", url.resolve_relative("https://a/b/c", "d/e"), "https://a/b/d/e");
equal("resolve dotdot", url.resolve_relative("https://a/b/c", "../d"), "https://a/d");
equal("host matches suffix", url.host_matches("sub.example.com", ".example.com"), true);
equal("host matches boundary", url.host_matches("notexample.com", ".example.com"), false);
equal("host matches exact", url.host_matches("example.com", "example.com"), true);

// --- decode ----------------------------------------------------------------

let payload = "{\"remarks\":\"x\"}";
equal("decode plain json", decode.decode(payload), payload);
equal("decode padded", decode.decode(b64enc(payload)), payload);

// Providers strip the padding; decode() must add it back.
let unpadded = replace(b64enc(payload), /=+$/, "");
equal("decode unpadded", decode.decode(unpadded), payload);
check("plain prefix", decode.plain_prefix("vless://abc") == true);

// --- presets ---------------------------------------------------------------

let target = presets.parse_target("macos-happ");
equal("target client", target.client, "happ");
equal("target device", target.device, "macos");
equal("normalize device", presets.normalize_device("win"), "windows");

let candidates = presets.candidates(presets.parse_target("ios-incy"));
let candidate_ids = [];
for (let preset in candidates)
	push(candidate_ids, preset.id);

equal("first candidate", candidates[0].id, "incy-ios");
contains("candidate fallback", sprintf("%J", candidate_ids), "happ-linux");
contains("candidate mac fallback", sprintf("%J", candidate_ids), "happ-macos");

let default_candidates = presets.candidates(presets.parse_target(""));
equal("default first candidate", default_candidates[0].id, "happ-linux");

let linux = presets.by_id("happ-linux");
equal("linux os", linux.headers["X-Device-OS"], "Linux");
contains("linux user agent", linux.headers["User-Agent"], "/linux ");
equal("linux random hwid", linux.headers["X-HWID"], "random");

let custom = presets.custom({
	ua_user_agent: "Happ/1.0/ios phone",
	ua_device_os: "iOS",
	ua_ver_os: "18.3.1",
	ua_app_version: "1.0.0",
	ua_device_model: "iPhone",
	ua_device_locale: "ru",
	ua_hwid: "phone-hwid"
});
equal("custom label", custom.label, "Свои заголовки");
equal("custom user agent", custom.headers["User-Agent"], "Happ/1.0/ios phone");
equal("custom os", custom.headers["X-Device-OS"], "iOS");
equal("custom hwid", custom.headers["X-HWID"], "phone-hwid");

let custom_random = presets.custom({
	ua_user_agent: "Happ/1.0/ios phone",
	ua_device_os: "iOS",
	ua_ver_os: "18.3.1",
	ua_app_version: "1.0.0",
	ua_device_model: "iPhone",
	ua_device_locale: "",
	ua_hwid: ""
});
equal("custom random hwid", custom_random.headers["X-HWID"], "random");
equal("custom default locale", custom_random.headers["X-Device-Locale"], "ru");

// --- parse -----------------------------------------------------------------

let profiles_raw = fs.readfile("tests/fixtures/profiles.json");
let profiles = parse.parse(decode.decode(profiles_raw));

equal("profile count", length(profiles.profiles), 2);
equal("endpoint count", length(profiles.endpoints), 2);
equal("profile name", profiles.profiles[0].name, "Reality node");
equal("endpoint address", profiles.endpoints[0].address, "203.0.113.10");
equal("endpoint port", profiles.endpoints[0].port, 443);
equal("endpoint security", profiles.endpoints[0].security, "reality");
equal("endpoint public key", profiles.endpoints[0].public_key, "7XfDHNvz4yET_gS8UcQNJfpRiRW64sBEVSH8imcVl2I");
equal("ws transport", profiles.endpoints[1].transport.type, "ws");
equal("ws path", profiles.endpoints[1].transport.path, "/ray");
equal("ws host", profiles.endpoints[1].transport.host, "sub.example.com");
equal("tls alpn", sprintf("%J", profiles.endpoints[1].alpn), "[ \"h2\", \"http/1.1\" ]");
equal("tls insecure", profiles.endpoints[1].insecure, true);

let reality_url = parse.endpoint_url(profiles.endpoints[0]);
contains("endpoint url scheme", reality_url, "vless://11111111-1111-1111-1111-111111111111@203.0.113.10:443?");
contains("endpoint url reality", reality_url, "security=reality");
contains("endpoint url flow", reality_url, "flow=xtls-rprx-vision-udp443");
contains("endpoint url pbk", reality_url, "pbk=7XfDHNvz4yET_gS8UcQNJfpRiRW64sBEVSH8imcVl2I");

let vless_raw = fs.readfile("tests/fixtures/vless.txt");
let vless = parse.parse(decode.decode(vless_raw));

equal("vless endpoint count", length(vless.endpoints), 2);
equal("vless reality sni", vless.endpoints[0].server_name, "cdn.example.com");
equal("vless ws path", vless.endpoints[1].transport.path, "/ws");
equal("vless ws host", vless.endpoints[1].transport.host, "ws.example.com");
contains("vless url roundtrip", parse.endpoint_url(vless.endpoints[1]), "type=ws");

// --- config ----------------------------------------------------------------

check("valid https", config.valid_subscription("https://example.com/sub") == true);
check("valid http", config.valid_subscription("http://example.com/sub") == true);
check("invalid ftp", config.valid_subscription("ftp://example.com/sub") == false);
check("invalid empty", config.valid_subscription("") == false);

// --- result ----------------------------------------------------------------

printf("\n%d checks, %d failures\n", checks, failures);

if (failures > 0)
	exit(1);

exit(0);
