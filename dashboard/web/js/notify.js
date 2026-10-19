// Desktop alerts (browser notifications) for things that need attention:
// master going offline, a follower in a bad state, failed copies, risk stops.
import { $ } from "./dom.js";

const BAD_STATES = new Set(["no_master", "algo_off", "netting_unsupported", "is_master", "risk_stop", "master_stale"]);
const ALERT_KINDS = new Set(["error", "risk"]);

let lastStates = null;   // login -> state, from the previous poll
let lastMasterOnline = null;
let seenUpTo = null;     // newest event key already handled

const TOAST_MS = 8000;

// "unsupported" (e.g. VS Code's built-in browser) | "default" | "granted" | "denied"
const permission = () => ("Notification" in window ? Notification.permission : "unsupported");

// In-page toast always; a desktop notification too when the browser allows it.
function notify(title, body) {
  toast(title, body);
  if (permission() === "granted") new Notification(title, { body, tag: `${title}:${body}` });
}

function toast(title, body) {
  const box = $("#toasts") ?? document.body.appendChild(Object.assign(document.createElement("div"), { id: "toasts" }));
  const el = document.createElement("div");
  el.className = "toast";
  el.append(Object.assign(document.createElement("strong"), { textContent: title }),
            Object.assign(document.createElement("div"), { textContent: body }));
  box.prepend(el);
  setTimeout(() => el.remove(), TOAST_MS);
}

const BUTTON = {
  unsupported: ["In-page alerts", "This browser can't show desktop notifications. Alerts appear inside the dashboard instead. Open it in Chrome or Edge for desktop alerts."],
  default:     ["Enable desktop alerts", ""],
  granted:     ["Desktop alerts on", ""],
  denied:      ["Desktop alerts blocked", "Notifications are blocked for this page. Click the icon left of the address bar → Site settings → Notifications → Allow, then reload. In-page alerts still work."],
};

function syncButton() {
  const [label, help] = BUTTON[permission()];
  $("#notifyBtn").textContent = label;
  $("#notifyBtn").title = help;
}

async function onButton() {
  const p = permission();
  if (p === "default") await Notification.requestPermission();
  else if (p !== "granted") alert(BUTTON[p][1]);
  syncButton();
  notify("Alerts are working", "You'll see copy failures, risk stops and offline accounts here.");
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
  $("#notifyBtn").addEventListener("click", onButton);
}
