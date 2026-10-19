// Renders the summary, master and followers from /api/overview.
import { $, esc, money, lots, ms, pill, rowsOrEmpty } from "./dom.js";

const STATES = {
  copying:             ["Copying", "good"],
  paused:              ["Paused", "warn"],
  master_stale:        ["Master offline", "warn"],
  no_master:           ["No master", "bad"],
  algo_off:            ["Algo Trading off", "bad"],
  not_logged_in:       ["Not logged in", "muted"],
  netting_unsupported: ["Netting account", "bad"],
  is_master:           ["Wrong MasterId", "bad"],
  stopped:             ["Stopped", "muted"],
  risk_stop:           ["Risk stop", "bad"],
};

// Today's P&L, and how much of the daily loss limit is used.
function riskMeter({ risk }) {
  if (!risk) return "–";
  const pnl = `<span class="${risk.daily_pnl < 0 ? "neg" : "pos"}">${money(risk.daily_pnl)}</span>`;
  if (!risk.daily_loss_limit) return `${pnl} <span class="sub">no limit</span>`;
  const used = Math.min(100, Math.max(0, (-risk.daily_pnl / risk.daily_loss_limit) * 100));
  const tone = risk.breached || used >= 100 ? "bad" : used >= 70 ? "warn" : "";
  return `<div class="meter" title="${esc(risk.reason || `${used.toFixed(0)}% of daily limit used`)}">
      <span>${pnl} <span class="sub">/ −${money(risk.daily_loss_limit)}</span></span>
      <div class="meter-bar"><div class="meter-fill ${tone}" style="width:${used}%"></div></div>
    </div>`;
}

const onlinePill = (online, yes = "Online") => (online ? pill(yes, "good") : pill("Offline", "bad"));

function followerState(f) {
  if (!f.online) return pill("Offline", "muted", `No status update for ${Math.round(f.age_ms / 1000)} s`);
  const [label, tone] = STATES[f.state] || [f.state, "muted"];
  return pill(label, tone);
}

const average = (xs) => (xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : 0);

export function renderOverview({ masters, followers, paused }) {
  renderPause(paused);
  renderStats(masters, followers);
  if (masters.length) $("#masters").innerHTML = masters.map(masterHtml).join("");
  if (followers.length) $("#followers").innerHTML = followers.map(followerRow).join("");
}

function renderPause(paused) {
  const btn = $("#pauseBtn");
  btn.disabled = false;
  btn.textContent = paused ? "Resume copying" : "Pause all copying";
  btn.className = `btn ${paused ? "btn-good" : "btn-danger"}`;
  $("#pausedBanner").hidden = !paused;
}

function renderStats(masters, followers) {
  const online = followers.filter((f) => f.online);
  const latencies = online.map((f) => f.latency_avg_ms).filter((v) => v > 0);
  $("#statMaster").innerHTML = masters.length ? onlinePill(masters[0].online) : "–";
  $("#statFollowers").textContent = `${online.filter((f) => f.state === "copying").length} / ${followers.length}`;
  $("#statCopies").textContent = followers.reduce((n, f) => n + (f.open_copies || 0), 0);
  $("#statLatency").textContent = latencies.length ? ms(average(latencies)) : "–";
}

const kv = (label, value) => `<div class="kv"><span>${label}</span><span>${value}</span></div>`;

const positionRow = (p) => `
  <tr>
    <td class="mono">${esc(p.ticket)}</td>
    <td>${esc(p.symbol)}</td>
    <td class="side-${esc(p.type)}">${esc(p.type.toUpperCase())}</td>
    <td class="num">${lots(p.volume)}</td>
    <td class="num">${esc(p.price)}</td>
    <td class="num">${p.sl ? esc(p.sl) : "–"}</td>
    <td class="num">${p.tp ? esc(p.tp) : "–"}</td>
  </tr>`;

const masterHtml = (m) => `
  <div class="master">
    ${kv("Account", `<span class="mono">${esc(m.master_id)}</span> <span class="sub">${esc(m.server)}</span>`)}
    ${kv("Status", onlinePill(m.online, "Publishing"))}
    ${kv("Balance", money(m.balance))}
    ${kv("Equity", money(m.equity))}
  </div>
  <div class="table-wrap">
    <table class="table">
      <thead><tr><th>Ticket</th><th>Symbol</th><th>Side</th><th class="num">Lots</th><th class="num">Open price</th><th class="num">SL</th><th class="num">TP</th></tr></thead>
      <tbody>${rowsOrEmpty(m.positions, positionRow, 7, "No open positions.")}</tbody>
    </table>
  </div>`;

const followerRow = (f) => `
  <tr>
    <td><span class="mono">${esc(f.login)}</span><div class="sub">${esc(f.server)}</div></td>
    <td>${followerState(f)}</td>
    <td class="num">×${esc(f.multiplier)}</td>
    <td class="num">${esc(f.open_copies)}</td>
    <td class="num">${money(f.equity)}<div class="sub">bal ${money(f.balance)}</div></td>
    <td>${riskMeter(f)}</td>
    <td class="num">${ms(f.latency_last_ms)} / ${ms(f.latency_avg_ms)}</td>
    <td class="num"><button class="btn btn-small" type="button" data-settings="${esc(f.login)}">Settings</button></td>
  </tr>`;
