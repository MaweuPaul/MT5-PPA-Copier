// Tiny DOM + formatting helpers shared by every view.

export const $ = (sel) => document.querySelector(sel);

const ESCAPES = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };

/** Escapes text for safe use inside HTML templates. */
export const esc = (v) => String(v ?? "").replace(/[&<>"']/g, (c) => ESCAPES[c]);

const fmt = (min, max) => (v) =>
  Number(v ?? 0).toLocaleString(undefined, { minimumFractionDigits: min, maximumFractionDigits: max });

export const money = fmt(2, 2);
export const lots = fmt(2, 3);
export const ms = (v) => (v ? `${Number(v).toFixed(0)} ms` : "–");

/** tone: good | warn | bad | muted */
export const pill = (label, tone, title = "") =>
  `<span class="pill pill-${tone}"${title ? ` title="${esc(title)}"` : ""}>${esc(label)}</span>`;

/** Renders rows, or a single "empty" row spanning the table. */
export const rowsOrEmpty = (items, row, cols, emptyText) =>
  items.length ? items.map(row).join("") : `<tr><td colspan="${cols}" class="empty">${esc(emptyText)}</td></tr>`;
