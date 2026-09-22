// ============================================================================
// connect.js — centralised host + anon key for the LDI Sales Dashboard
// Parallel racing: lahat ng hosts pinings nang sabay, first OK wins.
// Priority order (as tiebreaker only): local → cloudflare → ngrok
// ============================================================================

const HOSTS = [
 'http://192.168.0.5:8000',                                         // 1. local
  'https://trainers-police-rome-amplifier.trycloudflare.com',      // 2. cloudflare (fallback)
  'https://scam-retouch-hull.ngrok-free.dev'                          // 3. ngrok 
];

const ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyAgCiAgICAicm9sZSI6ICJhbm9uIiwKICAgICJpc3MiOiAic3VwYWJhc2UtZGVtbyIsCiAgICAiaWF0IjogMTY0MTc2OTIwMCwKICAgICJleHAiOiAxNzk5NTM1NjAwCn0.dc_X5iR_VP_qT0zsiyj_I_OZ2T9FtRU2BBNWN8Bu4GE';


// Supabase sometimes emits absolute URLs pointing at its own internal
// address (localhost:8000, 127.0.0.1:8000) in Location headers — e.g. for
// resumable (TUS) uploads. Clients on other devices can't reach those,
// so treat them as ALIASES of the current best host and rewrite them.
const HOST_ALIASES = [
  'http://localhost:8000',
  'http://127.0.0.1:8000',
  'https://localhost:8000',
  'https://127.0.0.1:8000'
];

// --- ngrok interstitial bypass + host failover --------------------------------
// 1) Lahat ng request sa tunnel host ay binibigyan ng skip header. Kapag wala
//    ito, ang isinasagot ng ngrok ay ang warning page (ERR_NGROK_6024,
//    text/html) na walang CORS headers: "blocked by CORS policy" / "Failed to fetch".
// 2) Kapag network failure (Failed to fetch / timeout) ang kasalukuyang host,
//    awtomatikong lilipat sa susunod na host sa ranking (2nd winner, 3rd, ...),
//    ipapadala ulit ang parehong request, at mag-rerace sa background.
const FAIL_COOLDOWN = 20000;               // ms na hindi susubukan ang bagsak na host
let   _ranked       = HOSTS.slice();       // ranking: best host muna
const _badUntil     = Object.create(null); // host -> oras ng pagbabalik
let   _reracing     = false;

function markHostBad(host){
  _badUntil[host] = Date.now() + FAIL_COOLDOWN;
  console.warn(`[connect] ❌ host down, cooldown ${FAIL_COOLDOWN / 1000}s: ${host}`);
}
function markHostOk(host){ delete _badUntil[host] }
function pickHost(){
  const now = Date.now();
  const alive = _ranked.filter(h => !_badUntil[h] || _badUntil[h] <= now);
  if (alive.length) return alive[0];
  for (const k in _badUntil) delete _badUntil[k];   // lahat bagsak: reset at subukan ulit
  return _ranked[0];
}
function hostOf(url){
  const h = HOSTS.find(h => url.indexOf(h) === 0);
  if (h) return h;
  for (const a of HOST_ALIASES) {
    if (url.indexOf(a) === 0) return a;
  }
  return null;
}
function swapHost(url, from, to){ return from === to ? url : to + url.slice(from.length) }

function selectHost(host){
  if (window.HOSTNAME === host) return;
  window.HOSTNAME = host;
  window.dispatchEvent(new CustomEvent('host-ready', { detail: { host, switched: true } }));
}
function reraceInBackground(){
  if (_reracing) return;
  _reracing = true;
  raceHosts()
    .then(host => { console.log(`[connect] 🔄 rerace winner: ${host}`); selectHost(host); })
    .catch(() => {})
    .finally(() => { _reracing = false; });
}

const rawFetch = window.fetch.bind(window);   // direktang fetch: gamit ng ping/race

window.fetch = async function patchedFetch(input, init){
  const origUrl = typeof input === 'string' ? input : (input && input.url) || '';
  const from    = hostOf(origUrl);
  if (!from) return rawFetch(origUrl, init);   // totally unrelated URL: hayaan lang

  // If the URL started with an alias (localhost / 127.0.0.1), we ignore the
  // alias prefix entirely and rebuild the URL from the picked real host.
  const isAlias = HOST_ALIASES.includes(from);
  const tail    = isAlias ? origUrl.slice(from.length) : null;

  const merged  = Object.assign({}, init);
  const headers = new Headers(merged.headers || (input && input.headers) || {});
  headers.set('ngrok-skip-browser-warning', 'true');
  merged.headers = headers;

  let lastErr = null;
  const maxTries = Math.max(1, _ranked.length);
  for (let i = 0; i < maxTries; i++){
    const host = pickHost();
    const targetUrl = isAlias ? (host + tail) : swapHost(origUrl, from, host);
    try {
      const res = await rawFetch(targetUrl, merged);
      markHostOk(host);
      selectHost(host);
      return res;
    } catch (e){
      if (e && e.name === 'AbortError') throw e;
      markHostBad(host);
      lastErr = e;
      console.warn(`[connect] ⚠️ ${host} failed (${e && e.name}) — susunod na host`);
      reraceInBackground();
    }
  }
  throw lastErr || new Error('All hosts unreachable');
};

// --- single host ping with timeout -----------------------------------------
async function pingHost(url, timeoutMs = 2500) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), timeoutMs);
  const started = performance.now();
  try {
    const res = await rawFetch(`${url}/auth/v1/health`, {
      method: 'GET',
      signal: ctrl.signal,
      headers: {
        apikey: ANON_KEY,
        'ngrok-skip-browser-warning': 'true'   // para hindi ma-block ng ngrok warning page
      }
    });
    const ms = Math.round(performance.now() - started);
    return res.ok ? { url, ok: true, ms } : { url, ok: false, ms };
  } catch (e) {
    return { url, ok: false, ms: Math.round(performance.now() - started), err: e.name };
  } finally {
    clearTimeout(t);
  }
}

// --- race all hosts, first OK wins -----------------------------------------
async function raceHosts(hosts = HOSTS, timeoutMs = 2500) {
  const results = await Promise.all(
    hosts.map(h => pingHost(h, timeoutMs))
  );

  results.forEach(r => {
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
    console.log(`[connect] 🏆 winner: ${winners[0].url} (${winners[0].ms}ms)`);
    return winners[0].url;
  }

  console.warn('[connect] ❌ no reachable host — falling back to first');
  return hosts[0];
}

// --- expose on window -------------------------------------------------------
window.HOSTS     = HOSTS;
window.HOSTNAME  = HOSTS[0];   // default until race finishes
window.ANON_KEY  = ANON_KEY;
window.raceHosts = raceHosts;

window.readyHost = raceHosts().then(host => {
  window.HOSTNAME = host;
  window.dispatchEvent(new CustomEvent('host-ready', { detail: { host } }));
  return host;
});