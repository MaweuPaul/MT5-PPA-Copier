// Tiny DOM + formatting helpers shared by every view.

export const $ = (sel) => document.querySelector(sel);

const ESCAPES = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };

/** Escapes text for safe use inside HTML templates. */
export const esc = (v) => String(v ?? "").replace(/[&<>"']/g, (c) => ESCAPES[c]);

const fmt = (min, max) => (v) =>
  Number(v ?? 0).toLocaleString(undefined, { minimumFractionDigits: min, maximumFractionDigits: max });

export const money = fmt(2, 2);
export const lots = fmt(2, 3);
/** Durations people can read: "320 ms", "1.4 s". */
export const ms = (v) => (!v ? "–" : v < 1000 ? `${Number(v).toFixed(0)} ms` : `${(v / 1000).toFixed(1)} s`);

/** tone: good | warn | bad | muted */
export const pill = (label, tone, title = "") =>
  `<span class="pill pill-${tone}"${title ? ` title="${esc(title)}"` : ""}>${esc(label)}</span>`;

/** Renders rows, or a single "empty" row spanning the table. */
export const rowsOrEmpty = (items, row, cols, emptyText) =>
  items.length ? items.map(row).join("") : `<tr><td colspan="${cols}" class="empty">${esc(emptyText)}</td></tr>`;
