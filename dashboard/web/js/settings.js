// The follower settings dialog: load, live lot preview, validate, save.
import { $, esc, lots } from "./dom.js";
import { getConfig, saveConfig, saveTemplate } from "./api.js";
import { refreshTemplates } from "./templates.js";
import { fillDelays, readDelays } from "./delays.js";
import { copyLots, validMultiplier, MIN_MULTIPLIER, MAX_MULTIPLIER } from "./lots.js";

const dialog = $("#settings");
const form = $("#settingsForm");

// Field name -> how to read it. Keys match the Go/EA config JSON.
const FIELDS = {
  enabled: "bool",
  multiplier: "number",
  max_lot: "number",
  round_up_min: "bool",
  copy_sltp: "bool",
  symbol_suffix: "text",
  symbol_prefix: "text",
  strip_suffix: "text",
  symbol_map: "text",
  daily_loss_limit: "number",
  equity_floor: "number",
  close_on_limit: "bool",
  max_open_trades: "number",
  max_total_lots: "number",
  trade_start: "text",
  trade_end: "text",
  news_minutes: "number",
};   // delays are read separately (entered in seconds, see delays.js)

let login = null;
let templates = {};
let getOverview = () => null;

function fillForm(config) {
  for (const [name, type] of Object.entries(FIELDS)) {
    const el = form.elements[name];
    if (type === "bool") el.checked = !!config[name];
    else el.value = config[name] ?? "";
  }
  fillDelays(form, config);
}

function readForm() {
  const out = {};
  for (const [name, type] of Object.entries(FIELDS)) {
    const el = form.elements[name];
    out[name] = type === "bool" ? el.checked : type === "number" ? Number(el.value || 0) : el.value.trim();
  }
  return { ...out, ...readDelays(form) };
}

function showError(msg) {
  $("#settingsError").textContent = msg;
  $("#settingsError").hidden = !msg;
}

function updatePreview() {
  const config = readForm();
  if (!validMultiplier(config.multiplier)) {
    $("#preview").textContent = `Multiplier must be between ${MIN_MULTIPLIER} and ${MAX_MULTIPLIER}.`;
    return;
  }
  const open = getOverview()?.masters[0]?.positions.map((p) => p.volume) ?? [];
  const samples = [...new Set([...open, 0.1, 1])].sort((a, b) => a - b).slice(0, 4);
  $("#preview").innerHTML = samples.map((m) => {
    const v = copyLots(m, config);
    return `Master ${lots(m)} lot → <strong>${v ? `${lots(v)} lot` : "skipped"}</strong> here`;
  }).join("<br>");
}

export async function openSettings(forLogin) {
  login = forLogin;
  showError("");
  const f = getOverview()?.followers.find((x) => String(x.login) === login);
  $("#settingsTitle").textContent = `Settings · ${login}${f ? ` (${f.server})` : ""}`;
  try {
    fillForm(await getConfig(login));
    templates = Object.fromEntries(await refreshTemplates());
    $("#templatePick").innerHTML = `<option value="">-</option>` +
      Object.keys(templates).map((n) => `<option>${esc(n)}</option>`).join("");
    updatePreview();
    dialog.showModal();
  } catch (err) {
    alert(`Could not load settings: ${err.message}`);
  }
}

/** onSaved runs after a successful save (e.g. to refresh the screen). */
export function initSettings({ overview, onSaved }) {
  getOverview = overview;
  form.addEventListener("input", updatePreview);
  $("#templatePick").addEventListener("change", (ev) => {
    const t = templates[ev.target.value];
    if (t) fillForm(t);
    updatePreview();
  });
  $("#saveTemplateBtn").addEventListener("click", async () => {
    const name = prompt("Template name (e.g. Exness 0.5x):");
    if (!name) return;
    try {
      await saveTemplate(name.trim(), readForm());
      refreshTemplates();
      showError("");
    } catch (err) {
      showError(err.message);
    }
  });
  form.addEventListener("submit", async (ev) => {
    if (ev.submitter?.value !== "save") return; // Cancel / ✕ just close
    ev.preventDefault();
    const btn = $("#saveBtn");
    btn.disabled = true;
    try {
      await saveConfig(login, readForm());
      dialog.close();
      onSaved();
    } catch (err) {
      showError(err.message);
    } finally {
      btn.disabled = false;
    }
  });
  document.addEventListener("click", (ev) => {
    const target = ev.target.closest("[data-settings]");
    if (target) openSettings(target.dataset.settings);
  });
}
