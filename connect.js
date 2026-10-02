

```javascript
// ============================================================================
// connect.js — LDI Sales Dashboard
// Optimized host detection + failover
//
// Priority:
//   1. Local     → fastest inside LAN
//   2. Cloudflare → primary external connection
//   3. ngrok      → emergency fallback
//
// Features:
//   ✓ Fast host detection
//   ✓ Does NOT wait for slow/dead hosts after a winner is found
//   ✓ Remembers last successful host
//   ✓ Automatic failover
//   ✓ ngrok browser-warning bypass
//   ✓ Existing fetch() calls continue to work
// ============================================================================

const HOSTS = [
//    'http://192.168.0.5:8000',                                // 1. Local
    'https://trainers-police-rome-amplifier.trycloudflare.com', // 2. Cloudflare
    'https://scam-retouch-hull.ngrok-free.dev'                // 3. ngrok
];

const ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyAgCiAgICAicm9sZSI6ICJhbm9uIiwKICAgICJpc3MiOiAic3VwYWJhc2UtZGVtbyIsCiAgICAiaWF0IjogMTY0MTc2OTIwMCwKICAgICJleHAiOiAxNzk5NTM1NjAwCn0.dc_X5iR_VP_qT0zsiyj_I_OZ2T9FtRU2BBNWN8Bu4GE';

//'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0';

// ============================================================================
// SETTINGS
// ============================================================================

const HOST_STORAGE_KEY = 'ldi_preferred_host';

const PING_TIMEOUT = 1800;       // Maximum ping time per host
const FAIL_COOLDOWN = 20000;     // Failed host disabled for 20 seconds

// ============================================================================
// INTERNAL STATE
// ============================================================================

let _ranked = HOSTS.slice();
let _badUntil = Object.create(null);
let _reracing = false;

// ============================================================================
// HOST HELPERS
// ============================================================================

function markHostBad(host) {
    _badUntil[host] = Date.now() + FAIL_COOLDOWN;

    console.warn(
        `[connect] ❌ host failed, cooldown ${FAIL_COOLDOWN / 1000}s: ${host}`
    );
}

function markHostOk(host) {
    delete _badUntil[host];

    try {
        localStorage.setItem(HOST_STORAGE_KEY, host);
    } catch (e) {
        // Ignore localStorage errors
    }
}

function isHostAvailable(host) {
    const until = _badUntil[host];

    return !until || until <= Date.now();
}

function pickHost() {

    const alive = _ranked.filter(isHostAvailable);

    if (alive.length) {
        return alive[0];
    }

    // Everything failed.
    // Clear cooldowns and try again.
    _badUntil = Object.create(null);

    return _ranked[0] || HOSTS[0];
}

function hostOf(url) {

    return HOSTS.find(
        host => url && url.indexOf(host) === 0
    ) || null;
}

function swapHost(url, from, to) {

    if (from === to) {
        return url;
    }

    return to + url.slice(from.length);
}

// ============================================================================
// HOST SELECTION
// ============================================================================

function selectHost(host, switched = true) {

    if (!host) {
        return;
    }

    const previous = window.HOSTNAME;

    window.HOSTNAME = host;

    if (previous !== host) {

        console.log(
            `[connect] 🌐 active host: ${host}`
        );

        window.dispatchEvent(
            new CustomEvent('host-ready', {
                detail: {
                    host,
                    previous,
                    switched
                }
            })
        );
    }
}

// ============================================================================
// LOCAL STORAGE
// ============================================================================

function getSavedHost() {

    try {

        const saved = localStorage.getItem(HOST_STORAGE_KEY);

        if (saved && HOSTS.includes(saved)) {
            return saved;
        }

    } catch (e) {
        // Ignore localStorage errors
    }

    return null;
}

// ============================================================================
// PING SINGLE HOST
// ============================================================================

async function pingHost(host, timeoutMs = PING_TIMEOUT) {

    const controller = new AbortController();

    const timer = setTimeout(
        () => controller.abort(),
        timeoutMs
    );

    const started = performance.now();

    try {

        const response = await rawFetch(
            `${host}/auth/v1/health`,
            {
                method: 'GET',

                signal: controller.signal,

                headers: {
                    apikey: ANON_KEY,

                    // Required for ngrok
                    'ngrok-skip-browser-warning': 'true'
                },

                // Avoid unnecessary browser cache behavior
                cache: 'no-store'
            }
        );

        const ms = Math.round(
            performance.now() - started
        );

        return {
            host,
            ok: response.ok,
            ms
        };

    } catch (error) {

        return {
            host,
            ok: false,
            ms: Math.round(
                performance.now() - started
            ),
            err: error?.name || 'UnknownError'
        };

    } finally {

        clearTimeout(timer);
    }
}

// ============================================================================
// FAST HOST RACE
//
// Important difference from the old version:
//
// OLD:
//   Promise.all()
//   ↓
//   Wait for EVERY host.
//
// NEW:
//   Promise.any()
//   ↓
//   Return as soon as ONE host succeeds.
// ============================================================================

async function raceHosts(hosts = HOSTS, timeoutMs = PING_TIMEOUT) {

    const started = performance.now();

    console.log('[connect] 🔎 testing hosts...');

    // ------------------------------------------------------------------------
    // Prefer saved host first.
    // ------------------------------------------------------------------------

    const savedHost = getSavedHost();

    if (savedHost && hosts.includes(savedHost)) {

        console.log(
            `[connect] ⭐ trying saved host first: ${savedHost}`
        );

        const savedResult = await pingHost(
            savedHost,
            timeoutMs
        );

        console.log(
            `[connect] ${savedHost} → ` +
            `${savedResult.ok ? 'OK ✅' : 'FAIL ❌'} ` +
            `(${savedResult.ms}ms)`
        );

        if (savedResult.ok) {

            _ranked = [
                savedHost,
                ...hosts.filter(h => h !== savedHost)
            ];

            console.log(
                `[connect] 🏆 saved host accepted: ` +
                `${savedHost} (${savedResult.ms}ms)`
            );

            return savedHost;
        }

        markHostBad(savedHost);
    }

    // ------------------------------------------------------------------------
    // Race remaining hosts.
    // ------------------------------------------------------------------------

    const candidates = hosts.filter(
        h => h !== savedHost && isHostAvailable(h)
    );

    if (!candidates.length) {

        _badUntil = Object.create(null);

        return hosts[0];
    }

    // ------------------------------------------------------------------------
    // Promise.any()
    //
    // The first successful host wins.
    // Failed hosts do NOT delay the winner.
    // ------------------------------------------------------------------------

    const attempts = candidates.map(
        async (host) => {

            const result = await pingHost(
                host,
                timeoutMs
            );

            console.log(
                `[connect] ${host} → ` +
                `${result.ok ? 'OK ✅' : 'FAIL ❌'} ` +
                `(${result.ms}ms)` +
                `${result.err ? ` [${result.err}]` : ''}`
            );

            if (!result.ok) {

                markHostBad(host);

                throw new Error(
                    `${host} failed`
                );
            }

            return {
                host,
                ms: result.ms
            };
        }
    );

    try {

        const winner = await Promise.any(attempts);

        const elapsed = Math.round(
            performance.now() - started
        );

        // Put winner first.
        _ranked = [
            winner.host,
            ...hosts.filter(h => h !== winner.host)
        ];

        markHostOk(winner.host);

        console.log(
            `[connect] 🏆 winner: ${winner.host} ` +
            `(${winner.ms}ms, total ${elapsed}ms)`
        );

        return winner.host;

    } catch (error) {

        console.warn(
            '[connect] ❌ no reachable host'
        );

        // Reset cooldowns for another attempt.
        _badUntil = Object.create(null);

        return hosts[0];
    }
}

// ============================================================================
// BACKGROUND RE-RACE
// ============================================================================

function reraceInBackground() {

    if (_reracing) {
        return;
    }

    _reracing = true;

    raceHosts()
        .then(host => {

            console.log(
                `[connect] 🔄 background winner: ${host}`
            );

            selectHost(host, true);
        })
        .catch(() => {})
        .finally(() => {

            _reracing = false;
        });
}

// ============================================================================
// FETCH PATCH
//
// Existing dashboard code does NOT need to change.
//
// Example:
//
// fetch(`${HOSTNAME}/rest/v1/sales?...`)
//
// will automatically use the active host.
// ============================================================================

const rawFetch = window.fetch.bind(window);

window.fetch = async function patchedFetch(input, init) {

    const origUrl =
        typeof input === 'string'
            ? input
            : (input && input.url) || '';

    const from = hostOf(origUrl);

    // Not one of our API hosts.
    // Let browser fetch normally.
    if (!from) {

        return rawFetch(
            input,
            init
        );
    }

    const merged = Object.assign(
        {},
        init
    );

    const headers = new Headers(
        merged.headers ||
        (input && input.headers) ||
        {}
    );

    // ngrok warning bypass
    headers.set(
        'ngrok-skip-browser-warning',
        'true'
    );

    merged.headers = headers;

    let lastErr = null;

    // ------------------------------------------------------------------------
    // Try hosts in current ranking.
    // ------------------------------------------------------------------------

    const maxTries = Math.max(
        1,
        _ranked.length
    );

    for (let i = 0; i < maxTries; i++) {

        const host = pickHost();

        try {

            const targetUrl = swapHost(
                origUrl,
                from,
                host
            );

            console.log(
                `[connect] → ${host}`
            );

            const response = await rawFetch(
                targetUrl,
                merged
            );

            // HTTP response received.
            // Even if HTTP status is 4xx/5xx,
            // the host itself is reachable.
            markHostOk(host);

            selectHost(host, true);

            return response;

        } catch (error) {

            // User cancelled request.
            if (
                error &&
                error.name === 'AbortError'
            ) {
                throw error;
            }

            markHostBad(host);

            lastErr = error;

            console.warn(
                `[connect] ⚠️ ${host} failed ` +
                `(${error?.name || 'Error'})`
            );

            // Try another host immediately.
            continue;
        }
    }

    throw (
        lastErr ||
        new Error('All hosts unreachable')
    );
};

// ============================================================================
// WINDOW EXPORTS
// ============================================================================

window.HOSTS = HOSTS;

window.HOSTNAME = getSavedHost() || HOSTS[0];

window.ANON_KEY = ANON_KEY;

window.raceHosts = raceHosts;

// ============================================================================
// INITIAL CONNECTION
// ============================================================================

window.readyHost = raceHosts()
    .then(host => {

        selectHost(
            host,
            false
        );

        return host;
    })
    .catch(error => {

        console.error(
            '[connect] initialization failed:',
            error
        );

        selectHost(
            HOSTS[0],
            false
        );

        return HOSTS[0];
    });

// ============================================================================
// DEBUG HELPER
// ============================================================================

window.getConnectionStatus = function () {

    return {
        activeHost: window.HOSTNAME,

        savedHost: getSavedHost(),

        rankedHosts: _ranked.slice(),

        failedHosts: Object.keys(_badUntil),

        reracing: _reracing
    };
};
```