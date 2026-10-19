// The follower settings dialog: load, live lot preview, validate, save.
import { $, lots } from "./dom.js";
import { getConfig, saveConfig } from "./api.js";
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
};

let login = null;
let getOverview = () => null;

function fillForm(config) {
  for (const [name, type] of Object.entries(FIELDS)) {
    const el = form.elements[name];
    if (type === "bool") el.checked = !!config[name];
    else el.value = config[name] ?? "";
  }
}

function readForm() {
  const out = {};
  for (const [name, type] of Object.entries(FIELDS)) {
    const el = form.elements[name];
    out[name] = type === "bool" ? el.checked : type === "number" ? Number(el.value || 0) : el.value.trim();
  }
  return out;
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
