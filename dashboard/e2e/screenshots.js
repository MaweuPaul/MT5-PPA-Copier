// Captures the README screenshots from the running dashboard:
//   cd dashboard\e2e && npm run screenshots
// Real account numbers are swapped for sample ones first, because the
// images are published in a public repo.
const { chromium } = require("@playwright/test");
const path = require("path");

const BASE = "http://127.0.0.1:8750";
const OUT = path.join(__dirname, "..", "..", "docs", "screenshots");
const VIEWPORT = { width: 1440, height: 900 };

async function anonymize(page) {
  const { masters, followers } = await (await page.request.get(`${BASE}/api/overview`)).json();
  const logins = [...masters.map((m) => m.master_id), ...followers.map((f) => String(f.login))];
  const fake = Object.fromEntries(logins.map((l, i) => [l, String(50001001 + i * 1111)]));
  await page.evaluate((map) => {
    const swap = (s) => Object.entries(map).reduce((t, [real, sample]) => t.split(real).join(sample), s);
    const walk = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    for (let n = walk.nextNode(); n; n = walk.nextNode()) n.nodeValue = swap(n.nodeValue);
    document.querySelectorAll("input").forEach((el) => (el.value = swap(el.value)));
  }, fake);
}

// Waits for live data, stops the page polling over the swapped numbers, then captures.
async function shot(page, hash, file, prepare) {
  await page.goto(`${BASE}/#${hash}`);
  await page.reload();               // a hash change alone keeps the last shot's dialog and stopped timers
  await page.waitForTimeout(2500);
  if (prepare) await prepare(page);
  await page.evaluate(() => { for (let id = setTimeout(() => {}, 0); id > 0; id--) { clearInterval(id); clearTimeout(id); } });
  await anonymize(page);
  await page.screenshot({ path: path.join(OUT, file) });
  console.log("saved", file);
}

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: VIEWPORT });
  await shot(page, "overview", "overview.png");
  await shot(page, "accounts", "accounts.png");
  await shot(page, "trades", "copied-trades.png");
  await shot(page, "activity", "activity.png");
  await shot(page, "overview", "settings.png", async (p) => {
    await p.locator("[data-settings]").first().click();
    await p.locator("#settings").waitFor({ state: "visible" });
  });
  await shot(page, "accounts", "add-account.png", async (p) => {
    await p.locator("#addAccountBtn").click();   // default: "Open a new MT5 and I'll log in there"
    await p.locator("#addForm").waitFor({ state: "visible" });
  });
  await browser.close();
})();
