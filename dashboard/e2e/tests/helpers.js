// Shared helpers: talk to the API directly to read state and restore it.
const HEADERS = { "X-Requested-With": "tradecopier" };

async function overview(request) {
  return (await request.get("/api/overview")).json();
}

async function getConfig(request, login) {
  return (await request.get(`/api/followers/${login}/config`)).json();
}

async function putConfig(request, login, config) {
  const res = await request.put(`/api/followers/${login}/config`, { headers: HEADERS, data: config });
  if (!res.ok()) throw new Error(`restore ${login}: ${await res.text()}`);
}

async function setPaused(request, paused) {
  await request.post(paused ? "/api/pause" : "/api/resume", { headers: HEADERS });
}

/** Snapshot every follower's settings + pause state; returns a restore function. */
async function snapshotState(request) {
  const { followers, paused } = await overview(request);
  const configs = {};
  for (const f of followers) configs[f.login] = await getConfig(request, f.login);
  return async () => {
    for (const [login, c] of Object.entries(configs)) await putConfig(request, login, c);
    await setPaused(request, paused);
    // Wait until every EA reports the restored settings (it re-reads ~2x/s).
    const same = (a, b) => Object.keys(b).every((k) => a?.[k] === b[k]);
    for (let i = 0; i < 20; i++) {
      const now = (await overview(request)).followers;
      if (now.every((f) => same(f.settings, configs[f.login]) && f.paused === paused)) return;
      await new Promise((r) => setTimeout(r, 500));
    }
    throw new Error("EAs did not confirm the restored settings within 10 s");
  };
}

/** Opens the Settings dialog for an account card. */
async function openSettings(page, login) {
  await page.goto("/#overview");
  await page.locator(`[data-settings="${login}"]`).click();
  await page.locator("#settings").waitFor({ state: "visible" });
}

const card = (page, login) => page.locator("article.account", { has: page.locator(`[data-settings="${login}"]`) });

module.exports = { HEADERS, overview, getConfig, putConfig, setPaused, snapshotState, openSettings, card };
