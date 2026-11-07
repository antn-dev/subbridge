// Machine-readable progress document.
//
// The LuCI page never blocks on a check: rpcd starts the process in the
// background and polls this file. Every update is written to a temporary file
// and renamed into place, so a reader never sees a half-written document.

let fs = require("fs");
let util = require("util");

function writer(path) {
	if (path == null || path == "")
		return null;

	return {
		path: path,
		rep: {
			state: "starting",
			phase: "",
			total: 0,
			done: 0,
			message: "",
			updated: time()
		}
	};
}

function flush(w) {
	if (w == null)
		return;

	w.rep.updated = time();

	let dir = util.dirname(w.path);
	if (dir != "" && dir != ".")
		util.ensure_dir(dir, 0700);

	let tmp = w.path + ".tmp." + int(clock()[1] % 1000000);
	if (!util.json_write(tmp, w.rep)) {
		return;
	}

	if (fs.rename(tmp, w.path) != true)
		fs.unlink(tmp);
}

function phase(w, name) {
	if (w == null)
		return;

	w.rep.state = "running";
	w.rep.phase = name;
	flush(w);
}

function progress(w, total, done) {
	if (w == null)
		return;

	w.rep.state = "running";
	w.rep.total = total;
	w.rep.done = done;
	flush(w);
}

function done(w) {
	if (w == null)
		return;

	w.rep.state = "done";
	w.rep.phase = "";
	w.rep.message = "";

	if (w.rep.total > 0)
		w.rep.done = w.rep.total;

	flush(w);
}

function fail(w, message) {
	if (w == null)
		return;

	w.rep.state = "error";
	w.rep.phase = "";
	w.rep.message = "" + (message == null ? "" : message);
	flush(w);
}

function read(path) {
	let value = util.json_read(path);
	if (value == null)
		return { state: "idle" };

	return value;
}

return {
	writer,
	flush,
	phase,
	progress,
	done,
	fail,
	read
};
