// The activity log table and its filters.
import { $, esc, ms, pill, rowsOrEmpty } from "./dom.js";
import { getEvents } from "./api.js";

const KIND_TONES = { copy: "good", skip: "warn", error: "bad" };

const eventRow = (e) => `
  <tr>
    <td class="mono">${esc(e.time.slice(11))}<div class="sub">${esc(e.time.slice(0, 10))}</div></td>
    <td class="mono">${esc(e.login)}</td>
    <td>${pill(e.kind, KIND_TONES[e.kind] || "muted")}</td>
    <td class="mono">${e.master ? esc(e.master) : "–"}</td>
    <td class="msg">${esc(e.msg)}</td>
    <td class="num">${e.latency_ms != null ? ms(e.latency_ms) : ""}</td>
  </tr>`;

export async function refreshActivity() {
  const kinds = $("#logKind").value ? $("#logKind").value.split(",") : null;
  try {
    let events = await getEvents($("#logAccount").value);
    if (kinds) events = events.filter((e) => kinds.includes(e.kind));
    $("#events").innerHTML = rowsOrEmpty(events, eventRow, 6, "No activity yet.");
  } catch {
    // the overview poll already shows the connection state
  }
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
  $("#logAccount").addEventListener("change", refreshActivity);
  $("#logKind").addEventListener("change", refreshActivity);
}
