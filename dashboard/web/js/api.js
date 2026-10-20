// All calls to the local Go server live here.

// The server rejects changes without this header (CSRF protection).
const HEADERS = { "Content-Type": "application/json", "X-Requested-With": "tradecopier" };

async function request(path, { method = "GET", body } = {}) {
  const res = await fetch(path, { method, headers: HEADERS, body: body && JSON.stringify(body) });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `${res.status} ${res.statusText}`);
  return data;
}

const followerPath = (login) => `/api/followers/${encodeURIComponent(login)}/config`;

export const getOverview = () => request("/api/overview");

export const getEvents = (login, limit = 300) =>
  request(`/api/events?limit=${limit}${login ? `&login=${encodeURIComponent(login)}` : ""}`);

export const getConfig = (login) => request(followerPath(login));

export const saveConfig = (login, config) => request(followerPath(login), { method: "PUT", body: config });

export const setPaused = (paused) => request(paused ? "/api/pause" : "/api/resume", { method: "POST" });

const templatePath = (name) => `/api/templates/${encodeURIComponent(name)}`;

export const getTemplates = () => request("/api/templates");

export const saveTemplate = (name, config) => request(templatePath(name), { method: "PUT", body: config });

export const deleteTemplate = (name) => request(templatePath(name), { method: "DELETE" });

export const getAccounts = () => request("/api/accounts");

export const addAccount = (form) => request("/api/accounts", { method: "POST", body: form });

export const getAddJob = (id) => request(`/api/accounts/jobs/${encodeURIComponent(id)}`);

export const accountAction = (login, action, { deleteFolder = false } = {}) =>
  action === "remove"
    ? request(`/api/accounts/${encodeURIComponent(login)}${deleteFolder ? "?delete_folder=1" : ""}`, { method: "DELETE" })
    : request(`/api/accounts/${encodeURIComponent(login)}/${action}`, { method: "POST" });

export const saveSetup = (setup) => request("/api/setup", { method: "PUT", body: setup });

export const startAllAccounts = () => request("/api/accounts/start-all", { method: "POST" });

export const attachAccount = (form) => request("/api/accounts/attach", { method: "POST", body: form });
