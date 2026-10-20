// Templates page: saved settings presets (applied from a follower's Settings).
import { $, esc, money, rowsOrEmpty } from "./dom.js";
import { getTemplates, deleteTemplate } from "./api.js";
import { describeDelay } from "./delays.js";

const row = ([name, c]) => `
  <tr>
    <td>${esc(name)}</td>
    <td class="num">×${esc(c.multiplier)}</td>
    <td class="mono">${esc(c.symbol_suffix) || "–"}</td>
    <td class="num">${c.daily_loss_limit ? money(c.daily_loss_limit) : "off"}</td>
    <td class="num">open ${describeDelay(c.delay_ms, c.delay_jitter_ms)} · close ${describeDelay(c.close_delay_ms, c.close_delay_jitter_ms)}</td>
    <td class="num"><button class="btn btn-small btn-danger" type="button" data-delete-template="${esc(name)}">Delete</button></td>
  </tr>`;

export async function refreshTemplates() {
  try {
    const list = Object.entries(await getTemplates()).sort(([a], [b]) => a.localeCompare(b));
    $("#templates").innerHTML = rowsOrEmpty(list, row, 6, "No templates yet.");
    return list;
  } catch {
    return [];
  }
}

export function initTemplates() {
  document.addEventListener("click", async (ev) => {
    const name = ev.target.closest("[data-delete-template]")?.dataset.deleteTemplate;
    if (!name || !confirm(`Delete template "${name}"?`)) return;
    await deleteTemplate(name).catch((err) => alert(err.message));
    refreshTemplates();
  });
  refreshTemplates();
}
