// Column layout for the FIDE TRF16 format, per the official specification:
// https://www.fide.com/FIDE/handbook/C04Annex2_TRF16.pdf
// All positions below are 1-indexed and inclusive, exactly as printed in that PDF.

export const PLAYER = {
  code: [1, 3],          // "001"
  startingRank: [5, 8],
  sex: [10, 10],
  title: [11, 13],
  name: [15, 47],
  fideRating: [49, 52],
  federation: [54, 56],
  fideNumber: [58, 68],
  birthDate: [70, 79],
  points: [81, 84],
  rank: [86, 89],
};

// Round blocks repeat every 10 columns starting at column 92 (round 1).
// Round N: id at base, colour at base+5, result at base+7.
export function roundBlockColumns(roundNumber) {
  const base = 92 + (roundNumber - 1) * 10;
  return { id: [base, base + 3], colour: [base + 5, base + 5], result: [base + 7, base + 7] };
}

// The "132" (round dates) header line reuses the same 10-column cadence,
// but each slot holds an 8-character YY/MM/DD date instead of id/colour/result.
export function roundDateColumns(roundNumber) {
  const base = 92 + (roundNumber - 1) * 10;
  return [base, base + 7];
}

export const TEAM = {
  code: [1, 3],           // "013"
  name: [5, 36],
};

// Team player slots repeat every 5 columns starting at column 37.
export function teamPlayerColumns(slotNumber) {
  const base = 37 + (slotNumber - 1) * 5;
  return [base, base + 3];
}

export const HEADER_CODES = {
  name: '012',
  city: '022',
  federation: '032',
  startDate: '042',
  endDate: '052',
  numberOfPlayers: '062',
  numberOfRatedPlayers: '072',
  numberOfTeams: '082',
  type: '092',
  chiefArbiter: '102',
  deputyArbiter: '112',
  timeControl: '122',
  roundDates: '132',
};

export const RESULT_CODES = {
  WIN: '1',
  DRAW: '=',
  LOSS: '0',
  FORFEIT_WIN: '+',
  FORFEIT_LOSS: '-',
  WIN_UNRATED: 'W',
  DRAW_UNRATED: 'D',
  LOSS_UNRATED: 'L',
  HALF_POINT_BYE: 'H',
  FULL_POINT_BYE: 'F',
  PAIRING_ALLOCATED_BYE: 'U',
  ZERO_POINT_BYE: 'Z',
};
