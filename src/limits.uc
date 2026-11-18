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

// Whole-download budget. A hostile server can trickle bytes forever, so the
// body limit alone is not enough: the handoff walk needs a deadline too.
const MAX_FETCH_SECONDS = 30;                // one HTTP request
const MAX_HANDOFF_SECONDS = 90;              // the whole handoff chain
const MAX_SUBSCRIPTION_SECONDS = 120;        // every attempt for one subscription

return {
	MAX_BODY_BYTES,
	MAX_PROFILES,
	MAX_ENDPOINTS,
	MAX_PROFILE_BYTES,
	MAX_REJECTED_ENDPOINTS,
	MAX_FETCH_SECONDS,
	MAX_HANDOFF_SECONDS,
	MAX_SUBSCRIPTION_SECONDS
};
