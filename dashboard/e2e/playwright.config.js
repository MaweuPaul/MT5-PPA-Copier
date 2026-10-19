// End-to-end tests against the running dashboard (and the live demo EAs).
// Start the dashboard first: ..\tradecopier-dashboard.exe -open=false
//
// WARNING: the tests briefly pause copying and change follower settings
// (restored afterwards). Don't place trades on the master while they run:
// a trade opened during the pause test is skipped for good.
const { defineConfig } = require("@playwright/test");

module.exports = defineConfig({
  testDir: "./tests",
  workers: 1,                 // tests share live accounts, so run one at a time
  timeout: 60_000,
  expect: { timeout: 10_000 }, // EA applies settings within ~0.5 s, status every 1 s
  reporter: [["list"]],
  use: {
    baseURL: "http://127.0.0.1:8750",
    viewport: { width: 1400, height: 1000 },
    screenshot: "only-on-failure",
  },
});
