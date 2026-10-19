// Desktop alerts (browser notifications) for things that need attention:
// master going offline, a follower in a bad state, failed copies, risk stops.
import { $ } from "./dom.js";

const BAD_STATES = new Set(["no_master", "algo_off", "netting_unsupported", "is_master", "risk_stop", "master_stale"]);
const ALERT_KINDS = new Set(["error", "risk"]);

let lastStates = null;   // login -> state, from the previous poll
let lastMasterOnline = null;
let seenUpTo = null;     // newest event key already handled

const enabled = () => "Notification" in window && Notification.permission === "granted";

function notify(title, body) {
  if (enabled()) new Notification(title, { body, tag: `${title}:${body}` });
}

function syncButton() {
  const btn = $("#notifyBtn");
  if (!("Notification" in window)) return (btn.hidden = true);
  btn.textContent = enabled() ? "Alerts on" : "Enable alerts";
  btn.disabled = enabled() || Notification.permission === "denied";
}

export function checkOverview({ masters, followers }) {
  const online = masters[0]?.online;
  if (lastMasterOnline === true && online === false) notify("Master offline", "The master stopped publishing. Copies are kept open.");
  lastMasterOnline = online ?? null;

  const states = new Map(followers.map((f) => [f.login, f.online ? f.state : "offline"]));
  if (lastStates) {
    for (const [login, state] of states) {
      if (state !== lastStates.get(login) && (BAD_STATES.has(state) || state === "offline")) {
        notify(`Follower ${login}: ${state.replace("_", " ")}`, "Check the dashboard.");
      }
    }
  }
  lastStates = states;
}

export function checkEvents(events) {
  const key = (e) => `${e.time}|${String(e.ms).padStart(15, "0")}`;
  if (seenUpTo !== null) {
    events.filter((e) => ALERT_KINDS.has(e.kind) && key(e) > seenUpTo)
      .slice(0, 3)
      .forEach((e) => notify(`${e.kind === "risk" ? "Risk stop" : "Copy failed"} · ${e.login}`, e.msg));
  }
  if (events.length) seenUpTo = key(events[0]);
  else if (seenUpTo === null) seenUpTo = "";
}

export function initNotify() {
  syncButton();
  $("#notifyBtn").addEventListener("click", async () => {
    await Notification.requestPermission();
    syncButton();
  });
}
