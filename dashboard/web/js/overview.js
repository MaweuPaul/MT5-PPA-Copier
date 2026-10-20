// Overview: health banner, summary tiles, main account and follower cards.
import { $, esc, money, lots, ms, pill, rowsOrEmpty } from "./dom.js";

// state -> [label, tone, plain-language note shown on the card when not fine]
const STATES = {
  copying:             ["Copying", "good", ""],
  paused:              ["Paused", "warn", "Copying is paused. New trades won't be copied."],
  risk_stop:           ["Stopped by safety limit", "bad", ""],
  master_stale:        ["Main account offline", "warn", "Your main account's MT5 isn't sending updates. Open trades are kept."],
  no_master:           ["Can't find main account", "bad", "Check the Master ID in this account's EA settings."],
  algo_off:            ["Algo Trading is off", "bad", "Turn on the Algo Trading button in this account's MT5."],
  not_logged_in:       ["Not logged in", "muted", "This MT5 isn't connected to its account."],
  netting_unsupported: ["Unsupported account type", "bad", "This account uses netting mode. Use a hedging account."],
  is_master:           ["Set up wrong", "bad", "This EA is pointed at its own account. Use CopierMaster here instead."],
  stopped:             ["Stopped", "muted", "The copier EA was removed from this MT5."],
};

const stateOf = (f) => (f.online ? STATES[f.state] || [f.state, "muted", ""] : ["Offline", "muted", "No update from this MT5 for a while. Is it open?"]);
const signed = (v) => `<span class="${v < 0 ? "neg" : v > 0 ? "pos" : ""}">${v > 0 ? "+" : ""}${money(v)}</span>`;
const average = (xs) => (xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : 0);

export function renderOverview({ masters, followers, paused }) {
  renderPause(paused);
  renderHealth(masters[0], followers, paused);
  renderStats(followers);
  if (masters.length) $("#masters").innerHTML = masters.map(masterHtml).join("");
  if (followers.length) $("#followers").innerHTML = followers.map(followerCard).join("");
}

function renderPause(paused) {
  const btn = $("#pauseBtn");
  btn.disabled = false;
  btn.textContent = paused ? "▶ Resume copying" : "⏸ Pause all copying";
  btn.className = `btn ${paused ? "btn-good" : "btn-danger"}`;
  $("#pausedBanner").hidden = !paused;
}

// One sentence that says whether everything is OK, and if not, what to look at.
function renderHealth(master, followers, paused) {
  const problems = followers.filter((f) => stateOf(f)[1] === "bad" || !f.online);
  const copying = followers.filter((f) => f.online && f.state === "copying").length;
  let tone = "good", icon = "✓", title, text;
  if (!master) {
    [tone, icon, title, text] = ["bad", "!", "Main account not found", "Attach CopierMaster to a chart in your main account's MT5."];
  } else if (!master.online) {
    [tone, icon, title, text] = ["bad", "!", "Main account is offline", "Its MT5 isn't sending updates. Copied trades stay open until it's back."];
  } else if (problems.length) {
    tone = "bad"; icon = "!";
    title = `${problems.length} account${problems.length > 1 ? "s need" : " needs"} attention`;
    text = problems.map((f) => `${f.login}: ${stateOf(f)[0]}`).join(" · ");
  } else if (paused) {
    [tone, icon, title, text] = ["warn", "⏸", "Copying is paused", "Press Resume copying when you're ready."];
  } else {
    title = "Everything's running";
    text = `${copying} of ${followers.length} account${followers.length === 1 ? " is" : "s are"} copying your trades.`;
  }
  $("#health").className = `health ${tone === "good" ? "" : tone}`;
  const fix = tone === "bad" ? `<button class="btn btn-good" type="button" data-launch-all>▶ Launch all accounts</button>` : "";
  $("#health").innerHTML = `<div class="health-icon">${icon}</div><div><h3>${esc(title)}</h3><p>${esc(text)}</p></div>${fix}`;
}

function renderStats(followers) {
  const online = followers.filter((f) => f.online);
  const latencies = online.map((f) => f.latency_avg_ms).filter((v) => v > 0);
  $("#statFollowers").textContent = `${online.filter((f) => f.state === "copying").length} of ${followers.length}`;
  $("#statCopies").textContent = followers.reduce((n, f) => n + (f.open_copies || 0), 0);
  $("#statPnl").innerHTML = signed(followers.reduce((s, f) => s + (f.risk?.daily_pnl || 0), 0));
  $("#statLatency").textContent = latencies.length ? ms(average(latencies)) : "–";
}

const kv = (label, value) => `<div class="kv"><span>${label}</span><span>${value}</span></div>`;

const positionRow = (p) => `
  <tr>
    <td><strong>${esc(p.symbol)}</strong></td>
    <td><span class="side side-${esc(p.type)}">${p.type === "buy" ? "BUY" : "SELL"}</span></td>
    <td class="num">${lots(p.volume)}</td>
    <td class="num">${esc(p.price)}</td>
    <td class="num">${p.sl ? esc(p.sl) : "–"}</td>
    <td class="num">${p.tp ? esc(p.tp) : "–"}</td>
    <td class="sub mono">#${esc(p.ticket)}</td>
  </tr>`;

const masterHtml = (m) => `
  <div class="master-head">
    ${kv("Account", `${esc(m.master_id)} <span class="sub">${esc(m.server)}</span>`)}
    ${kv("Status", m.online ? pill("Online", "good") : pill("Offline", "bad"))}
    ${kv("Balance", money(m.balance))}
    ${kv("Equity", money(m.equity))}
    ${kv("Open trades", m.positions.length)}
  </div>
  <div class="table-wrap">
    <table class="table">
      <thead><tr><th>Symbol</th><th>Direction</th><th class="num">Lots</th><th class="num">Opened at</th><th class="num">Stop loss</th><th class="num">Take profit</th><th>Ticket</th></tr></thead>
      <tbody>${rowsOrEmpty(m.positions, positionRow, 7, "No open trades right now.")}</tbody>
    </table>
  </div>`;

// Today's result against the daily loss limit, as a bar.
function riskMeter({ risk }) {
  if (!risk?.daily_loss_limit) return "";
  const used = Math.min(100, Math.max(0, (-risk.daily_pnl / risk.daily_loss_limit) * 100));
  const tone = risk.breached || used >= 100 ? "bad" : used >= 70 ? "warn" : "";
  return `<div class="meter">
      <div class="meter-label"><span>Daily loss limit</span><span>${used.toFixed(0)}% used of ${money(risk.daily_loss_limit)}</span></div>
      <div class="meter-bar"><div class="meter-fill ${tone}" style="width:${used}%"></div></div>
    </div>`;
}

const fact = (label, value) => `<div class="fact"><span>${label}</span><span>${value}</span></div>`;

function followerCard(f) {
  const [label, tone, note] = stateOf(f);
  const why = f.state === "risk_stop" ? f.risk?.reason : note;
  return `
  <article class="account ${tone}">
    <div class="account-top">
      <div><div class="account-name">${esc(f.server)}</div><div class="sub mono">${esc(f.login)}</div></div>
      ${pill(label, tone)}
    </div>
    <div>
      <div class="sub">Equity</div>
      <div class="account-equity">${money(f.equity)}</div>
      <div class="sub">Today ${signed(f.risk?.daily_pnl ?? 0)} · Balance ${money(f.balance)}</div>
    </div>
    <div class="account-facts">
      ${fact("Lot size", `×${esc(f.multiplier)}`)}
      ${fact("Open trades", esc(f.open_copies))}
      ${fact("Copy speed", ms(f.latency_avg_ms))}
    </div>
    ${riskMeter(f)}
    ${why ? `<p class="account-note">${esc(why)}</p>` : ""}
    <div class="actions" style="justify-content:flex-start">
      ${f.online ? "" : `<button class="btn btn-small btn-good" type="button" data-account-action="start" data-login="${esc(f.login)}">▶ Start MT5</button>`}
      ${f.online ? "" : `<button class="btn btn-small btn-danger" type="button" data-account-action="remove" data-login="${esc(f.login)}">Remove</button>`}
      <button class="btn btn-small" type="button" data-settings="${esc(f.login)}">⚙ Settings</button>
    </div>
  </article>`;
}
