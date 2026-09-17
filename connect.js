// ============================================================================
// connect.js — centralised host + anon key for the LDI Sales Dashboard
// Parallel racing: lahat ng hosts pinings nang sabay, first OK wins.
// Priority order (as tiebreaker only): local → cloudflare → ngrok
// ============================================================================

const HOSTS = [
  'http://192.168.0.5:8000',                                         // 1. local
  'https://trainers-police-rome-amplifier.trycloudflare.com',      // 2. cloudflare
  'https://YOUR-SUBDOMAIN.ngrok-free.app'                          // 3. ngrok (palitan mo)
];

const ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyAgCiAgICAicm9sZSI6ICJhbm9uIiwKICAgICJpc3MiOiAic3VwYWJhc2UtZGVtbyIsCiAgICAiaWF0IjogMTY0MTc2OTIwMCwKICAgICJleHAiOiAxNzk5NTM1NjAwCn0.dc_X5iR_VP_qT0zsiyj_I_OZ2T9FtRU2BBNWN8Bu4GE';

// --- single host ping with timeout -----------------------------------------
async function pingHost(url, timeoutMs = 2500) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), timeoutMs);
  const started = performance.now();
  try {
    const res = await fetch(`${url}/auth/v1/health`, {
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