// Hash router: #overview, #trades, #activity, #templates.
import { $ } from "./dom.js";

const PAGES = { overview: "Overview", trades: "Trades & slippage", activity: "Activity", templates: "Templates" };

export const currentPage = () => (location.hash.slice(1) in PAGES ? location.hash.slice(1) : "overview");

function show() {
  const page = currentPage();
  document.querySelectorAll("[data-page]").forEach((el) => (el.hidden = el.dataset.page !== page));
  document.querySelectorAll("[data-nav]").forEach((el) => el.classList.toggle("active", el.dataset.nav === page));
  $("#pageTitle").textContent = PAGES[page];
}

export function initRouter() {
  window.addEventListener("hashchange", show);
  show();
}
