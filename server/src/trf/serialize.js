import { newLine, place, render } from './lineBuilder.js';
import { PLAYER, roundBlockColumns, roundDateColumns, TEAM, teamPlayerColumns, HEADER_CODES } from './columns.js';

function headerLine(code, value) {
  return `${code} ${value ?? ''}`.replace(/\s+$/, '');
}

// yyyy-mm-dd (as produced by <input type="date">) -> yyyy/mm/dd
function slashDate(isoDate) {
  return isoDate ? isoDate.replaceAll('-', '/') : '';
}

// yyyy-mm-dd -> yy/mm/dd, as required specifically for the "132" round-dates line.
function shortSlashDate(isoDate) {
  if (!isoDate) return '';
  const [y, m, d] = isoDate.split('-');
  return `${y.slice(-2)}/${m}/${d}`;
}

const TYPE_LABELS = {
  'swiss': 'Individual: Swiss System',
  'roundrobin': 'Individual: Round Robin System',
  'team-swiss': 'Team: Swiss System',
  'team-roundrobin': 'Team: Round Robin System',
};

function playerLine(p) {
  const chars = newLine();
  place(chars, PLAYER.code, '001');
  place(chars, PLAYER.startingRank, String(p.rank), { align: 'right' });
  place(chars, PLAYER.sex, p.sex === 'w' || p.sex === 'W' || p.sex === 'F' ? 'w' : (p.sex ? 'm' : ''));
  place(chars, PLAYER.title, p.title ?? '');
  place(chars, PLAYER.name, p.name ?? '');
  place(chars, PLAYER.fideRating, p.fideRating ? String(p.fideRating) : '', { align: 'right' });
  place(chars, PLAYER.federation, p.federation ?? '');
  place(chars, PLAYER.fideNumber, p.fideNumber ? String(p.fideNumber) : '', { align: 'right' });
  place(chars, PLAYER.birthDate, p.birthDate ? slashDate(p.birthDate) : '');
  place(chars, PLAYER.points, (p.points ?? 0).toFixed(1), { align: 'right' });
  place(chars, PLAYER.rank, String(p.rank ?? ''), { align: 'right' });

  const games = p.games ?? [];
  games.forEach((g, i) => {
    const cols = roundBlockColumns(i + 1);
    place(chars, cols.id, g.opponentRank ? String(g.opponentRank) : '0000', { align: 'right' });
    place(chars, cols.colour, g.colour ?? '-');
    place(chars, cols.result, g.result ?? '');
  });

  return render(chars);
}

function teamLine(t) {
  const chars = newLine();
  place(chars, TEAM.code, '013');
  place(chars, TEAM.name, t.name ?? '');
  (t.playerRanks ?? []).forEach((rank, i) => {
    place(chars, teamPlayerColumns(i + 1), String(rank), { align: 'right' });
  });
  return render(chars);
}

// tournament: { name, city, federation, startDate, endDate, numberOfPlayers,
//   numberOfRatedPlayers, numberOfTeams, type, chiefArbiter, deputyArbiters,
//   timeControl, roundDates }
// players: [{ rank, sex, title, name, fideRating, federation, fideNumber,
//   birthDate, points, games: [{ opponentRank, colour, result }] }]
// teams: [{ name, playerRanks }]
export function serializeTrf({ tournament, players, teams = [] }) {
  const lines = [];
  const t = tournament;

  if (t.name) lines.push(headerLine(HEADER_CODES.name, t.name));
  if (t.city) lines.push(headerLine(HEADER_CODES.city, t.city));
  if (t.federation) lines.push(headerLine(HEADER_CODES.federation, t.federation));
  if (t.startDate) lines.push(headerLine(HEADER_CODES.startDate, slashDate(t.startDate)));
  if (t.endDate) lines.push(headerLine(HEADER_CODES.endDate, slashDate(t.endDate)));
  lines.push(headerLine(HEADER_CODES.numberOfPlayers, players.length));
  if (t.numberOfRatedPlayers !== undefined) {
    lines.push(headerLine(HEADER_CODES.numberOfRatedPlayers, t.numberOfRatedPlayers));
  }
  if (teams.length) lines.push(headerLine(HEADER_CODES.numberOfTeams, teams.length));
  if (t.type) lines.push(headerLine(HEADER_CODES.type, TYPE_LABELS[t.type] ?? t.type));
  if (t.chiefArbiter) lines.push(headerLine(HEADER_CODES.chiefArbiter, t.chiefArbiter));
  for (const arbiter of t.deputyArbiters ?? []) {
    lines.push(headerLine(HEADER_CODES.deputyArbiter, arbiter));
  }
  if (t.timeControl) lines.push(headerLine(HEADER_CODES.timeControl, t.timeControl));

  if (t.roundDates?.length) {
    const chars = newLine();
    place(chars, [1, 3], HEADER_CODES.roundDates);
    t.roundDates.forEach((date, i) => {
      place(chars, roundDateColumns(i + 1), shortSlashDate(date));
    });
    lines.push(render(chars));
  }

  for (const p of players) lines.push(playerLine(p));
  for (const team of teams) lines.push(teamLine(team));

  // Per the spec, every line ends in a carriage return.
  return lines.join('\r\n') + '\r\n';
}
