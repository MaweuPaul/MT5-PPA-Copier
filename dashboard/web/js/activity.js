// Activity log: type chips, account filter, search, count and CSV export.
import { $, esc, ms, pill, rowsOrEmpty } from "./dom.js";

const KIND_TONES = { open: "good", partial: "good", sltp: "good", close: "muted", skip: "warn", error: "bad", risk: "bad" };

let events = [];
let kinds = null;     // null = all

const eventRow = (e) => `
  <tr>
    <td class="mono">${esc(e.time.slice(11))}<div class="sub">${esc(e.time.slice(0, 10))}</div></td>
    <td class="mono">${esc(e.login)}</td>
    <td>${pill(e.kind, KIND_TONES[e.kind] || "muted")}</td>
    <td class="mono">${e.master ? esc(e.master) : "–"}</td>
    <td class="msg">${esc(e.msg)}</td>
    <td class="num">${e.latency_ms != null ? ms(e.latency_ms) : ""}</td>
  </tr>`;

function visible() {
  const account = $("#logAccount").value;
  const q = $("#logSearch").value.trim().toLowerCase();
  return events.filter((e) =>
    (!account || String(e.login) === account) &&
    (!kinds || kinds.includes(e.kind)) &&
    (!q || `${e.master} ${e.login} ${e.kind} ${e.msg}`.toLowerCase().includes(q)));
}

function render() {
  const rows = visible();
  $("#logCount").textContent = `${rows.length} of ${events.length} entries`;
  $("#events").innerHTML = rowsOrEmpty(rows, eventRow, 6, "No matching activity.");
}

/** Called by main with the latest events (newest first). */
export function renderActivity(latest) {
  events = latest;
  render();
}

function exportCsv() {
  const cols = ["time", "login", "kind", "master", "msg", "latency_ms", "symbol", "side", "lots", "price", "master_price"];
  const cell = (v) => `"${String(v ?? "").replace(/"/g, '""')}"`;
  const csv = [cols.join(","), ...visible().map((e) => cols.map((c) => cell(e[c])).join(","))].join("\r\n");
  const a = Object.assign(document.createElement("a"), {
    href: URL.createObjectURL(new Blob([csv], { type: "text/csv" })),
    download: `tradecopier-activity-${new Date().toISOString().slice(0, 10)}.csv`,
  });
  a.click();
  URL.revokeObjectURL(a.href);
}

/** Keeps the account filter in sync with the followers that exist. */
export function syncAccountFilter(followers) {
  const sel = $("#logAccount");
  const wanted = ["", ...followers.map((f) => String(f.login))];
  if (wanted.join() === [...sel.options].map((o) => o.value).join()) return;
  const current = sel.value;
  sel.innerHTML = `<option value="">All accounts</option>` +
    followers.map((f) => `<option value="${esc(f.login)}">${esc(f.login)} · ${esc(f.server)}</option>`).join("");
  sel.value = wanted.includes(current) ? current : "";
}

export function initActivity() {
  $("#kindChips").addEventListener("click", (ev) => {
    const chip = ev.target.closest(".chip");
    if (!chip) return;
    document.querySelectorAll("#kindChips .chip").forEach((c) => c.classList.toggle("active", c === chip));
    kinds = chip.dataset.kinds ? chip.dataset.kinds.split(",") : null;
    render();
  });
  $("#logAccount").addEventListener("change", render);
  $("#logSearch").addEventListener("input", render);
  $("#exportBtn").addEventListener("click", exportCsv);
}
