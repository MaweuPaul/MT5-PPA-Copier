// Trades & slippage: every copy's fill against the master's open price.
import { $, esc, lots, ms, rowsOrEmpty } from "./dom.js";

// Points of slippage, signed so positive = worse than the master
// (paid more on a buy, received less on a sell).
function slippagePoints(e) {
  if (!e.point || !e.master_price || !e.price) return null;
  const diff = (e.price - e.master_price) / e.point;
  return e.side === "buy" ? diff : -diff;
}

function slippageCell(e) {
  const p = slippagePoints(e);
  if (p == null) return "–";
  const cls = p > 0.5 ? "neg" : p < -0.5 ? "pos" : "";
  return `<span class="${cls}">${p > 0 ? "+" : ""}${p.toFixed(1)} pts</span>`;
}

const tradeRow = (e, i, all) => {
  const first = i === 0 || all[i - 1].master !== e.master;   // master info once per group
  return `<tr>
    <td class="mono">${first ? `#${esc(e.master)}<div class="sub">${esc(e.side?.toUpperCase())} ${lots(e.master_lots)} @ ${esc(e.master_price)}</div>` : ""}</td>
    <td class="mono">${esc(e.login)}<div class="sub">${esc(e.symbol)}</div></td>
    <td class="num">${lots(e.lots)}</td>
    <td class="num">${esc(e.price)}</td>
    <td class="num">${slippageCell(e)}</td>
    <td class="num">${ms(e.latency_ms)}</td>
    <td class="mono">${esc(e.time.slice(11))}</td>
  </tr>`;
};

export function renderTrades(events) {
  const opens = events
    .filter((e) => e.kind === "open")
    .sort((a, b) => (b.master - a.master) || (a.login - b.login));   // newest master first, grouped
  $("#trades").innerHTML = rowsOrEmpty(opens, tradeRow, 7, "No copied trades yet.");
}
