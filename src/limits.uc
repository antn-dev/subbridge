// Hard limits for untrusted subscription content.
//
// A router has 64-128 MB of RAM, so a broken or hostile provider must not be
// able to fill /tmp or make SubBridge start thousands of sing-box endpoints.
// The values are deliberately generous for real subscriptions.

const MAX_BODY_BYTES = 4 * 1024 * 1024;      // 4 MiB downloaded payload
const MAX_PROFILES = 500;                    // top-level JSON profiles
const MAX_ENDPOINTS = 2000;                  // flattened VLESS endpoints
const MAX_PROFILE_BYTES = 512 * 1024;        // one profile's JSON payload
const MAX_REJECTED_ENDPOINTS = 100;          // sing-box check retries

return {
	MAX_BODY_BYTES,
	MAX_PROFILES,
	MAX_ENDPOINTS,
	MAX_PROFILE_BYTES,
	MAX_REJECTED_ENDPOINTS
};
