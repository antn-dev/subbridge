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

function ensure_dir(path, mode) {
	path = trim(path);
	if (path == "" || path == "/")
		return true;

	let current = "";
	for (let part in split(path, "/")) {
		if (part == "")
			continue;

		current += "/" + part;
		if (fs.stat(current) == null)
			fs.mkdir(current, mode == null ? 0700 : mode);
	}

	return fs.stat(path) != null;
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
		for (let name in fs.readdir(path))
			remove_dir(path + "/" + name);

		fs.rmdir(path);
	}
	else {
		fs.unlink(path);
	}
}

function temp_dir(prefix) {
	let base = "/tmp/" + prefix + "-" + time() + "-" + int(clock()[1] % 1000000) + "-" + ord(substr(random_bytes(1), 0, 1));
	ensure_dir(base, 0700);

	return base;
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
	find_in_path,
	remove_dir,
	temp_dir
};
