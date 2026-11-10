// Small helpers shared by every SubBridge module.
//
// ucode has no standard library beyond the modules listed in `require()`.
// Everything here is deliberately dependency-free so the same file runs on a
// router and in the test harness.

let fs = require("fs");

function trim(value) {
	if (type(value) != "string")
		return "";

	return replace(replace(value, /^\s+/, ""), /\s+$/, "");
}

function nonempty(value) {
	return type(value) == "string" && trim(value) != "";
}

function read_file(path) {
	let f = fs.open(path, "r");
	if (!f)
		return null;

	let data = f.read("all");
	f.close();

	return data;
}

function write_file(path, data, mode) {
	let f = fs.open(path, "w", mode == null ? 0600 : mode);
	if (!f)
		return false;

	f.write(data);
	f.close();

	return true;
}

function dirname(path) {
	let s = "" + (path == null ? "" : path);
	let slash = -1;
	for (let i = 0; i < length(s); i++) {
		if (substr(s, i, 1) == "/")
			slash = i;
	}

	if (slash < 0)
		return ".";
	if (slash == 0)
		return "/";

	return substr(s, 0, slash);
}

function current_uid() {
	let data = read_file("/proc/self/status");
	if (data == null)
		return -1;

	let m = match(data, /\nUid:[ \t]+([0-9]+)/);
	return m == null ? -1 : int(m[1]);
}

function process_id() {
	let data = read_file("/proc/self/stat");
	if (data == null)
		return 0;

	let m = match(data, /^([0-9]+)/);
	return m == null ? 0 : int(m[1]);
}

function private_dir(st) {
	if (st == null || st.type != "directory" || st.perm == null)
		return false;

	return st.perm.group_write != true && st.perm.other_write != true;
}

function ensure_dir(path, mode) {
	path = trim(path);
	if (path == "" || path == "/")
		return true;

	let wanted = mode == null ? 0700 : mode;
	let current = "";

	for (let part in split(path, "/")) {
		if (part == "")
			continue;

		current += "/" + part;
		let st = fs.lstat(current);

		if (st == null) {
			fs.mkdir(current, wanted);
			st = fs.lstat(current);
		}

		// A symlink or a file must never be accepted where a directory is
		// expected: writes would follow it outside our temporary tree.
		if (st == null || st.type != "directory")
			return false;
	}

	let st = fs.lstat(path);
	if (!private_dir(st))
		return false;

	// A directory created in advance by another local user could be used to
	// read the endpoint credentials written into it.
	let uid = current_uid();
	if (uid >= 0 && type(st.uid) == "int" && st.uid != uid)
		return false;

	return true;
}

function file_exists(path) {
	return fs.stat(path) != null;
}

function is_executable(path) {
	let st = fs.stat(path);
	if (st == null || st.type != "file")
		return false;

	return st.perm.user_exec == true;
}

function json_read(path) {
	let data = read_file(path);
	if (data == null || trim(data) == "")
		return null;

	try {
		return json(data);
	}
	catch (e) {
		return null;
	}
}

function json_write(path, value) {
	return write_file(path, sprintf("%.4J\n", value), 0600);
}

function shell_quote(value) {
	let s = "" + value;
	return "'" + replace(s, /'/, "'\\''") + "'";
}

function argv_command(argv) {
	let parts = [];
	for (let arg in argv)
		push(parts, shell_quote(arg));

	return join(" ", parts);
}

// Run a command through /bin/sh and return { code, output }. stderr is folded
// into output so callers can report the engine's own explanation.
function command(cmd) {
	let p = fs.popen("( " + cmd + " ) 2>&1");
	if (!p)
		return { code: -1, output: "" };

	let output = p.read("all");
	let code = p.close();

	return { code: code == null ? -1 : code, output: output == null ? "" : output };
}

function command_argv(argv) {
	return command(argv_command(argv));
}

function first_line(value) {
	let s = "" + (value == null ? "" : value);
	let lines = split(s, "\n");
	for (let line in lines) {
		line = trim(line);
		if (line != "")
			return line;
	}

	return "";
}

function split_lines(value) {
	let result = [];
	for (let line in split("" + (value == null ? "" : value), "\n"))
		push(result, replace(line, /\r$/, ""));

	return result;
}

function to_int(value, fallback) {
	let n = int(value);
	if (n == null || n != n)
		return fallback;

	return n;
}

function lower(value) {
	return lc("" + (value == null ? "" : value));
}

function to_bool(value) {
	if (value == true)
		return true;

	let s = lower("" + (value == null ? "" : value));
	return s == "1" || s == "true" || s == "yes" || s == "on";
}

function now_ms() {
	let c = clock();
	return time() * 1000 + int(c[1] / 1000000);
}

function random_bytes(count) {
	let data = "";
	let f = fs.open("/dev/urandom", "r");
	if (f) {
		data = f.read(count);
		f.close();
	}

	// /dev/urandom always exists on Linux; this keeps the helper usable in a
	// restricted test environment.
	while (length(data) < count)
		data += chr(int(time() + clock()[1] + length(data)) % 256);

	return substr(data, 0, count);
}

function find_in_path(name) {
	if (index(name, "/") >= 0)
		return is_executable(name) ? name : null;

	let path = getenv("PATH");
	if (path == null)
		path = "/usr/sbin:/usr/bin:/sbin:/bin";

	for (let dir in split(path, ":")) {
		if (dir == "")
			continue;

		let candidate = dir + "/" + name;
		if (is_executable(candidate))
			return candidate;
	}

	return null;
}

function remove_dir(path) {
	if (path == null || path == "")
		return;

	let st = fs.stat(path);
	if (st == null)
		return;

	if (st.type == "directory") {
		for (let name in fs.lsdir(path))
			remove_dir(path + "/" + name);

		fs.rmdir(path);
	}
	else {
		fs.unlink(path);
	}
}

function random_hex(count) {
	let out = "";
	let bytes = random_bytes(count);

	for (let i = 0; i < length(bytes); i++)
		out += sprintf("%02x", ord(substr(bytes, i, 1)));

	return out;
}

function temp_path(path) {
	return "" + path + ".tmp." + random_hex(8);
}

function temp_dir(prefix) {
	// mkdir is atomic and fails on an existing path, including a symlink
	// planted in /tmp. 64 bits of randomness make guessing impractical.
	for (let attempt = 0; attempt < 8; attempt++) {
		let base = "/tmp/" + prefix + "-" + random_hex(8);

		if (fs.mkdir(base, 0700) != true)
			continue;

		let st = fs.lstat(base);
		if (private_dir(st) &&
		    (type(st.uid) != "int" || st.uid == current_uid()))
			return base;

		fs.rmdir(base);
	}

	die("cannot create a temporary directory");
}

return {
	trim,
	nonempty,
	read_file,
	write_file,
	dirname,
	ensure_dir,
	file_exists,
	is_executable,
	json_read,
	json_write,
	shell_quote,
	argv_command,
	command,
	command_argv,
	first_line,
	split_lines,
	to_int,
	to_bool,
	lower,
	now_ms,
	random_bytes,
	random_hex,
	temp_path,
	current_uid,
	process_id,
	find_in_path,
	remove_dir,
	temp_dir
};
