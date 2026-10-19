// Lot maths mirrored from the EA (CopierFollower NormalizeLots), assuming the
// common 0.01 lot step. Used for the settings preview so a typo like 0.05
// instead of 0.5 is obvious before saving.

export const MIN_MULTIPLIER = 0.01;
export const MAX_MULTIPLIER = 100;
const STEP = 0.01;

const floorToStep = (v) => Math.floor(v / STEP + 1e-7) * STEP;

/** Follower lots for a master trade, or 0 if the copy would be skipped. */
export function copyLots(masterLots, { multiplier, max_lot, round_up_min }) {
  let v = floorToStep(masterLots * multiplier);
  if (max_lot > 0 && v > max_lot) v = floorToStep(max_lot);
  if (v < STEP) return round_up_min ? STEP : 0;
  return v;
}

export const validMultiplier = (m) => m >= MIN_MULTIPLIER && m <= MAX_MULTIPLIER;
