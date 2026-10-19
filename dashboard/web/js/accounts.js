// Accounts page: add an account in one form, start / stop / remove MT5s,
// and the one-time setup (MT5 folder, accounts folder, start with Windows).
import { $, esc, pill, rowsOrEmpty } from "./dom.js";
import { getAccounts, addAccount, getAddJob, accountAction, saveSetup } from "./api.js";

const JOB_POLL_MS = 1000;
const dialog = $("#addAccount");
const form = $("#addForm");
let getOverview = () => null;

const ROLE = { master: "Main account", follower: "Copies trades" };

const row = (a) => `
  <tr>
    <td><strong class="mono">${esc(a.login)}</strong><div class="sub">${esc(a.server)}</div></td>
    <td>${esc(ROLE[a.role] || a.role)}</td>
    <td>${a.running ? pill("Running", "good") : pill("Stopped", "muted")}</td>
    <td class="sub mono">${esc(a.dir)}</td>
    <td><div class="actions">
      ${a.running
        ? `<button class="btn btn-small" data-account-action="stop" data-login="${esc(a.login)}">Stop</button>`
        : `<button class="btn btn-small btn-good" data-account-action="start" data-login="${esc(a.login)}">Start</button>`}
      <button class="btn btn-small btn-danger" data-account-action="remove" data-login="${esc(a.login)}">Remove</button>
    </div></td>
  </tr>`;

export async function refreshAccounts() {
  try {
    const { accounts, settings, autostart } = await getAccounts();
    $("#accountsList").innerHTML = rowsOrEmpty(accounts, row, 5, "No accounts yet. Click “+ Add account”.");
    const f = $("#setupForm").elements;
    if (document.activeElement?.form !== $("#setupForm")) {   // don't overwrite while typing
      f.mt5_source.value = settings.mt5_source;
      f.terminals_dir.value = settings.terminals_dir;
      f.autostart.checked = autostart;
    }
  } catch { /* connection state is shown by the overview poll */ }
}

function syncRole() {
  const follower = form.elements.role.value === "follower";
  form.querySelector(".follower-only").hidden = !follower;
  form.elements.master_id.required = follower;
}

function openAdd() {
  form.reset();
  const master = getOverview()?.masters[0]?.master_id;
  if (master) form.elements.master_id.value = master;
  $("#addSteps").hidden = true;
  $("#addError").hidden = true;
  $("#addSubmit").disabled = false;
  syncRole();
  dialog.showModal();
}

function showSteps(steps, done) {
  $("#addSteps").hidden = false;
  $("#addSteps").innerHTML = steps.map((s, i) =>
    `<li class="${done || i < steps.length - 1 ? "done" : ""}">${esc(s)}</li>`).join("");
}

async function submitAdd() {
  const e = form.elements;
  const body = {
    role: e.role.value, login: e.login.value.trim(), password: e.password.value, server: e.server.value.trim(),
    master_id: e.master_id.value.trim(), multiplier: Number(e.multiplier.value || 1), symbol_suffix: e.symbol_suffix.value.trim(),
  };
  $("#addError").hidden = true;
  $("#addSubmit").disabled = true;
  try {
    const { job } = await addAccount(body);
    e.password.value = "";   // don't keep it in the page
    for (;;) {
      const s = await getAddJob(job);
      showSteps(s.steps, s.done && !s.error);
      if (s.error) throw new Error(s.error);
      if (s.done) break;
      await new Promise((r) => setTimeout(r, JOB_POLL_MS));
    }
    refreshAccounts();
  } catch (err) {
    $("#addError").textContent = err.message;
    $("#addError").hidden = false;
    $("#addSubmit").disabled = false;
  }
}

async function onAction(btn) {
  const { login, accountAction: action } = btn.dataset;
  if (action === "remove" && !confirm(`Remove ${login} from the dashboard?\n\nIts MT5 is closed. The folder stays on disk (it holds MT5's saved login and history) and you can delete it yourself.`)) return;
  btn.disabled = true;
  try {
    const { dir } = await accountAction(login, action);
    if (action === "remove") alert(`Removed. Its MT5 folder is still at:\n${dir}`);
  } catch (err) {
    alert(err.message);
  }
  refreshAccounts();
}

export function initAccounts({ overview }) {
  getOverview = overview;
  $("#addAccountBtn").addEventListener("click", openAdd);
  form.addEventListener("change", (ev) => ev.target.name === "role" && syncRole());
  form.addEventListener("submit", (ev) => {
    if (ev.submitter?.value !== "add") return;   // Close / ✕
    ev.preventDefault();
    submitAdd();
  });
  document.addEventListener("click", (ev) => {
    const btn = ev.target.closest("[data-account-action]");
    if (btn) onAction(btn);
  });
  $("#setupForm").addEventListener("submit", async (ev) => {
    ev.preventDefault();
    const f = ev.target.elements;
    try {
      await saveSetup({ mt5_source: f.mt5_source.value.trim(), terminals_dir: f.terminals_dir.value.trim(), autostart: f.autostart.checked });
      $("#setupMsg").textContent = "Saved.";
    } catch (err) {
      $("#setupMsg").textContent = err.message;
    }
  });
  refreshAccounts();
}
