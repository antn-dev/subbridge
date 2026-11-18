// Destination policy for provider-controlled URLs.
//
// A subscription page can redirect the router anywhere. Without a check, the
// next request could hit the router's own web UI, a LAN device or a service on
// 127.0.0.1, and the first bytes of the reply are shown in LuCI as an error
// message. The rules here are deliberately conservative: only public unicast
// addresses are reachable.

const BLOCKED_HOSTS = [
	"localhost",
	"localhost.localdomain",
	"ip6-localhost",
	"ip6-loopback",
	"broadcasthost"
];

// Only these schemes may reach the network layer. file:// and gopher:// are
// not needed for a subscription and would turn the downloader into a local
// file reader.
const ALLOWED_SCHEMES = [ "http", "https" ];

// ucode does not hoist function declarations, so helpers come first.
function ends_with_text(value, suffix) {
	if (length(value) < length(suffix))
		return false;

	return substr(value, length(value) - length(suffix), length(suffix)) == suffix;
}

function scheme_allowed(scheme) {
	let s = lc("" + (scheme == null ? "" : scheme));

	for (let allowed in ALLOWED_SCHEMES) {
		if (s == allowed)
			return true;
	}

	return false;
}

function is_ipv4(value) {
	let parts = split("" + (value == null ? "" : value), ".");
	if (length(parts) != 4)
		return false;

	for (let part in parts) {
		if (part == "" || length(part) > 3)
			return false;

		if (match(part, /^[0-9]+$/) == null)
			return false;

		let n = int(part);
		if (n < 0 || n > 255)
			return false;
	}

	return true;
}

function ipv4_to_int(value) {
	let parts = split("" + value, ".");
	let n = 0;

	for (let part in parts)
		n = n * 256 + int(part);

	return n;
}

// Every range below is either "not reachable from the router" or "belongs to
// the router": loopback, RFC1918, link-local, CGNAT, multicast, benchmark,
// documentation and the IPv4-mapped equivalents.
const BLOCKED_V4 = [
	[ "0.0.0.0", 8 ],
	[ "10.0.0.0", 8 ],
	[ "100.64.0.0", 10 ],
	[ "127.0.0.0", 8 ],
	[ "169.254.0.0", 16 ],
	[ "172.16.0.0", 12 ],
	[ "192.0.0.0", 24 ],
	[ "192.0.2.0", 24 ],
	[ "192.88.99.0", 24 ],
	[ "192.168.0.0", 16 ],
	[ "198.18.0.0", 15 ],
	[ "198.51.100.0", 24 ],
	[ "203.0.113.0", 24 ],
	[ "224.0.0.0", 4 ],
	[ "240.0.0.0", 4 ]
];

function blocked_ipv4(value) {
	if (!is_ipv4(value))
		return false;

	let n = ipv4_to_int(value);

	for (let range in BLOCKED_V4) {
		let base = ipv4_to_int(range[0]);
		let bits = range[1];
		let mask = bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF;

		if ((n & mask) == (base & mask))
			return true;
	}

	return false;
}

// IPv6 is parsed into its eight 16-bit groups and checked numerically. Text
// comparison is not enough: "0:0:0:0:0:0:0:1" and "::1" are the same address,
// and so are "fd00::1" and "fd00:0:0:0:0:0:0:1".
function hex_group(value) {
	let s = lc("" + value);

	if (s == "" || length(s) > 4)
		return -1;

	let n = 0;

	for (let i = 0; i < length(s); i++) {
		let digit = index("0123456789abcdef", substr(s, i, 1));
		if (digit < 0)
			return -1;

		n = n * 16 + digit;
	}

	return n;
}

// Returns eight 16-bit groups, or null when the text is not an IPv6 address.
function ipv6_groups(value) {
	let s = lc("" + (value == null ? "" : value));

	if (substr(s, 0, 1) == "[" && substr(s, length(s) - 1, 1) == "]")
		s = substr(s, 1, length(s) - 2);

	// Strip a zone id such as fe80::1%eth0.
	let pct = index(s, "%");
	if (pct >= 0)
		s = substr(s, 0, pct);

	if (index(s, ":") < 0)
		return null;

	let at = index(s, "::");
	let left = null;
	let right = null;

	if (at >= 0) {
		// At most one "::" is allowed.
		if (index(substr(s, at + 2), "::") >= 0)
			return null;

		left = substr(s, 0, at);
		right = substr(s, at + 2);
	}
	else {
		left = s;
		right = "";
	}

	let head = left == "" ? [] : split(left, ":");
	let tail = right == "" ? [] : split(right, ":");

	// Expand an IPv4 tail such as ::ffff:127.0.0.1 into two hex groups. It is
	// always the last element of one side, never both. Returns false when the
	// tail looks like IPv4 but is malformed.
	let expand = function (parts) {
		if (length(parts) == 0)
			return true;

		let last = parts[length(parts) - 1];
		if (index(last, ".") < 0)
			return true;

		if (!is_ipv4(last))
			return false;

		let n = ipv4_to_int(last);
		parts[length(parts) - 1] = sprintf("%x", (n >> 16) & 0xFFFF);
		push(parts, sprintf("%x", n & 0xFFFF));

		return true;
	};

	if (!expand(tail) || !expand(head))
		return null;

	let groups = [];

	for (let part in head)
		push(groups, part);

	let filler = 8 - length(groups) - length(tail);
	if (at < 0) {
		if (length(groups) != 8)
			return null;

		filler = 0;
	}
	else if (filler < 0) {
		return null;
	}

	let out = [];

	for (let part in groups) {
		let n = hex_group(part);
		if (n < 0)
			return null;

		push(out, n);
	}

	for (let i = 0; i < filler; i++)
		push(out, 0);

	for (let part in tail) {
		let n = hex_group(part);
		if (n < 0)
			return null;

		push(out, n);
	}

	if (length(out) != 8)
		return null;

	return out;
}

function blocked_ipv6(value) {
	let s = lc("" + (value == null ? "" : value));

	if (index(s, ":") < 0)
		return false;

	let g = ipv6_groups(s);

	// Anything that looks like IPv6 but does not parse is treated as blocked:
	// the kernel may still accept it, so guessing "public" is unsafe.
	if (g == null)
		return true;

	// Unspecified and loopback.
	if (g[0] == 0 && g[1] == 0 && g[2] == 0 && g[3] == 0 &&
	    g[4] == 0 && g[5] == 0 && g[6] == 0 && g[7] <= 1)
		return true;

	// Link-local fe80::/10, unique-local fc00::/7, multicast ff00::/8.
	if ((g[0] & 0xFFC0) == 0xFE80)
		return true;
	if ((g[0] & 0xFE00) == 0xFC00)
		return true;
	if ((g[0] & 0xFF00) == 0xFF00)
		return true;

	// Documentation 2001:db8::/32 and discard-only 100::/64.
	if (g[0] == 0x2001 && g[1] == 0x0DB8)
		return true;
	if (g[0] == 0x0100 && g[1] == 0 && g[2] == 0 && g[3] == 0)
		return true;

	// Addresses that embed an IPv4 address: ::ffff:0:0/96 (mapped),
	// 64:ff9b::/96 (NAT64) and 2002::/16 (6to4). The embedded address is
	// what the router actually reaches.
	let embedded = null;

	if (g[0] == 0 && g[1] == 0 && g[2] == 0 && g[3] == 0 && g[4] == 0 && g[5] == 0xFFFF)
		embedded = [ g[6], g[7] ];
	else if (g[0] == 0x0064 && g[1] == 0xFF9B && g[2] == 0 && g[3] == 0 &&
	         g[4] == 0 && g[5] == 0)
		embedded = [ g[6], g[7] ];
	else if (g[0] == 0x2002)
		embedded = [ g[1], g[2] ];

	if (embedded != null)
		return blocked_ipv4(sprintf("%d.%d.%d.%d",
			(embedded[0] >> 8) & 0xFF, embedded[0] & 0xFF,
			(embedded[1] >> 8) & 0xFF, embedded[1] & 0xFF));

	return false;
}

function blocked_address(value) {
	return blocked_ipv4(value) || blocked_ipv6(value);
}

function bare_host(host) {
	let s = lc("" + (host == null ? "" : host));

	if (substr(s, 0, 1) == "[" && substr(s, length(s) - 1, 1) == "]")
		s = substr(s, 1, length(s) - 2);

	// A stray port must not hide the real host from the checks below.
	if (index(s, ":") >= 0 && index(s, "::") < 0)
		s = substr(s, 0, index(s, ":"));

	if (s != "" && substr(s, length(s) - 1, 1) == ".")
		s = substr(s, 0, length(s) - 1);

	return s;
}

function host_blocked(host) {
	let s = bare_host(host);

	if (s == "")
		return true;

	for (let name in BLOCKED_HOSTS) {
		if (s == name)
			return true;
	}

	// ".local" is mDNS, ".internal" is often a router-provided zone.
	if (ends_with_text(s, ".local") || s == "local" ||
	    ends_with_text(s, ".internal") || s == "internal")
		return true;

	return blocked_address(s);
}

// socket.addrinfo is the only resolver ucode exposes. It returns the addresses
// the kernel would connect to, which is what a DNS-rebinding attacker cannot
// fake at check time. A name that does not resolve is not treated as blocked:
// the fetch itself will fail with the real DNS error, and reporting "non-public
// address" there would hide what went wrong.
function resolve_blocked(host) {
	let socket = null;

	try {
		socket = require("socket");
	}
	catch (e) {
		// Without ucode-mod-socket the literal checks above are all we have.
		return false;
	}

	if (socket == null || type(socket.addrinfo) != "function")
		return false;

	let result = null;

	try {
		result = socket.addrinfo("" + host, "80", { socktype: socket.SOCK_STREAM });
	}
	catch (e) {
		return false;
	}

	if (result == null || length(result) == 0)
		return false;

	for (let entry in result) {
		let addr = entry.addr;

		// A result without an address is not something to guess about.
		if (addr == null || type(addr.address) != "string")
			continue;

		if (blocked_address(addr.address))
			return true;
	}

	return false;
}

return {
	scheme_allowed,
	is_ipv4,
	blocked_ipv4,
	blocked_ipv6,
	blocked_address,
	bare_host,
	host_blocked,
	resolve_blocked
};
