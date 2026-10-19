// Entry point: wires the views together and runs the polling loops.
import { $ } from "./dom.js";
import { getOverview, setPaused } from "./api.js";
import { renderOverview } from "./overview.js";
import { initActivity, refreshActivity, syncAccountFilter } from "./activity.js";
import { initSettings } from "./settings.js";

const OVERVIEW_EVERY_MS = 1000;
const ACTIVITY_EVERY_MS = 2000;

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
  } catch {
    setConnection(false);
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

initActivity();
initSettings({
  overview: () => overview,
  onSaved: () => {
    refreshOverview();
    setTimeout(refreshActivity, 1500); // the EA logs "settings applied" within ~0.5 s
  },
});

refreshOverview();
refreshActivity();
setInterval(refreshOverview, OVERVIEW_EVERY_MS);
setInterval(refreshActivity, ACTIVITY_EVERY_MS);
