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
let fetch = require("fetch");
let limits = require("limits");

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

function dies(name, fn, needle) {
	let ok = false;

	try {
		fn();
	}
	catch (e) {
		ok = needle == null || index("" + e, needle) >= 0;
	}

	check(name, ok);
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
// Regression: without /g only the first apostrophe was escaped, so the rest of
// the value escaped the quoted string and became shell code.
equal("shell_quote escapes every quote", util.shell_quote("a'b'c"), "'a'\\''b'\\''c'");
equal("shell_quote keeps plain value", util.shell_quote("plain value"), "'plain value'");
equal("shell_quote empty", util.shell_quote(""), "''");
equal("split_lines", sprintf("%J", util.split_lines("a\r\nb\n")), "[ \"a\", \"b\", \"\" ]");
contains("first_line", util.first_line("\n  sing-box version 1.14\n"), "sing-box version 1.14");
equal("random_hex length", length(util.random_hex(8)), 16);
check("random_hex differs", util.random_hex(8) != util.random_hex(8));
contains("temp_path suffix", util.temp_path("/tmp/x"), "/tmp/x.tmp.");
check("temp_path differs", util.temp_path("/tmp/x") != util.temp_path("/tmp/x"));

let temp = util.temp_dir("subbridge-test");
let temp_stat = fs.stat(temp);
check("temp_dir is a directory", temp_stat != null && temp_stat.type == "directory");
equal("ensure_dir existing", util.ensure_dir(temp, 0700), true);
let temp_file = temp + "/file";
util.write_file(temp_file, "x");
equal("ensure_dir rejects a file", util.ensure_dir(temp_file, 0700), false);
util.remove_dir(temp);

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

// Regression: pad_base64 used regexes without /g, so a wrapped payload kept
// its line breaks (and URL-safe '-'/'_' were only fixed in the first place).
let wrapped = b64enc(payload);
wrapped = substr(wrapped, 0, 8) + "\n" + substr(wrapped, 8);
equal("decode wrapped base64", decode.decode(wrapped), payload);

let urlsafe = replace(replace(b64enc("{\"remarks\":\"?~>\"}"), /\+/g, "-"), /\//g, "_");
equal("decode url-safe base64", decode.decode(urlsafe), "{\"remarks\":\"?~>\"}");

// The old implementation compared an 8-character prefix with "[" and could
// therefore never be true for an array.
check("plain text array", decode.looks_like_plain_text("[1,2]") == true);
check("plain text object", decode.looks_like_plain_text("{\"a\":1}") == true);
check("plain text base64", decode.looks_like_plain_text("eyJhIjoxfQ==") == false);

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

// --- fetch -----------------------------------------------------------------

let identity = {
	"User-Agent": "Happ/1.0/linux",
	"X-HWID": "device-id",
	"X-Device-OS": "Linux"
};
let public = fetch.public_headers(identity);
equal("public headers keep user agent", public["User-Agent"], "Happ/1.0/linux");
check("public headers drop hwid", public["X-HWID"] == null);
check("public headers drop device", public["X-Device-OS"] == null);

let trusted = { "sub.example.com": true };
check("trusted host keeps headers",
	fetch.trusted_headers(identity, "sub.example.com", trusted)["X-HWID"] == "device-id");
check("foreign host drops hwid",
	fetch.trusted_headers(identity, "evil.example.net", trusted)["X-HWID"] == null);
check("foreign host keeps user agent",
	fetch.trusted_headers(identity, "evil.example.net", trusted)["User-Agent"] == "Happ/1.0/linux");

// --- limits ----------------------------------------------------------------

check("body limit is set", limits.MAX_BODY_BYTES > 0);
check("endpoint limit is set", limits.MAX_ENDPOINTS > 0);
check("profile limit is set", limits.MAX_PROFILES > 0);

let many_lines = "";
for (let i = 0; i <= limits.MAX_ENDPOINTS; i++)
	many_lines += "vless://11111111-1111-1111-1111-111111111111@127.0.0.1:443#n\n";

dies("too many endpoints rejected", function() {
	parse.parse(many_lines);
}, "too many endpoints");

let many_profiles = "[";
for (let i = 0; i <= limits.MAX_PROFILES; i++)
	many_profiles += (i > 0 ? "," : "") + "{\"remarks\":\"p\",\"outbounds\":[]}";
many_profiles += "]";

dies("too many profiles rejected", function() {
	parse.parse(many_profiles);
}, "too many profiles");

let big_chunk = "";
for (let i = 0; i < 1024; i++)
	big_chunk += "a";

let big_profile = "";
for (let i = 0; i < 600; i++)
	big_profile += big_chunk;

dies("oversized profile rejected", function() {
	parse.parse("[{\"remarks\":\"" + big_profile + "\",\"outbounds\":[]}]");
}, "profile is too large");

// --- net -------------------------------------------------------------------

let net = require("net");

check("loopback blocked", net.blocked_address("127.0.0.1") == true);
check("private 10/8 blocked", net.blocked_address("10.1.2.3") == true);
check("private 172.16/12 blocked", net.blocked_address("172.16.0.1") == true);
check("public 172.32 allowed", net.blocked_address("172.32.0.1") == false);
check("private 192.168/16 blocked", net.blocked_address("192.168.1.1") == true);
check("link-local blocked", net.blocked_address("169.254.1.1") == true);
check("cgnat blocked", net.blocked_address("100.64.0.1") == true);
check("broadcast blocked", net.blocked_address("255.255.255.255") == true);
check("public v4 allowed", net.blocked_address("1.1.1.1") == false);
check("ipv6 loopback blocked", net.blocked_address("::1") == true);
check("ipv6 link-local blocked", net.blocked_address("fe80::1") == true);
check("ipv6 ula blocked", net.blocked_address("fd00::1") == true);
check("ipv6 mapped loopback blocked", net.blocked_address("::ffff:127.0.0.1") == true);
check("ipv6 public allowed", net.blocked_address("2606:4700::1111") == false);

// Regression: the first version compared IPv6 as text, so an uncompressed
// loopback address ("0:0:0:0:0:0:0:1") was treated as public.
check("ipv6 loopback uncompressed", net.blocked_address("0:0:0:0:0:0:0:1") == true);
check("ipv6 loopback padded", net.blocked_address("0000:0000:0000:0000:0000:0000:0000:0001") == true);
check("ipv6 unspecified", net.blocked_address("::") == true);
check("ipv6 link-local full", net.blocked_address("fe80:0:0:0:0:0:0:1") == true);
check("ipv6 link-local upper bound", net.blocked_address("febf::1") == true);
check("ipv6 fec0 allowed", net.blocked_address("fec0::1") == false);
check("ipv6 ula full", net.blocked_address("fd00:0:0:0:0:0:0:1") == true);
check("ipv6 ula fc00", net.blocked_address("fc00::1") == true);
check("ipv6 multicast blocked", net.blocked_address("ff02::1") == true);
check("ipv6 documentation blocked", net.blocked_address("2001:db8::1") == true);
check("ipv6 discard blocked", net.blocked_address("100::1") == true);
check("ipv6 zone id blocked", net.blocked_address("fe80::1%eth0") == true);

// An embedded IPv4 address is what the router actually reaches, in every
// transition prefix.
check("ipv6 mapped public allowed", net.blocked_address("::ffff:1.1.1.1") == false);
check("ipv6 mapped private blocked", net.blocked_address("::ffff:10.0.0.1") == true);
check("ipv6 mapped hex loopback blocked", net.blocked_address("::ffff:7f00:1") == true);
check("ipv6 nat64 public allowed", net.blocked_address("64:ff9b::1.1.1.1") == false);
check("ipv6 nat64 private blocked", net.blocked_address("64:ff9b::10.0.0.1") == true);
check("6to4 private blocked", net.blocked_address("2002:0a00:0001::1") == true);
check("6to4 public allowed", net.blocked_address("2002:0101:0101::1") == false);

// An address that looks like IPv6 but does not parse is blocked rather than
// assumed public: the kernel may still connect to it.
check("malformed ipv6 blocked", net.blocked_address("1:::2") == true);
check("ipv6 with five colons blocked", net.blocked_address(":::::") == true);

// Integer and octal spellings are not IPv4 literals for the resolver either,
// so they must not be accepted as one.
check("decimal integer not ipv4", net.is_ipv4("2130706433") == false);
check("octal not ipv4", net.is_ipv4("0177.0.0.1") == false);
check("hex not ipv4", net.is_ipv4("0x7f000001") == false);

check("localhost host blocked", net.host_blocked("localhost") == true);
check("mDNS host blocked", net.host_blocked("printer.local") == true);
check("internal zone blocked", net.host_blocked("router.internal") == true);
check("public host allowed", net.host_blocked("sub.example.com") == false);
check("host with port blocked", net.host_blocked("127.0.0.1:8080") == true);
check("bracketed ipv6 blocked", net.host_blocked("[::1]") == true);

check("file scheme rejected", net.scheme_allowed("file") == false);
check("gopher scheme rejected", net.scheme_allowed("gopher") == false);
check("http scheme allowed", net.scheme_allowed("HTTP") == true);
check("https scheme allowed", net.scheme_allowed("https") == true);

// --- result ----------------------------------------------------------------

printf("\n%d checks, %d failures\n", checks, failures);

if (failures > 0)
	exit(1);

exit(0);
