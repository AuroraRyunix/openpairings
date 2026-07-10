import test from 'node:test';
import assert from 'node:assert/strict';
import { serializeTrf, parseTrf, RESULT_CODES } from '../src/trf/index.js';

// Column numbers below are 1-indexed inclusive, straight from the FIDE spec.
// substr(line, start, end) reads inclusive [start, end] out of a 1-indexed line.
function col(line, start, end) {
  return line.slice(start - 1, end);
}

const sample = {
  tournament: {
    name: 'Test Open 2026',
    city: 'Ghent',
    federation: 'BEL',
    startDate: '2026-07-01',
    endDate: '2026-07-05',
    type: 'swiss',
    chiefArbiter: 'Jorian Burssens',
    deputyArbiters: ['Assistant One'],
    timeControl: '90+30',
    roundDates: ['2026-07-01', '2026-07-02', '2026-07-03'],
  },
  players: [
    {
      rank: 1,
      sex: 'm',
      title: 'GM',
      name: 'Carlsen, Magnus',
      fideRating: 2823,
      federation: 'NOR',
      fideNumber: 1503014,
      birthDate: '1990-11-30',
      points: 2.5,
      games: [
        { opponentRank: 2, colour: 'w', result: RESULT_CODES.WIN },
        { opponentRank: 3, colour: 'b', result: RESULT_CODES.DRAW },
        { opponentRank: null, colour: null, result: RESULT_CODES.PAIRING_ALLOCATED_BYE },
      ],
    },
    {
      rank: 2,
      sex: 'w',
      title: '',
      name: 'Vandekerckhove, Ava',
      fideRating: 1674,
      federation: 'BEL',
      fideNumber: 207918,
      birthDate: '1990-01-01',
      points: 0,
      games: [
        { opponentRank: 1, colour: 'b', result: RESULT_CODES.LOSS },
        { opponentRank: 3, colour: 'w', result: RESULT_CODES.LOSS },
        { opponentRank: 2, colour: null, result: RESULT_CODES.ZERO_POINT_BYE },
      ],
    },
  ],
};

test('header lines use the code + free-text layout', () => {
  const trf = serializeTrf(sample);
  const lines = trf.split('\r\n');
  assert.equal(lines[0], '012 Test Open 2026');
  assert.equal(lines[1], '022 Ghent');
  assert.equal(lines[2], '032 BEL');
  assert.equal(lines[3], '042 2026/07/01');
  assert.equal(lines[4], '052 2026/07/05');
});

test('player line matches the exact FIDE TRF16 column positions', () => {
  const trf = serializeTrf(sample);
  const line = trf.split('\r\n').find((l) => l.startsWith('001') && l.includes('Carlsen'));

  assert.equal(col(line, 1, 3), '001');
  assert.equal(col(line, 5, 8).trim(), '1');
  assert.equal(col(line, 10, 10), 'm');
  assert.equal(col(line, 11, 13).trim(), 'GM');
  assert.equal(col(line, 15, 47).trim(), 'Carlsen, Magnus');
  assert.equal(col(line, 49, 52).trim(), '2823');
  assert.equal(col(line, 54, 56), 'NOR');
  assert.equal(col(line, 58, 68).trim(), '1503014');
  assert.equal(col(line, 70, 79), '1990/11/30');
  assert.equal(col(line, 81, 84), ' 2.5');
  assert.equal(col(line, 86, 89).trim(), '1');

  // Round 1: opponent 2, colour w, result 1 (win)
  assert.equal(col(line, 92, 95).trim(), '2');
  assert.equal(col(line, 97, 97), 'w');
  assert.equal(col(line, 99, 99), '1');

  // Round 2: opponent 3, colour b, result = (draw)
  assert.equal(col(line, 102, 105).trim(), '3');
  assert.equal(col(line, 107, 107), 'b');
  assert.equal(col(line, 109, 109), '=');

  // Round 3: pairing-allocated bye -> opponent 0000, colour '-', result U
  assert.equal(col(line, 112, 115), '0000');
  assert.equal(col(line, 117, 117), '-');
  assert.equal(col(line, 119, 119), 'U');
});

test('round-dates (132) line places YY/MM/DD at the round-block columns', () => {
  const trf = serializeTrf(sample);
  const line = trf.split('\r\n').find((l) => l.startsWith('132'));
  assert.equal(col(line, 92, 99), '26/07/01');
  assert.equal(col(line, 102, 109), '26/07/02');
  assert.equal(col(line, 112, 119), '26/07/03');
});

test('parseTrf is the inverse of serializeTrf for header + player data', () => {
  const trf = serializeTrf(sample);
  const parsed = parseTrf(trf);

  assert.equal(parsed.tournament.name, 'Test Open 2026');
  assert.equal(parsed.tournament.city, 'Ghent');
  assert.equal(parsed.tournament.federation, 'BEL');
  assert.equal(parsed.tournament.startDate, '2026-07-01');
  assert.equal(parsed.tournament.endDate, '2026-07-05');
  assert.deepEqual(parsed.tournament.deputyArbiters, ['Assistant One']);
  assert.equal(parsed.tournament.timeControl, '90+30');
  assert.deepEqual(parsed.tournament.roundDates, ['2026-07-01', '2026-07-02', '2026-07-03']);

  assert.equal(parsed.players.length, 2);
  const magnus = parsed.players[0];
  assert.equal(magnus.rank, 1);
  assert.equal(magnus.sex, 'm');
  assert.equal(magnus.title, 'GM');
  assert.equal(magnus.name, 'Carlsen, Magnus');
  assert.equal(magnus.fideRating, 2823);
  assert.equal(magnus.federation, 'NOR');
  assert.equal(magnus.fideNumber, 1503014);
  assert.equal(magnus.birthDate, '1990-11-30');
  assert.equal(magnus.points, 2.5);
  assert.deepEqual(magnus.games, [
    { opponentRank: 2, colour: 'w', result: '1' },
    { opponentRank: 3, colour: 'b', result: '=' },
    { opponentRank: null, colour: null, result: 'U' },
  ]);
});

test('teams are serialized and parsed with correct player-slot columns', () => {
  const withTeams = {
    ...sample,
    teams: [{ name: 'KGSRL Gent', playerRanks: [1, 2] }],
  };
  const trf = serializeTrf(withTeams);
  const line = trf.split('\r\n').find((l) => l.startsWith('013'));
  assert.equal(col(line, 1, 3), '013');
  assert.equal(col(line, 5, 36).trim(), 'KGSRL Gent');
  assert.equal(col(line, 37, 40).trim(), '1');
  assert.equal(col(line, 42, 45).trim(), '2');

  const parsed = parseTrf(trf);
  assert.deepEqual(parsed.teams, [{ name: 'KGSRL Gent', playerRanks: [1, 2] }]);
});

test('a name longer than 33 characters is truncated, not overflowed into the rating field', () => {
  const longName = {
    tournament: { name: 'T' },
    players: [{ rank: 1, name: 'A'.repeat(50), points: 0, games: [] }],
  };
  const line = serializeTrf(longName).split('\r\n').find((l) => l.startsWith('001'));
  assert.equal(col(line, 15, 47), 'A'.repeat(33));
  assert.equal(col(line, 48, 48), ' ');
});
