-- PairingsEngine database schema
-- Designed for the full scope (individual + team events) from day one.

CREATE TABLE IF NOT EXISTS meta (
  key   TEXT PRIMARY KEY,
  value TEXT
);

CREATE TABLE IF NOT EXISTS tournaments (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  name           TEXT NOT NULL,
  -- swiss | roundrobin | team-swiss | team-roundrobin
  type           TEXT NOT NULL DEFAULT 'swiss',
  venue          TEXT NOT NULL DEFAULT '',
  city           TEXT NOT NULL DEFAULT '',
  federation     TEXT NOT NULL DEFAULT '',
  start_date     TEXT NOT NULL DEFAULT '',
  end_date       TEXT NOT NULL DEFAULT '',
  organizer      TEXT NOT NULL DEFAULT '',
  chief_arbiter  TEXT NOT NULL DEFAULT '',
  deputy_arbiter TEXT NOT NULL DEFAULT '',
  time_control   TEXT NOT NULL DEFAULT '',
  rounds_count   INTEGER NOT NULL DEFAULT 9,
  -- fide | national | none : which rating is used for pairing numbers
  rating_type    TEXT NOT NULL DEFAULT 'fide',
  points_win     REAL NOT NULL DEFAULT 1,
  points_draw    REAL NOT NULL DEFAULT 0.5,
  points_loss    REAL NOT NULL DEFAULT 0,
  -- value of a pairing-allocated bye, in points
  bye_value      REAL NOT NULL DEFAULT 1,
  -- JSON array of tiebreak codes, in priority order
  tiebreaks      TEXT NOT NULL DEFAULT '[]',
  -- none | baku
  acceleration   TEXT NOT NULL DEFAULT 'none',
  -- setup | running | finished
  status         TEXT NOT NULL DEFAULT 'setup',
  created_at     TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS teams (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  tournament_id INTEGER NOT NULL REFERENCES tournaments(id) ON DELETE CASCADE,
  name          TEXT NOT NULL,
  captain       TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS players (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  tournament_id   INTEGER NOT NULL REFERENCES tournaments(id) ON DELETE CASCADE,
  name            TEXT NOT NULL,
  sex             TEXT NOT NULL DEFAULT '',
  title           TEXT NOT NULL DEFAULT '',
  fide_id         INTEGER,
  fide_rating     INTEGER NOT NULL DEFAULT 0,
  national_id     TEXT NOT NULL DEFAULT '',
  national_rating INTEGER NOT NULL DEFAULT 0,
  federation      TEXT NOT NULL DEFAULT '',
  birth_year      INTEGER,
  club            TEXT NOT NULL DEFAULT '',
  -- active | withdrawn
  status          TEXT NOT NULL DEFAULT 'active',
  start_round     INTEGER NOT NULL DEFAULT 1,
  team_id         INTEGER REFERENCES teams(id) ON DELETE SET NULL,
  -- board order within the team (team events)
  board_order     INTEGER,
  created_at      TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_players_tournament ON players(tournament_id);

CREATE TABLE IF NOT EXISTS rounds (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  tournament_id INTEGER NOT NULL REFERENCES tournaments(id) ON DELETE CASCADE,
  number        INTEGER NOT NULL,
  date          TEXT NOT NULL DEFAULT '',
  -- pairing | playing | finished
  status        TEXT NOT NULL DEFAULT 'pairing',
  UNIQUE (tournament_id, number)
);

-- Team-vs-team encounter (team events); board games reference it.
CREATE TABLE IF NOT EXISTS matches (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  round_id   INTEGER NOT NULL REFERENCES rounds(id) ON DELETE CASCADE,
  board      INTEGER NOT NULL,
  team_a_id  INTEGER REFERENCES teams(id),
  team_b_id  INTEGER REFERENCES teams(id)
);

CREATE TABLE IF NOT EXISTS pairings (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  round_id        INTEGER NOT NULL REFERENCES rounds(id) ON DELETE CASCADE,
  board           INTEGER NOT NULL,
  white_player_id INTEGER REFERENCES players(id),
  black_player_id INTEGER REFERENCES players(id),
  -- '', '1-0', '1/2-1/2', '0-1', '+--', '--+', '0-0' (double forfeit), 'bye'
  result          TEXT NOT NULL DEFAULT '',
  match_id        INTEGER REFERENCES matches(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_pairings_round ON pairings(round_id);

CREATE TABLE IF NOT EXISTS byes (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  tournament_id INTEGER NOT NULL REFERENCES tournaments(id) ON DELETE CASCADE,
  player_id     INTEGER NOT NULL REFERENCES players(id) ON DELETE CASCADE,
  round         INTEGER NOT NULL,
  -- requested-half | requested-zero | absent | pairing-allocated
  type          TEXT NOT NULL DEFAULT 'requested-half',
  UNIQUE (player_id, round)
);

CREATE TABLE IF NOT EXISTS forbidden_pairings (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  tournament_id INTEGER NOT NULL REFERENCES tournaments(id) ON DELETE CASCADE,
  player_a_id   INTEGER NOT NULL REFERENCES players(id) ON DELETE CASCADE,
  player_b_id   INTEGER NOT NULL REFERENCES players(id) ON DELETE CASCADE
);

-- Local copy of the FIDE rating list (synced from ratings.fide.com)
CREATE TABLE IF NOT EXISTS fide_players (
  fide_id         INTEGER PRIMARY KEY,
  name            TEXT NOT NULL,
  federation      TEXT NOT NULL DEFAULT '',
  sex             TEXT NOT NULL DEFAULT '',
  title           TEXT NOT NULL DEFAULT '',
  standard_rating INTEGER,
  rapid_rating    INTEGER,
  blitz_rating    INTEGER,
  birth_year      INTEGER,
  flag            TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_fide_players_name ON fide_players(name COLLATE NOCASE);
