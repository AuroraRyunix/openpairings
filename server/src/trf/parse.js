import { read } from './lineBuilder.js';
import { PLAYER, roundBlockColumns, roundDateColumns, TEAM, teamPlayerColumns, HEADER_CODES } from './columns.js';

const HEADER_FIELD_BY_CODE = Object.fromEntries(
  Object.entries(HEADER_CODES).map(([field, code]) => [code, field])
);

function slashToIso(slashDate) {
  if (!slashDate) return '';
  const [y, m, d] = slashDate.split('/');
  if (!y || y === '0000') return '';
  return `${y}-${m ?? '00'}-${d ?? '00'}`;
}

function parsePlayerLine(line) {
  const games = [];
  for (let round = 1; ; round++) {
    const cols = roundBlockColumns(round);
    if (line.length < cols.id[0]) break;
    const idRaw = read(line, cols.id);
    const colour = read(line, cols.colour);
    const result = read(line, cols.result);
    if (!idRaw && !colour && !result) break;
    games.push({
      opponentRank: idRaw && idRaw !== '0000' ? Number(idRaw) : null,
      colour: colour === '-' || colour === '' ? null : colour,
      result: result || null,
    });
  }

  const rankRaw = read(line, PLAYER.startingRank);
  const sex = read(line, PLAYER.sex);
  const ratingRaw = read(line, PLAYER.fideRating);
  const fideNumberRaw = read(line, PLAYER.fideNumber);
  const pointsRaw = read(line, PLAYER.points);

  return {
    rank: rankRaw ? Number(rankRaw) : null,
    sex: sex ? sex.toLowerCase() : '',
    title: read(line, PLAYER.title),
    name: read(line, PLAYER.name),
    fideRating: ratingRaw ? Number(ratingRaw) : 0,
    federation: read(line, PLAYER.federation),
    fideNumber: fideNumberRaw ? Number(fideNumberRaw) : null,
    birthDate: slashToIso(read(line, PLAYER.birthDate)),
    points: pointsRaw ? Number(pointsRaw) : 0,
    games,
  };
}

function parseTeamLine(line) {
  const playerRanks = [];
  for (let slot = 1; ; slot++) {
    const cols = teamPlayerColumns(slot);
    if (line.length < cols[0]) break;
    const raw = read(line, cols);
    if (!raw) break;
    playerRanks.push(Number(raw));
  }
  return { name: read(line, TEAM.name), playerRanks };
}

function parseRoundDatesLine(line) {
  const dates = [];
  for (let round = 1; ; round++) {
    const cols = roundDateColumns(round);
    if (line.length < cols[0]) break;
    const raw = read(line, cols);
    if (!raw) break;
    const [y, m, d] = raw.split('/');
    const fullYear = y.length === 2 ? `20${y}` : y;
    dates.push(`${fullYear}-${m}-${d}`);
  }
  return dates;
}

// Inverse of serializeTrf(): returns { tournament, players, teams }.
export function parseTrf(text) {
  const lines = text.split(/\r?\n/).filter((l) => l.trim().length > 0);
  const tournament = { deputyArbiters: [] };
  const players = [];
  const teams = [];

  for (const line of lines) {
    const code = line.slice(0, 3);
    if (code === '001') {
      players.push(parsePlayerLine(line));
      continue;
    }
    if (code === '013') {
      teams.push(parseTeamLine(line));
      continue;
    }
    if (code === HEADER_CODES.roundDates) {
      tournament.roundDates = parseRoundDatesLine(line);
      continue;
    }
    const field = HEADER_FIELD_BY_CODE[code];
    if (!field) continue; // unknown/unsupported line, skip

    const value = line.slice(4).trim();
    if (field === 'deputyArbiter') {
      tournament.deputyArbiters.push(value);
    } else if (field === 'startDate' || field === 'endDate') {
      tournament[field] = value.replaceAll('/', '-');
    } else if (field === 'numberOfPlayers' || field === 'numberOfRatedPlayers' || field === 'numberOfTeams') {
      tournament[field] = Number(value) || 0;
    } else {
      tournament[field] = value;
    }
  }

  return { tournament, players, teams };
}
