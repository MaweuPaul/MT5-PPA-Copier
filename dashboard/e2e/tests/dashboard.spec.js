// Dashboard end-to-end tests. They change live follower settings, so every
// setting and the pause state are restored afterwards.
const { test, expect, request: pwRequest } = require("@playwright/test");
const { overview, getConfig, snapshotState, openSettings, card } = require("./helpers");

let api;         // own request context: fixtures can't be reused in afterAll
let restore;
let followers;   // from /api/overview at start
let pepper;      // first follower's login, used for tests that change settings

test.beforeAll(async () => {
  api = await pwRequest.newContext({ baseURL: "http://127.0.0.1:8750" });
  restore = await snapshotState(api);
  followers = (await overview(api)).followers;
  pepper = String(followers[0].login);
});

test.afterAll(async () => {
  await restore();
  await api.dispose();
});

test("overview: health banner, main account and every follower card", async ({ page }) => {
  await page.goto("/#overview");
  await expect(page.locator("#conn")).toHaveText("Live");
  await expect(page.locator("#health h3")).not.toHaveText("Connecting…");
  await expect(page.locator("#masters .master-head")).toBeVisible();
  await expect(page.locator("article.account")).toHaveCount(followers.length);
  await page.screenshot({ path: "screenshots/overview.png", fullPage: true });
});

test("sidebar switches pages", async ({ page }) => {
  await page.goto("/");
  for (const [nav, title] of [["accounts", "Accounts"], ["trades", "Copied trades"], ["activity", "Activity"], ["templates", "Templates"], ["overview", "Overview"]]) {
    await page.locator(`[data-nav="${nav}"]`).click();
    await expect(page.locator("#pageTitle")).toHaveText(title);
    await expect(page.locator(`[data-page="${nav}"]`)).toBeVisible();
    await expect(page.locator(`[data-page]:not([data-page="${nav}"]):visible`)).toHaveCount(0);   // only one page at a time
    await page.screenshot({ path: `screenshots/${nav}.png`, fullPage: true });
  }
});

test("settings: loads saved values and previews lot sizes", async ({ page, request }) => {
  const config = await getConfig(request, pepper);
  await openSettings(page, pepper);
  const mult = page.locator('#settingsForm [name="multiplier"]');
  await expect(mult).toHaveValue(String(config.multiplier));
  await mult.fill("0.5");
  await expect(page.locator("#preview")).toContainText("Master 0.10 lot → 0.05 lot here");
  await mult.fill("0.05");
  await expect(page.locator("#preview")).toContainText("Master 0.10 lot → 0.01 lot here"); // rounds up to min
  await page.screenshot({ path: "screenshots/settings.png" });
  await page.locator('#settingsForm button[value="cancel"]').last().click();
  await expect(page.locator("#settings")).toBeHidden();
});

test("settings: invalid values are not saved", async ({ page, request }) => {
  const before = await getConfig(request, pepper);
  await openSettings(page, pepper);
  await page.locator('#settingsForm [name="multiplier"]').fill("");
  await page.locator("#saveBtn").click();
  await expect(page.locator("#settings")).toBeVisible();          // browser blocks the empty field
  await page.locator('#settingsForm [name="multiplier"]').fill("1");
  await page.locator('#settingsForm [name="trade_start"]').fill("25:00");
  await page.locator("#saveBtn").click();
  await expect(page.locator("#settings")).toBeVisible();          // pattern blocks 25:00
  expect(await getConfig(request, pepper)).toEqual(before);
});

test("settings: copy delay is applied live by the EA", async ({ page, request }) => {
  await openSettings(page, pepper);
  await page.locator('#settingsForm [name="delay_ms"]').fill("1500");
  await page.locator('#settingsForm [name="delay_jitter_ms"]').fill("500");
  await page.locator("#saveBtn").click();
  await expect(page.locator("#settings")).toBeHidden();
  await expect.poll(async () => (await overview(request)).followers.find((f) => String(f.login) === pepper).settings.delay_ms)
    .toBe(1500);
});

test("safety: a daily loss limit below today's loss stops copying, removing it resumes", async ({ page, request }) => {
  const f = (await overview(request)).followers.find((x) => String(x.login) === pepper);
  test.skip(!(f.risk.daily_pnl < -0.01), "needs a losing day on this account to trigger the limit");

  await openSettings(page, pepper);
  await page.locator('#settingsForm [name="daily_loss_limit"]').fill("0.01");
  await page.locator("#saveBtn").click();
  await expect(card(page, pepper)).toContainText("Stopped by safety limit");
  await expect(card(page, pepper).locator(".meter-fill.bad")).toBeVisible();
  await expect(page.locator("#health")).toHaveClass(/bad/);
  await page.screenshot({ path: "screenshots/risk-stop.png", fullPage: true });

  await openSettings(page, pepper);
  await page.locator('#settingsForm [name="daily_loss_limit"]').fill("0");
  await page.locator("#saveBtn").click();
  await expect(card(page, pepper)).toContainText("Copying");
});

test("pause and resume all copying", async ({ page }) => {
  await page.goto("/#overview");
  await page.locator("#pauseBtn").click();
  await expect(page.locator("#pausedBanner")).toBeVisible();
  await expect(card(page, pepper)).toContainText("Paused");
  await page.screenshot({ path: "screenshots/paused.png", fullPage: true });
  await page.locator("#pauseBtn").click();
  await expect(page.locator("#pausedBanner")).toBeHidden();
  await expect(card(page, pepper)).toContainText("Copying");
});

test("activity: type filter, search, count and CSV export", async ({ page }) => {
  await page.goto("/#activity");
  await expect(page.locator("#logCount")).toContainText("entries");
  await page.locator('#kindChips .chip[data-kinds^="risk"]').click();
  await expect(page.locator("#events tr").first()).toContainText(/Settings|Status|Started|Safety limit|Note/);
  await page.locator("#logSearch").fill("settings applied");
  await expect(page.locator("#events")).toContainText("settings applied");
  const [download] = await Promise.all([page.waitForEvent("download"), page.locator("#exportBtn").click()]);
  expect(download.suggestedFilename()).toMatch(/^tradecopier-activity-.*\.csv$/);
});

test("templates: save from settings, list, load and delete", async ({ page }) => {
  const name = `e2e test ${Date.now()}`;
  page.on("dialog", (d) => (d.type() === "prompt" ? d.accept(name) : d.accept()));
  await openSettings(page, pepper);
  await page.locator('#settingsForm [name="multiplier"]').fill("0.7");
  await page.locator("#saveTemplateBtn").click();
  await page.locator('#settingsForm button[value="cancel"]').last().click();

  await page.goto("/#templates");
  await expect(page.locator("#templates")).toContainText(name);

  await openSettings(page, pepper);
  await page.locator("#templatePick").selectOption(name);
  await expect(page.locator('#settingsForm [name="multiplier"]')).toHaveValue("0.7");
  await page.locator('#settingsForm button[value="cancel"]').last().click();

  await page.goto("/#templates");
  await page.locator(`[data-delete-template="${name}"]`).click();
  await expect(page.locator("#templates")).not.toContainText(name);
});

test("alerts button shows an in-page alert", async ({ page }) => {
  page.on("dialog", (d) => d.accept());
  await page.goto("/#overview");
  await page.locator("#notifyBtn").click();
  await expect(page.locator(".toast").first()).toContainText("Alerts are working");
});

test("accounts: lists every registered MT5 with its running state", async ({ page }) => {
  const { accounts } = await (await api.get("/api/accounts")).json();
  await page.goto("/#accounts");
  await expect(page.locator("#accountsList tr")).toHaveCount(accounts.length);
  for (const a of accounts) await expect(page.locator("#accountsList")).toContainText(a.login);
  await expect(page.locator("#accountsList .pill-good")).toHaveCount(accounts.filter((a) => a.running).length);
  await expect(page.locator("#setupForm [name=mt5_source]")).not.toHaveValue("");
  await page.screenshot({ path: "screenshots/accounts.png", fullPage: true });
});

test("accounts: add form shows the server's validation error and creates nothing", async ({ page }) => {
  const count = async () => (await (await api.get("/api/accounts")).json()).accounts.length;
  const before = await count();
  await page.goto("/#accounts");
  await page.locator("#addAccountBtn").click();
  const f = page.locator("#addForm");
  await f.locator("[name=login]").fill("123");
  await f.locator("[name=password]").fill("x");
  await f.locator("[name=server]").fill("Bad/Server");   // "/" is not allowed in a server name
  await f.locator("[name=master_id]").fill("592208623");
  await page.screenshot({ path: "screenshots/add-account.png" });
  await page.locator("#addSubmit").click();
  await expect(page.locator("#addError")).toContainText("server");
  expect(await count()).toBe(before);
});
