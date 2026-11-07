// Persistent pseudonymous device id.
//
// Happ on Apple platforms sends a 16-character base36 (0-9, a-z) value in
// X-HWID, so a generated id has the same shape as a real one. The value must
// survive across checks: a provider that binds a subscription to a device
// would otherwise see a new device on every run and could hit its limit.

let fs = require("fs");
let util = require("util");

const DEFAULT_PATH = "/etc/subbridge/hwid";
const ALPHABET = "0123456789abcdefghijklmnopqrstuvwxyz";
const LENGTH = 16;

function generate() {
	let random = util.random_bytes(LENGTH);
	let out = "";

	for (let i = 0; i < LENGTH; i++)
		out += substr(ALPHABET, ord(substr(random, i, 1)) % length(ALPHABET), 1);

	return out;
}

function read(path) {
	let value = util.trim(util.read_file(path));
	return value == "" ? null : value;
}

function get_or_create(path) {
	path = path == null || path == "" ? DEFAULT_PATH : path;

	let existing = read(path);
	if (existing != null)
		return existing;

	let value = generate();

	let dir = util.dirname(path);
	if (dir != "" && dir != "." && dir != "/")
		util.ensure_dir(dir, 0700);

	// write_file uses mode 0600 by default; be explicit because the directory
	// may have been created by an older package with different permissions.
	let f = fs.open(path, "w", 0600);
	if (!f)
		return value;

	f.write(value + "\n");
	f.close();

	return value;
}

return {
	DEFAULT_PATH,
	generate,
	read,
	get_or_create
};
