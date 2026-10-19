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
