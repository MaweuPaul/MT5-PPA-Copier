// Delay inputs are shown in seconds (data-ms="<config key>") but stored in ms.
// Shared by the Settings and Add account forms.

const inputs = (form) => form.querySelectorAll("[data-ms]");

/** Fills every delay input of form from a config (ms values). */
export function fillDelays(form, config) {
  inputs(form).forEach((el) => (el.value = (config[el.dataset.ms] || 0) / 1000));
}

/** Reads every delay input of form as { config key: ms }. */
export function readDelays(form) {
  return Object.fromEntries([...inputs(form)].map((el) => [el.dataset.ms, Math.round(Number(el.value || 0) * 1000)]));
}

/** "2 s + 0–1 s", for listings. */
export function describeDelay(fixedMs, jitterMs) {
  if (!fixedMs && !jitterMs) return "instant";
  const s = (ms) => `${+(ms / 1000).toFixed(1)} s`;
  return jitterMs ? `${s(fixedMs)} + 0–${s(jitterMs)}` : s(fixedMs);
}
