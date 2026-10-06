// ============================================================================
// connect.js — centralised host + anon key for the LDI Sales Dashboard
//
// Chrome-friendly edition:
//   • HTTPS page  →  ONLY https:// hosts are ever used (no mixed-content block)
//   • HTTP  page  →  local LAN host is allowed
//   • http://localhost / 127.0.0.1 is allowed even from HTTPS (Chrome treats
//     loopback as "potentially trustworthy")
//   • ngrok-skip-browser-warning header is ONLY sent to ngrok hosts, so we
//     don't trigger extra CORS preflights on Supabase / Cloudflare
//   • Pings use mode:'cors', credentials:'omit', cache:'no-store' so Chrome
//     never returns a stale/opaque failure
//   • fetch now auto-fails over to another allowed host on network errors
//     and 502/503/504 responses
// ============================================================================

const HOSTS = [
  // 'http://192.168.0.5:8000',                                    // 1. local
  'https://snowy-mouse-c50bsupabase-proxy.ldicorplan68.workers.dev', // 2. cloudflare workers
  'https://groundwater-player-bag-sip.trycloudflare.com',           // 3. cloudflare tunnel
  // 'https://scam-retouch-hull.ngrok-free.dev'                    // 4. ngrok
];

const ANON_KEY =
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyAgCiAgICAicm9sZSI6ICJhbm9uIiwKICAgICJpc3MiOiAic3VwYWJhc2UtZGVtbyIsCiAgICAiaWF0IjogMTY0MTc2OTIwMCwKICAgICJleHAiOiAxNzk5NTM1NjAwCn0.dc_X5iR_VP_qT0zsiyj_I_OZ2T9FtRU2BBNWN8Bu4GE';

const PING_TIMEOUT = 2000;
const SKIP_HEADER = 'ngrok-skip-browser-warning';
const STORE_KEY = 'ldi.connect.v1';

// cache once — location.protocol never changes mid-session
const IS_SECURE_PAGE = location.protocol === 'https:';

const rawFetch = window.fetch.bind(window);
const conn =
  navigator.connection ||
  navigator.mozConnection ||
  navigator.webkitConnection;

// --- helpers ---------------------------------------------------------------

function isNgrokHost(h) {
  return typeof h === 'string' && h.indexOf('ngrok') !== -1;
}

// Chrome considers these "potentially trustworthy" → not mixed content.
function isLoopbackHost(h) {
  return /^http:\/\/(localhost|127\.0\.0\.1|\[::1\])(:\d+)?/i.test(h || '');
}

// Fix for Chrome's "Mixed Content" + "Private Network Access" blocks.
function isMixedContent(h) {
  if (!h) return true;
  if (!IS_SECURE_PAGE) return false;        // http page → everything is fine
  if (h.indexOf('https://') === 0) return false;
  if (isLoopbackHost(h)) return false;      // http://localhost is OK
  return true;                              // http://192.168.* on https page = BLOCKED
}

function allowedHosts() {
  if (!IS_SECURE_PAGE) return HOSTS.slice();

  // On HTTPS pages we stay HTTPS-only.
  const safe = HOSTS.filter((h) => !isMixedContent(h));
  if (!safe.length) {
    console.error(
      '[connect] Page is HTTPS but no HTTPS host is configured. ' +
        'Chrome will block http:// LAN calls. Add a Cloudflare/ngrok HTTPS host.'
    );
  }
  return safe;
}

function defaultHost() {
  return allowedHosts()[0] || '';
}

// --- state -----------------------------------------------------------------

let _finding = null;
let _lastSig = netSig();
let _wasOffline = !navigator.onLine;

const hostOf = (url) => {
  for (let i = 0; i < HOSTS.length; i++) {
    if (url.indexOf(HOSTS[i]) === 0) return HOSTS[i];
  }
  return null;
};

function netSig() {
  const type = (conn && conn.type) || '';
  return (navigator.onLine ? '1' : '0') + '|' + type + '|' + location.protocol;
}

function readSaved() {
  try {
    const s = JSON.parse(localStorage.getItem(STORE_KEY));
    if (s && s.host && allowedHosts().indexOf(s.host) !== -1) return s;
  } catch (e) {}
  return null;
}

function writeSaved(host) {
  try {
    localStorage.setItem(STORE_KEY, JSON.stringify({ host, sig: netSig() }));
  } catch (e) {}
}

function selectHost(host) {
  const allowed = allowedHosts();
  if (allowed.indexOf(host) === -1) host = allowed[0] || host;
  if (!host) return; // nothing safe available
  writeSaved(host);
  if (window.HOSTNAME === host) return;
  window.HOSTNAME = host;
  window.dispatchEvent(
    new CustomEvent('host-ready', { detail: { host, switched: true } })
  );
}

// --- pinging ---------------------------------------------------------------

function pingHost(url, timeoutMs = PING_TIMEOUT) {
  // Never even attempt a request Chrome will block.
  if (isMixedContent(url)) {
    return Promise.resolve({ url, ok: false, ms: 0, err: 'mixed-content' });
  }

  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), timeoutMs);
  const started = performance.now();

  const headers = { apikey: ANON_KEY };
  // only add the ngrok header when we're actually talking to ngrok
  if (isNgrokHost(url)) headers[SKIP_HEADER] = 'true';

  return rawFetch(url + '/auth/v1/health', {
    method: 'GET',
    mode: 'cors',          // be explicit
    credentials: 'omit',   // avoids credentialed-CORS blocks
    cache: 'no-store',     // never reuse an opaque/cached failure
    signal: ctrl.signal,
    headers,
  })
    .then(
      (res) => ({
        url,
        ok: res.ok,
        ms: Math.round(performance.now() - started),
      }),
      (e) => ({
        url,
        ok: false,
        ms: Math.round(performance.now() - started),
        err: e.name,
      })
    )
    .finally(() => clearTimeout(t));
}

function raceHosts(hosts, timeoutMs = PING_TIMEOUT) {
  hosts = hosts || allowedHosts();
  if (!hosts.length) return Promise.resolve('');

  const pings = hosts.map((h) => pingHost(h, timeoutMs));
  return Promise.any(
    pings.map((p) => p.then((r) => (r.ok ? r.url : Promise.reject(r))))
  ).catch(() => {
    console.warn('[connect] ❌ no reachable host — falling back to first allowed');
    return hosts[0] || defaultHost();
  });
}

function findServer(reason) {
  if (_finding) return _finding;
  console.log('[connect] finding server' + (reason ? ' (' + reason + ')' : ''));
  _finding = raceHosts()
    .then((host) => {
      selectHost(host);
      _lastSig = netSig();
      if (host) console.log('[connect] using ' + host);
      return host;
    })
    .finally(() => {
      _finding = null;
    });
  return _finding;
}

function onNetworkChange(reason) {
  const sig = netSig();
  if (sig === _lastSig && reason !== 'online') return;
  _lastSig = sig;
  if (!navigator.onLine) return;
  findServer(reason || 'network-change');
}

window.addEventListener('offline', () => {
  _wasOffline = true;
});

window.addEventListener('online', () => {
  if (_wasOffline) {
    _wasOffline = false;
    onNetworkChange('online');
  }
});

if (conn && conn.addEventListener) {
  conn.addEventListener('change', () => onNetworkChange('connection-type'));
}

// --- patched fetch ---------------------------------------------------------

// centralised header builder — skip-header only for ngrok
function buildHeaders(src, host) {
  let headers;
  if (!src) {
    headers = {};
  } else if (Array.isArray(src)) {
    headers = Object.fromEntries(src);
  } else if (typeof src.forEach === 'function') {
    headers = {};
    src.forEach((v, k) => {
      headers[k] = v;
    });
  } else {
    headers = Object.assign({}, src);
  }

  if (isNgrokHost(host)) {
    headers[SKIP_HEADER] = 'true';
  } else {
    // case-insensitive delete so we don't accidentally send it elsewhere
    Object.keys(headers).forEach((k) => {
      if (k.toLowerCase() === SKIP_HEADER.toLowerCase()) delete headers[k];
    });
  }
  return headers;
}

function isRetryableStatus(status) {
  return status === 502 || status === 503 || status === 504;
}

window.fetch = async function patchedFetch(input, init) {
  const url =
    typeof input === 'string' ? input : (input && input.url) || '';
  const from = hostOf(url);
  if (!from) return rawFetch(input, init); // not one of our hosts

  const allowed = allowedHosts();
  let host = window.HOSTNAME || from;
  if (allowed.indexOf(host) === -1) host = allowed[0] || from;

  // hard-stop mixed content instead of letting Chrome throw an opaque error
  if (isMixedContent(host)) {
    console.warn(
      '[connect] ⛔ blocked mixed-content fetch → ' + host + url.slice(from.length)
    );
    return Promise.reject(
      new TypeError('Failed to fetch (mixed content blocked by Chrome)')
    );
  }

  const buildTarget = (h) => h + url.slice(from.length);
  const buildInit = (h) => {
    const src = (init && init.headers) || (input && input.headers);
    const headers = buildHeaders(src, h);
    // NOTE: if you pass a Request object as `input`, its body/method will be
    // lost here — pass a URL string + init instead (that's what Supabase-js does).
    return Object.assign({}, init || {}, { headers });
  };

  let target = buildTarget(host);
  let reqInit = buildInit(host);

  try {
    const res = await rawFetch(target, reqInit);

    // failover only on gateway/server-unavailable errors
    if (isRetryableStatus(res.status)) {
      const newHost = await findServer('fetch-status-' + res.status);
      if (newHost && newHost !== host) {
        console.warn('[connect] retrying ' + res.status + ' on ' + newHost);
        return rawFetch(buildTarget(newHost), buildInit(newHost));
      }
    }

    return res;
  } catch (e) {
    // Don't retry if the caller intentionally aborted.
    if (e && e.name === 'AbortError') throw e;

    const newHost = await findServer('fetch-error');
    if (newHost && newHost !== host) {
      console.warn('[connect] retrying fetch on ' + newHost);
      return rawFetch(buildTarget(newHost), buildInit(newHost));
    }

    throw e;
  }
};

// --- boot ------------------------------------------------------------------

function boot() {
  const saved = readSaved();
  const sig = netSig();

  if (saved && saved.sig === sig) {
    return pingHost(saved.host).then((r) => {
      if (r.ok) {
        window.HOSTNAME = saved.host;
        console.log('[connect] sticking with ' + saved.host);
        return saved.host;
      }
      return findServer('saved-host-dead');
    });
  }

  return findServer(saved ? 'network-changed-since-last' : 'startup');
}

window.HOSTS = HOSTS;
window.HOSTNAME = defaultHost();
window.ANON_KEY = ANON_KEY;
window.raceHosts = raceHosts;
window.findServer = findServer;

window.readyHost = boot().then((host) => {
  if (host) window.HOSTNAME = host;
  window.dispatchEvent(new CustomEvent('host-ready', { detail: { host } }));
  return host;
});