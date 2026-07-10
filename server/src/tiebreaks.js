// Tiebreak catalogue, following the FIDE Tie-Break Regulations (C.07).
// Codes follow the abbreviations used in the regulations.
// The calculation engine (phase 3) implements each of these, including the
// unplayed-game rules; for now this drives configuration and TRF export.

export const TIEBREAKS = [
  { code: 'BH',    name: 'Buchholz',                    forTeams: false, description: 'Sum of the scores of all opponents.' },
  { code: 'BHC1',  name: 'Buchholz Cut-1',              forTeams: false, description: 'Buchholz minus the lowest-scoring opponent.' },
  { code: 'BHC2',  name: 'Buchholz Cut-2',              forTeams: false, description: 'Buchholz minus the two lowest-scoring opponents.' },
  { code: 'MBH',   name: 'Median Buchholz',             forTeams: false, description: 'Buchholz minus the highest and lowest-scoring opponents.' },
  { code: 'SB',    name: 'Sonneborn-Berger',            forTeams: false, description: 'Sum of the scores of beaten opponents plus half the scores of drawn opponents.' },
  { code: 'DE',    name: 'Direct encounter',            forTeams: true,  description: 'Result(s) of the game(s) between the tied participants.' },
  { code: 'WIN',   name: 'Number of wins',              forTeams: true,  description: 'Total number of games won (including forfeits).' },
  { code: 'WON',   name: 'Number of games won over the board', forTeams: false, description: 'Games won, excluding forfeits and byes.' },
  { code: 'BPG',   name: 'Games played with Black',     forTeams: false, description: 'Number of games played with the black pieces.' },
  { code: 'PS',    name: 'Progressive score',           forTeams: false, description: 'Sum of the running score after each round.' },
  { code: 'KS',    name: 'Koya system',                 forTeams: false, description: 'Score against opponents who scored 50% or more.' },
  { code: 'ARO',   name: 'Average rating of opponents', forTeams: false, description: 'Average rating of all opponents.' },
  { code: 'AROC1', name: 'Average rating of opponents, Cut-1', forTeams: false, description: 'ARO excluding the lowest-rated opponent.' },
  { code: 'MP',    name: 'Match points',                forTeams: true,  description: 'Team events: 2 points per match won, 1 per drawn match.' },
  { code: 'GP',    name: 'Game points',                 forTeams: true,  description: 'Team events: sum of individual board points.' },
  { code: 'BB',    name: 'Board points weighted (Berlin)', forTeams: true, description: 'Team events: board points weighted by board number (higher boards count more).' },
];

// Sensible defaults per tournament type, matching common FIDE practice.
export const FIDE_DEFAULTS = {
  'swiss':            ['BHC1', 'BH', 'SB', 'DE', 'WIN', 'PS'],
  'roundrobin':       ['DE', 'WIN', 'SB', 'KS'],
  'team-swiss':       ['MP', 'GP', 'DE', 'BB', 'SB'],
  'team-roundrobin':  ['MP', 'GP', 'DE', 'BB', 'SB'],
};
