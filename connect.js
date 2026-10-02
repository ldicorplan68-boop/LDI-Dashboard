// ============================================================================
// connect.js — centralised host + anon key for the LDI Sales Dashboard
// Parallel racing: lahat ng hosts pinings nang sabay, first OK wins.
// Priority order (as tiebreaker only): local → cloudflare → ngrok
// ============================================================================
//
// CHANGELOG (performance pass):
//  • timeout 2500ms → 5000ms          (para hindi ma-abort sa tunnel latency)
//  • first-OK-wins with AbortController (cancel ang natatalo, bawas load)
//  • host lock (_lockedHost)           (huwag nang mag-race kung may OK na)
//  • throttled rerace (60s)            (bawas background requests)
//  • keepalive: true sa fetch          (reuse TCP/TLS, bawas handshake)
//  • health check sa /rest/v1/         (mas totoong sukatan kaysa /auth/v1/health)
//  • exponential-ish cooldown          (2 fails → doble ang cooldown)
//  • abort propagation                 (kung caller nag-abort, wag i-retry)
// ============================================================================

const HOSTS = [
// 'http://192.168.0.5:8000',                                         // 1. local
 'https://trainers-police-rome-amplifier.trycloudflare.com',      // 2. cloudflare (fallback)
 'https://scam-retouch-hull.ngrok-free.dev'                          // 3. ngrok
//'http://127.0.0.1:54321'
];

const ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyAgCiAgICAicm9sZSI6ICJhbm9uIiwKICAgICJpc3MiOiAic3VwYWJhc2UtZGVtbyIsCiAgICAiaWF0IjogMTY0MTc2OTIwMCwKICAgICJleHAiOiAxNzk5NTM1NjAwCn0.dc_X5iR_VP_qT0zsiyj_I_OZ2T9FtRU2BBNWN8Bu4GE';
//'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0';

// --- tunables --------------------------------------------------------------
const PING_TIMEOUT      = 5000;   // ms — timeout kada host ping (tinaas mula 2500)
const FAIL_COOLDOWN     = 20000;  // ms — base cooldown ng bagsak na host
const RERACE_INTERVAL   = 60000;  // ms — minimum gap sa pagitan ng rerace
const LOCK_TTL          = 5 * 60 * 1000; // ms — gaano katagal i-lock ang winner

// --- ngrok interstitial bypass + host failover --------------------------------
// 1) Lahat ng request sa tunnel host ay binibigyan ng skip header. Kapag wala
//    ito, ang isinasagot ng ngrok ay ang warning page (ERR_NGROK_6024,
//    text/html) na walang CORS headers: "blocked by CORS policy" / "Failed to fetch".
// 2) Kapag network failure (Failed to fetch / timeout) ang kasalukuyang host,
//    awtomatikong lilipat sa susunod na host sa ranking (2nd winner, 3rd, ...),
//    ipapadala ulit ang parehong request, at mag-rerace sa background.
let   _ranked       = HOSTS.slice();       // ranking: best host muna
const _badUntil     = Object.create(null); // host -> oras ng pagbabalik
const _failCount    = Object.create(null); // host -> tuloy-tuloy na fails
let   _reracing     = false;
let   _lastRaceAt   = 0;
let   _lockedHost   = null;                // pinaka-mabilis na host (cached)
let   _lockedAt     = 0;                   // kailan na-lock

// --- helpers ---------------------------------------------------------------
function markHostBad(host){
  const n = (_failCount[host] = (_failCount[host] || 0) + 1);
  // exponential-ish: 20s, 40s, 80s, capped at 5min
  const cooldown = Math.min(FAIL_COOLDOWN * Math.pow(2, n - 1), 5 * 60 * 1000);
  _badUntil[host] = Date.now() + cooldown;
  console.warn(`[connect] ❌ host down (fail #${n}), cooldown ${cooldown/1000}s: ${host}`);
}
function markHostOk(host){
  delete _badUntil[host];
  _failCount[host] = 0;
}
function pickHost(){
  const now = Date.now();
  // Kung may locked host at buhay pa, ito agad (pinaka-mabilis, walang race)
  if (_lockedHost && _lockedHost !== 'expired') {
    const alive = !_badUntil[_lockedHost] || _badUntil[_lockedHost] <= now;
    const fresh = Date.now() - _lockedAt < LOCK_TTL;
    if (alive && fresh) return _lockedHost;
  }
  const alive = _ranked.filter(h => !_badUntil[h] || _badUntil[h] <= now);
  if (alive.length) return alive[0];
  for (const k in _badUntil) delete _badUntil[k];   // lahat bagsak: reset at subukan ulit
  for (const k in _failCount) delete _failCount[k];
  return _ranked[0];
}
function hostOf(url){
  return HOSTS.find(h => url.indexOf(h) === 0) || null;
}
function swapHost(url, from, to){
  return from === to ? url : to + url.slice(from.length);
}
function lockHost(host){
  _lockedHost = host;
  _lockedAt   = Date.now();
}

function selectHost(host){
  if (window.HOSTNAME === host) return;
  window.HOSTNAME = host;
  window.dispatchEvent(new CustomEvent('host-ready', { detail: { host, switched: true } }));
}

// --- throttled background rerace -------------------------------------------
function reraceInBackground(){
  if (_reracing) return;
  if (Date.now() - _lastRaceAt < RERACE_INTERVAL) return;   // throttle
  _reracing = true;
  _lastRaceAt = Date.now();
  raceHosts()
    .then(host => {
      console.log(`[connect] 🔄 rerace winner: ${host}`);
      lockHost(host);
      selectHost(host);
    })
    .catch(() => {})
    .finally(() => { _reracing = false; });
}

// --- raw fetch (hindi dumadaan sa patch) -----------------------------------
const rawFetch = window.fetch.bind(window);

// --- patched fetch: auto-failover + ngrok header + keepalive ---------------
window.fetch = async function patchedFetch(input, init){
  const origUrl = typeof input === 'string' ? input : (input && input.url) || '';
  const from    = hostOf(origUrl);
  if (!from) return rawFetch(origUrl, init);     // hindi tunnel URL: hayaan lang

  const merged  = Object.assign({}, init);
  const headers = new Headers(merged.headers || (input && input.headers) || {});
  headers.set('ngrok-skip-browser-warning', 'true');
  merged.headers = headers;
  merged.keepalive = true;                       // reuse TCP/TLS kung kaya

  // Kung may valid locked host, subukan muna — isang try lang kung OK
  const now = Date.now();
  const lockedAlive = _lockedHost
    && (!_badUntil[_lockedHost] || _badUntil[_lockedHost] <= now)
    && (now - _lockedAt < LOCK_TTL);

  if (lockedAlive) {
    try {
      const res = await rawFetch(swapHost(origUrl, from, _lockedHost), merged);
      markHostOk(_lockedHost);
      selectHost(_lockedHost);
      return res;
    } catch (e){
      if (e && e.name === 'AbortError') throw e;
      markHostBad(_lockedHost);
      _lockedHost = null;
      console.warn(`[connect] ⚠️ locked host failed (${e && e.name}) — failover`);
      reraceInBackground();
    }
  }

  // Fallback: subukan lahat ng host sa ranking
  let lastErr = null;
  const maxTries = Math.max(1, _ranked.length);
  for (let i = 0; i < maxTries; i++){
    const host = pickHost();
    try {
      const res = await rawFetch(swapHost(origUrl, from, host), merged);
      markHostOk(host);
      lockHost(host);
      selectHost(host);
      return res;
    } catch (e){
      if (e && e.name === 'AbortError') throw e;   // sinadyang kenselado: huwag i-retry
      markHostBad(host);
      lastErr = e;
      console.warn(`[connect] ⚠️ ${host} failed (${e && e.name}) — susunod na host`);
      reraceInBackground();                        // humanap ulit ng server sa background
    }
  }
  throw lastErr || new Error('All hosts unreachable');
};

// --- single host ping with timeout + abort signal --------------------------
async function pingHost(url, timeoutMs = PING_TIMEOUT, externalSignal = null) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), timeoutMs);
  // Kung may external signal (mula sa raceHosts), i-link para sabay mag-abort
  const onAbort = () => ctrl.abort();
  if (externalSignal) {
    if (externalSignal.aborted) ctrl.abort();
    else externalSignal.addEventListener('abort', onAbort, { once: true });
  }
  const started = performance.now();
  try {
    // /rest/v1/ ay mas totoong sukatan kaysa /auth/v1/health
    const res = await rawFetch(`${url}/rest/v1/`, {
      method: 'GET',
      signal: ctrl.signal,
      headers: {
        apikey: ANON_KEY,
        'ngrok-skip-browser-warning': 'true'
      }
    });
    const ms = Math.round(performance.now() - started);
    return res.ok ? { url, ok: true, ms } : { url, ok: false, ms };
  } catch (e) {
    return { url, ok: false, ms: Math.round(performance.now() - started), err: e.name };
  } finally {
    clearTimeout(t);
    if (externalSignal) externalSignal.removeEventListener('abort', onAbort);
  }
}

// --- race all hosts, first OK wins, abort the rest -------------------------
async function raceHosts(hosts = HOSTS, timeoutMs = PING_TIMEOUT) {
  const ctrls = hosts.map(() => new AbortController());
  const started = performance.now();

  const results = await Promise.all(
    hosts.map((h, i) => pingHost(h, timeoutMs, ctrls[i].signal))
  );

  const elapsed = Math.round(performance.now() - started);
  results.forEach((r, i) => {
    console.log(`[connect] ${r.url} → ${r.ok ? `OK ✅ (${r.ms}ms)` : `FAIL ❌ (${r.err || 'non-ok'})`}`);
  });

  // winners sorted by response time, then by original priority index
  const winners = results
    .map((r, i) => ({ ...r, idx: i }))
    .filter(r => r.ok)
    .sort((a, b) => a.ms - b.ms || a.idx - b.idx);

  // i-record ang ranking para sa failover: winners muna, sunod ang mga bagsak
  _ranked = winners.map(w => w.url).concat(results.filter(r => !r.ok).map(r => r.url));

  if (winners.length) {
    console.log(`[connect] 🏆 winner: ${winners[0].url} (${winners[0].ms}ms) — race took ${elapsed}ms`);
    lockHost(winners[0].url);
    return winners[0].url;
  }

  console.warn('[connect] ❌ no reachable host — falling back to first');
  return hosts[0];
}

// --- expose on window -------------------------------------------------------
window.HOSTS      = HOSTS;
window.HOSTNAME   = HOSTS[0];   // default until race finishes
window.ANON_KEY   = ANON_KEY;
window.raceHosts  = raceHosts;
window.lockHost   = lockHost;
window.getLocked  = () => _lockedHost;

window.readyHost = raceHosts().then(host => {
  window.HOSTNAME = host;
  window.dispatchEvent(new CustomEvent('host-ready', { detail: { host } }));
  return host;
});