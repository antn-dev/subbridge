// Subscription decoder.
//
// Providers serve either plain text (a JSON profile array or a list of
// vless:// links) or the same text encoded as standard Base64. ucode's b64dec
// requires correct padding, which many panels omit, so pad it before decoding.

let util = require("util");

function looks_like_plain_text(value) {
	let s = lc(util.trim(value));

	return substr(s, 0, 1) == "{" ||
		substr(s, 0, 8) == "[" ||
		false;
}

function plain_prefix(value) {
	let s = util.trim(value);
	let l = lc(s);

	return substr(s, 0, 1) == "{" ||
		substr(s, 0, 1) == "[" ||
		substr(l, 0, 8) == "vless://" ||
		substr(l, 0, 8) == "vmess://" ||
		substr(l, 0, 9) == "trojan://" ||
		substr(l, 0, 5) == "ss://";
}

function pad_base64(value) {
	let s = replace(replace(replace("" + value, /\s+/, ""), /-/, "+"), /_/, "/");
	let remainder = length(s) % 4;

	if (remainder == 2)
		s += "==";
	else if (remainder == 3)
		s += "=";

	return s;
}

function decode(value) {
	let data = util.trim(value);
	if (data == "")
		die("empty subscription response");

	if (plain_prefix(data))
		return data;

	let decoded = null;

	try {
		decoded = b64dec(pad_base64(data));
	}
	catch (e) {
		decoded = null;
	}

	if (decoded != null && util.trim(decoded) != "")
		return util.trim(decoded);

	die("unsupported subscription encoding");
}

return {
	looks_like_plain_text,
	plain_prefix,
	pad_base64,
	decode
};
