// Entry point: wires the views together and runs the polling loops.
import { $ } from "./dom.js";
import { getOverview, getEvents, setPaused } from "./api.js";
import { initRouter } from "./router.js";
import { renderOverview } from "./overview.js";
import { initActivity, renderActivity, syncAccountFilter } from "./activity.js";
import { renderTrades } from "./trades.js";
import { initSettings } from "./settings.js";
import { initTemplates } from "./templates.js";
import { initNotify, checkOverview, checkEvents } from "./notify.js";

const OVERVIEW_EVERY_MS = 1000;
const EVENTS_EVERY_MS = 2000;
const EVENT_LIMIT = 1000;

let overview = null;

function setConnection(ok) {
  $("#conn").className = `pill ${ok ? "pill-good" : "pill-bad"}`;
  $("#conn").textContent = ok ? "live" : "dashboard offline";
}

async function refreshOverview() {
  try {
    overview = await getOverview();
    setConnection(true);
    renderOverview(overview);
    syncAccountFilter(overview.followers);
    checkOverview(overview);
  } catch {
    setConnection(false);
  }
}

// One events fetch feeds the activity log, the trades page and alerts.
async function refreshEvents() {
  try {
    const events = await getEvents("", EVENT_LIMIT);
    renderActivity(events);
    renderTrades(events);
    checkEvents(events);
  } catch {
    // the overview poll already shows the connection state
  }
}

$("#pauseBtn").addEventListener("click", async (ev) => {
  ev.currentTarget.disabled = true;
  try {
    await setPaused(!overview?.paused);
  } catch (err) {
    alert(err.message);
  }
  refreshOverview();
});

initRouter();
initActivity();
initTemplates();
initNotify();
initSettings({
  overview: () => overview,
  onSaved: () => {
    refreshOverview();
    setTimeout(refreshEvents, 1500); // the EA logs "settings applied" within ~0.5 s
  },
});

refreshOverview();
refreshEvents();
setInterval(refreshOverview, OVERVIEW_EVERY_MS);
setInterval(refreshEvents, EVENTS_EVERY_MS);
