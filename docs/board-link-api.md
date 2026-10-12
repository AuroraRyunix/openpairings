# The board link: API for a hall box

What a box that reads electronic boards in the playing hall (Alnasl)
implements to work with OpenPairings: learn who sits where, and report what
the boards saw. This document is the contract. It is meant to be enough to
build the box's half without reading OpenPairings' code; where the code and
this document disagree, that is a bug in one of them, and it should be
reported rather than worked around.

Implemented by `PairingsEngineWeb.BoardLinkController` and
`PairingsEngine.BoardLink`. API version 1.

## The shape of it

```
[boards] --serial--> box (in the hall)
                      |  \
        board link    |   \  moves and clocks, relay key (push only)
   (this document)    v    v
              OpenPairings   OpenResults
```

- **The box always calls.** Plain HTTP(S) requests from the box to
  OpenPairings. OpenPairings never opens a connection to the box, so the hall
  opens no port and the box needs no address.
- **OpenPairings to the box:** the tournament, its rounds, the boards of each
  round with players and colours, the rate of play, which round is on, and
  where to send the moves on the results site.
- **The box to OpenPairings:** per game the moves, clocks, PGN, the result the
  board saw, the game's state, and how many moves the box reconstructed or
  guessed.
- **A board never enters a result.** What the box reports is stored beside the
  pairing and shown to the arbiter. The tournament's result is typed by the
  arbiter, as before. Nothing in this API can set, change or clear it.
- **The box to OpenResults** is a separate, one-way link (OpenResults'
  `docs/live-boards-api.md`). The box stops reading pairings from OpenResults:
  everything it needs for that link (`server_url`, `slug`, `relay_key`) arrives
  over this one.
- One box may hold several codes and serve several tournaments at once. Which
  table plays in which tournament is the box's own setting; OpenPairings does
  not know about tables.

## The connect code

One line of text, shown once in OpenPairings (Settings, Live boards) and as a
QR code holding exactly the same text:

```
https://pairings.example.org/api/boards/v1#oplt_Zq3...43 characters...
```

- Everything before `#` is the **API root**. Every path below is appended to
  it (`<root>/link`, `<root>/tournaments/17`).
- Everything after `#` is the **secret**: `oplt_` (a code for one tournament)
  or `oplg_` (a code for a tournament group), followed by 43 characters of
  base64url (32 random bytes). Treat the whole string after `#` as opaque.
- The secret is in the URL fragment on purpose: pasted into a browser, it is
  not sent anywhere.

Parsing: split at the first `#`; trim whitespace; the root has no trailing
slash. Reject a code without a `#` or with an empty secret.

A desktop copy of OpenPairings answers on loopback only. Its code reads
`http://127.0.0.1:<port>/api/boards/v1#...` and works only for a box program
on the same computer (see [Out of scope](#out-of-scope)). A box must not
rewrite the host.

The code can be withdrawn in OpenPairings at any time; from then on every
request with it is `401`. OpenPairings keeps only a SHA-256 of the secret and
cannot show it again, so the box must store it.

## Authentication

Every request:

```
Authorization: Bearer <secret>
```

Optional, on any request, so the arbiter can tell boxes apart on the settings
page (free text, at most 80 and 40 characters):

```
X-Board-Box: Hall A
X-Board-Box-Version: 0.4.0
```

No cookies, no session, no CSRF token. Use HTTPS whenever the root says
`https`.

## Fields nobody asked for

A field in a request body that this document does not name is **ignored**,
not refused: a newer box can talk to an older OpenPairings. The other way
round holds too - a box must ignore fields in an answer that it does not
know. Nothing unknown is stored.

## Limits

| | |
|---|---|
| requests per code | 1200 a minute; beyond it `429 rate_limited`, `Retry-After: 60` |
| refused codes per client address | 30 in 10 minutes; beyond it a wrong code gets `429` with `Retry-After: 600` instead of `401`. A valid code is never refused for somebody else's wrong ones |
| the secret | 20 to 200 bytes; anything else is `401` without being looked up |
| `game` | 1 to 64 bytes |
| `seq` | 0 to 9 007 199 254 740 991 (2^53 - 1) |
| `white_ms`, `black_ms`, each entry of `move_clocks` | 0 to 360 000 000 (a hundred hours) |
| `reconstructed`, `guessed`, `rewritten` | 0 to 2000 |
| `start_fen` | 100 bytes |
| `X-Board-Box`, `X-Board-Box-Version`; `name`, `version` of `POST /box` | 80 and 40 characters; longer is cut, not refused |
| games in one request | 64 |
| moves in one game | 1000 plies |
| one move | 2 to 10 characters from `A-Z a-z 0-9 + # = -` |
| `pgn` | 100 000 bytes |
| codes per tournament, and per group | 8 |

## Errors

Every error has the same body. Dispatch on `error`; `detail` is for a log.

```json
{ "error": "pairing_gone", "detail": "no game 5f0c... in this tournament: ..." }
```

| status | `error` | meaning |
|---|---|---|
| 401 | `unauthorized` | no code, or one that is wrong or withdrawn. Stop and ask the arbiter for a new code; do not retry in a loop |
| 404 | `tournament_not_found` | this code does not reach a tournament with that id: it never did, or the tournament was deleted, archived, handed off, taken out of the group, or the code's maker lost access. Drop the tournament; the next `GET /link` says what is left |
| 409 | `pairing_gone` | the game named in a report is not in this tournament any more (the round was paired again, the board was removed). Do not retry; fetch the tournament again |
| 409 | `pairing_changed` | the game exists, but not between the two players the report names, or with the colours the other way round. Do not retry; fetch the tournament again |
| 422 | `invalid_request` | a field missing, mistyped or out of range; `detail` names it |
| 422 | `not_a_game` | the game named is a bye or an empty board |
| 429 | `rate_limited` | wait `Retry-After` seconds |

Treat `4xx` other than `429` as "this request is wrong, do not send it again
unchanged", and `429`, `5xx` and network errors as "send the same request
again later". Every request here is safe to repeat.

## GET /link

What this code gives access to. This is the request to poll.

```json
{
  "api": 1,
  "server": { "name": "OpenPairings", "version": "0.84.0" },
  "poll_seconds": 5,
  "kind": "group",
  "group": { "name": "Summer Festival" },
  "tournaments": [
    { "id": 17, "name": "Summer Open", "label": "Open", "state": "running", "version": "3f9a0c1e5b7d2a44c610" },
    { "id": 18, "name": "Summer U12", "label": "U12", "state": "setup", "version": "a01b77e2c9d04f5566e1" }
  ]
}
```

| field | |
|---|---|
| `api` | `1`. A box that sees a number it does not know should say so and stop |
| `poll_seconds` | how often to ask. Honour it |
| `kind` | `"tournament"` or `"group"` |
| `group` | `{ "name" }` for a group code, else `null` |
| `tournaments[].id` | integer; the `:id` of the routes below |
| `tournaments[].label` | the tournament's short label inside its group, or `null` |
| `tournaments[].state` | `"setup"`, `"running"` or `"finished"`. Information only |
| `tournaments[].version` | opaque string. It changes whenever `GET /tournaments/:id` would answer differently - and that includes **every result the arbiter enters**, since the document carries it. So during a round the listing changes about once a game, and a box fetches the tournament again each time. That is intended: the document is a few kilobytes |

A tournament code lists one tournament, or none once it is deleted or
archived. A group code lists every tournament of the group that the person
who made the code may open, in the group's order. **A tournament added to the
group later appears here without a new code**; one that leaves the group, or
that the maker loses access to, disappears. An empty list is not an error.

### Polling

The response carries `ETag`. Send it back:

```
GET /link
If-None-Match: "8c1f0e..."
```

An unchanged listing answers `304` with no body. The listing changes when
the set of tournaments does or when any tournament's `version` does, so this
one request tells the box whether anything it holds is stale.

1. Every `poll_seconds`: `GET /link` with `If-None-Match`.
2. On `200`: for each tournament whose `version` differs from the one the box
   holds, `GET /tournaments/:id`. Drop tournaments that are no longer listed.
3. On `304`: nothing to do.

**Latency.** An arbiter pairs a round; the box has it within `poll_seconds`
(5 s) plus one request. A board swap or a replaced player after that reaches
the box the same way. There is no push channel; five seconds was judged
cheaper than a socket through every hall firewall.

**Cost.** A `304` costs OpenPairings a few indexed reads per tournament. It
does not build the tournament's document.

Offline, keep the last document and keep the boards running; report when the
connection is back.

## POST /box

Optional. What the box says about itself, for the settings page.

```json
{ "name": "Hall A", "version": "0.4.0", "boards": { "17": 6, "18": 4 } }
```

`boards` maps a tournament id (as a string) to the number of boards the box
has assigned to it. Counts for tournaments the code does not reach are
dropped. Send it at start and when it changes. Reply: `{"status": "ok"}`.

## GET /tournaments/:id

Everything the box needs for one tournament. `ETag` is the `version`;
`If-None-Match` gives `304`.

```json
{
  "version": "3f9a0c1e5b7d2a44c610",
  "tournament": {
    "id": 17,
    "name": "Summer Open",
    "site": "Town Hall",
    "city": "Ghent",
    "federation": "BEL",
    "start_date": "2026-07-04",
    "end_date": "2026-07-06",
    "rounds": 5,
    "state": "running",
    "team_event": false,
    "boards_per_match": null,
    "chess960": false,
    "live_boards": true,
    "display": { "rating": true, "title": true, "federation": true },
    "time_control": {
      "text": "90min/40moves+30min/end+30sec/move from move 1",
      "kind": "standard",
      "pgn": "40/5400+30:1800+30",
      "periods": [ { "moves": 40, "seconds": 5400 }, { "moves": null, "seconds": 1800 } ],
      "increment_seconds": 30,
      "increment_from_move": 1
    }
  },
  "current_round": 3,
  "players": [
    { "id": 501, "no": 1, "name": "Player One", "title": "IM", "rating": 2410, "federation": "BEL", "fide_id": 200001, "team": null },
    { "id": 502, "no": 2, "name": "Player Two", "title": null, "rating": 2195, "federation": "NED", "fide_id": null, "team": null }
  ],
  "rounds": [
    {
      "number": 3,
      "date": "2026-07-05",
      "state": "current",
      "chess960_position": null,
      "boards": [
        { "game": "9b1d6c0e4f7a4a1e8d2c5b6a7f809112", "board": 1, "label": "1", "kind": "game", "white": 501, "black": 502, "result": null }
      ]
    }
  ],
  "openresults": {
    "server_url": "https://results.example.org",
    "slug": "k3v9x2",
    "relay_key": "orrk_..."
  }
}
```

### `tournament`

| field | |
|---|---|
| `site` | the venue, or the city when no venue is set, or `null`. For the PGN `Site` tag |
| `rounds` | the number of rounds planned |
| `team_event`, `boards_per_match` | see [Team events](#team-events) |
| `chess960` | the event is Chess960; each round's `chess960_position` is then its drawn start position (0 to 959), or `null` before the draw |
| `live_boards` | the arbiter's switch that puts a Live link on the public pages. Information only: the box sends moves whether or not it is on |
| `display` | which of rating, title and federation the arbiter shows on the public pages. The box is given all three for every player; when it passes player data to a third party (a broadcast on another site) it should leave out what is `false` here |
| `time_control.text` | the rate of play as the arbiter set it, or `null` |
| `time_control.kind` | `"standard"`, `"rapid"`, `"blitz"` or `null` |
| `time_control.pgn` | the PGN `TimeControl` value, or `null` when the rate of play cannot be expressed as one. Never guess one from `text` |
| `time_control.periods`, `increment_seconds`, `increment_from_move` | the same as numbers, or all `null` when `text` could not be read. `moves: null` means "to the end of the game" |

### `current_round`

The round to have on the boards, or `null` before round 1 is paired.

OpenPairings has no "start the round" act: **a round that is paired is on.**
Which of the paired rounds, exactly:

1. Take the rounds that were paired **last, together**. A Swiss (individual
   or team) and a Keizer pair one round at a time, so that is the newest
   round. A Swiss played as two-leg matches pairs both legs at once, so it
   is the newest two. A round robin pairs every round at once, so it is all
   of them.
2. Among those, `current_round` is the lowest-numbered round that still has
   a game without a result. When none has, it is the highest of them.

So in a Swiss it is the latest paired round, whatever is still open in an
earlier one: a postponed game of round 2, or a result of round 2 cleared to
be corrected, does not make round 2 "current" again while round 3 is being
played. In a round robin it starts at round 1 and moves on when the last
result of a round is entered. A postponed game is a result (`*`), so marking
a game postponed lets a round robin move on; a game left without any result
holds it at that round.

`current_round` therefore only goes down when a round is unpaired - never
because a result was cleared - in every system but the round robin, where
clearing a result of an earlier round still brings it back to that round. A
box should not move boards that have a game under way back to an earlier
round on its own (Alnasl does not).

When `current_round` changes, the box starts that round by itself. A box may
let the arbiter override which round it shows; OpenPairings does not need to
be told.

### `players`

Every player who is seated on a board of any round below. `id` is what
`white` and `black` refer to and what a report sends back. `no` is the
pairing number. `rating` is the tournament rating (an integer, or `null` for
unrated). `team` is the team's name in a team event, else `null`.

Nothing else about a player is sent. Not the birth date, club, e-mail
address or anything typed into a registration form.

Player ids are stable while the tournament is, but **not for ever**: restoring
the tournament to an earlier point gives every player a new id. The `version`
changes when that happens, so a box that follows the polling rule never
reports with a stale id for long; if it does, it gets `pairing_changed`.

### `rounds[]`

Every paired round, in order.

| field | |
|---|---|
| `number` | the round number. It is also OpenResults' `round` |
| `date` | `YYYY-MM-DD` or `null` |
| `state` | `"current"`, `"finished"` (before the current one) or `"upcoming"` (paired, after the current one) |
| `boards` | see below, in `board` order |

### `rounds[].boards[]`

| field | |
|---|---|
| `game` | **the game's id.** A string of up to 64 characters, stable for the life of the pairing: it survives a board being renumbered and a restore point. A round paired again gets new ids. Use it as the key for everything; never key on the board number |
| `board` | the board number, unique within the round. **This is the `board` of OpenResults' live API**, with `rounds[].number` as its `round` |
| `label` | what is printed on the pairing sheet and stuck on the table. Usually the same as `board`; it differs when the arbiter gave a player a fixed table |
| `kind` | `"game"`: set a board up for it. `"forfeit"`: the arbiter entered a forfeit, nobody plays. `"bye"`: one player, no game |
| `white`, `black` | player ids; `black` is `null` for a bye |
| `result` | the **arbiter's** result as entered, or `null` until there is one. One of `1-0`, `1/2-1/2`, `0-1`, `1-0FF`, `0-1FF`, `0-0FF`, `0-0`, `1/2-0`, `0-1/2`, the `U`-suffixed unrated variants, `*`/`*W`/`*B` (postponed) and `bye`. A box may show it; it must not depend on the list being complete |
| `match` | team events only, see below |

Boards the arbiter has emptied or hidden are not listed.

### `openresults`

`null` while the tournament is not on a results site. Otherwise:

| field | |
|---|---|
| `server_url` | the results site's public address, no trailing slash. Post to `<server_url>/api/tournaments/<slug>/live` |
| `slug` | the tournament's public short name there |
| `relay_key` | the relay key to send as `Authorization: Bearer`, or `null` when the arbiter has not saved one. With `null`, do not post to the results site; keep reporting to OpenPairings |

Any of the three can change (publishing switched off, the address rotated, a
new key saved). The `version` changes with them.

## POST /tournaments/:id/games

What a board saw of one game. **The whole game every time**, like
OpenResults' ingest: that is what makes a retry safe.

```json
{
  "game": "9b1d6c0e4f7a4a1e8d2c5b6a7f809112",
  "white": 501,
  "black": 502,
  "seq": 41,
  "status": "live",
  "moves": ["e4", "e5", "Nf3", "Nc6", "Bb5"],
  "move_clocks": [5398000, 5391000, 5380000, null, 5371000],
  "white_ms": 5371000,
  "black_ms": 5340000,
  "running": "black",
  "result": null,
  "reconstructed": 0,
  "guessed": 0,
  "pgn": "[Event \"?\"] ... 1. e4 e5 2. Nf3 Nc6 3. Bb5 *"
}
```

| field | | meaning |
|---|---|---|
| `game` | required | the `game` of the board, from the tournament document |
| `white`, `black` | required | the two player ids the box believes are playing it. Checked against the pairing as it is now |
| `seq` | required, 0 to 2^53-1 | the box's own counter for this game; see below |
| `status` | default `"live"` | `"waiting"` (board set up, nothing played), `"live"`, `"finished"` |
| `moves` | default `[]` | the game so far, SAN, from the start position (or `start_fen`) |
| `move_clocks` | no | one entry per move: the mover's clock in milliseconds after the move, or `null` where unknown. If present it must have exactly as many entries as `moves` |
| `white_ms`, `black_ms` | no | each clock as it reads at the moment of this report |
| `running` | no | `"white"`, `"black"` or `"none"` |
| `result` | no | the result **the board saw**: `"1-0"`, `"1/2-1/2"`, `"0-1"`, or `null` / `"*"` for none |
| `reconstructed` | default 0 | how many of the moves the box worked out after the fact |
| `guessed` | default 0 | how many it guessed where the board was ambiguous |
| `rewritten` | default 0 | how many it first read as another move of the same piece and corrected later. A rewritten move may also be counted in one of the two above |
| `start_fen` | no | the start position, for a game that does not begin from the usual one |
| `pgn` | no | the box's own PGN of the game, stored as sent and offered to the arbiter as "the box's own PGN" |
| `replace` | no | `true`: store this report whatever `seq` is held |

A field that is left out is stored as absent: a report replaces the previous
one as a whole. Send the clocks every time.

### `seq`: which report is the newer

Per game, the box keeps a number that only grows: a persistent counter, or
the box's clock in milliseconds. OpenPairings holds the highest it has
stored.

| the report's `seq` | what happens |
|---|---|
| higher than held, or nothing held | stored. `"applied": true` |
| equal | not stored again. `"applied": false, "reason": "duplicate"` - a retry of a request that had arrived |
| lower | not stored. `"applied": false, "reason": "stale"` - a late duplicate cannot overwrite a newer state |

All three answer `200`. `"replace": true` stores the report regardless and
sets the held `seq` to the report's: for a box that was replaced or lost its
counter, on the arbiter's say-so.

Moves are compared with nothing. A report with fewer moves and a higher `seq`
replaces a longer game: that is a takeback or a correction, and the box is the
one that knows.

### What is checked

- The secret reaches the tournament (`404 tournament_not_found`).
- `game` is a game of this tournament now (`409 pairing_gone`), and is not a
  bye (`422 not_a_game`).
- `white` and `black` are its players, in those colours (`409
  pairing_changed`).
- Every field is of its type and within its limits (`422 invalid_request`).
  A move must look like a move (the character set and length above).

**Legality is not checked.** OpenPairings has no chess rules of its own; a
move is stored as sent. The box is expected to send legal, canonical SAN (as
it must for OpenResults, which does check).

A report for a game the arbiter has entered a result for, or a forfeit for,
is accepted and stored. It changes nothing about that result; if the two
disagree the arbiter sees the board's in red.

### Reply

```json
{ "status": "ok", "game": "9b1d6c0e4f7a4a1e8d2c5b6a7f809112", "applied": true, "seq": 41 }
```

`seq` is the one OpenPairings holds after the request.

### Several games in one request

```json
{ "games": [ { "game": "...", "white": 501, "black": 502, "seq": 41, "moves": ["e4"] }, { "game": "...", "..." : "..." } ] }
```

At most 64. The reply is `200` with one result per game, in order, because
one board reporting a game that is gone must not hide that the others were
stored:

```json
{ "status": "ok", "results": [
  { "status": "ok", "game": "9b1d...", "applied": true, "seq": 41 },
  { "status": "error", "game": "77aa...", "error": "pairing_gone", "detail": "..." }
] }
```

A request whose `games` is not a list, or is longer than 64, is `422
invalid_request` as a whole.

### How often

On each move, on a state change (`waiting` to `live`, the result), and on a
clock correction. Not on a timer: OpenPairings shows the arbiter a result
column and the game on request, not a running clock.

## Late changes

The arbiter can change a round after the box started it.

| what the arbiter did | what the box sees |
|---|---|
| swapped two players, or replaced one | a new `version`; the same `game` ids with other `white`/`black`. Reports with the old players are `409 pairing_changed` |
| turned the colours of a board | the same, `white` and `black` exchanged |
| unpaired the round and paired it again | a new `version`; new `game` ids. Reports for the old ids are `409 pairing_gone` |
| moved a game to another board number | a new `version`; the same `game`, another `board` / `label`. Keep the game, move its OpenResults target |
| entered a forfeit | `kind` becomes `"forfeit"` |
| restored the tournament to an earlier point | a new `version`; `game` ids as they were at that point; **new player ids** |

On `pairing_changed` or `pairing_gone`: stop sending that report, fetch
`GET /tournaments/:id`, and match the physical board to its game again. What
the box does with the moves it had recorded is its own decision (and the
arbiter's); OpenPairings will not file them under another pairing.

A game that was stored and whose pairing later disappears stays in
OpenPairings' database, is shown nowhere and is not exported. If a restore
point brings the pairing back, the game is attached again.

## Team events

`tournament.team_event` is `true` and `boards_per_match` says how many boards
a match has. Boards are numbered through the round (`board` 1 to N, as
OpenResults numbers them), and each carries its match:

```json
{ "game": "...", "board": 6, "label": "6", "kind": "game", "white": 611, "black": 640, "result": null,
  "match": { "number": 2, "board": 2, "team_a": "Team Three", "team_b": "Team Four" } }
```

| field | |
|---|---|
| `match.number` | the match's number in the round |
| `match.board` | this board's place within the match, 1 to `boards_per_match` |
| `match.team_a`, `match.team_b` | the two teams' names. Which team has White on this board is each player's `team` |

So the triple the brief calls (round, match, board) is
`(rounds[].number, match.number, match.board)`, and the game is still keyed
by `game`. A team with the bye has no boards. A board with no player on it
yet (a line-up that has not been entered) is not listed; one with a single
seat filled is listed with `kind: "bye"` until the other is.

## What OpenPairings does with a report

- Stores it per game. The arbiter's Pairings page gets a column, "Board saw",
  for a tournament that has a code or a stored game: nothing where the board
  reported nothing, "playing" for a game in progress, the board's result
  otherwise, in red when the arbiter's entered result differs. Nothing is
  blocked by it.
- Builds PGN on request (per game, per round, per tournament) with headers
  from the tournament, the moves and `move_clocks` from the report, and the
  **arbiter's** result (`*` until entered).
- Carries the games in a tournament export and in restore points. The codes
  and the relay key are in neither.
- Writes the code's first use to the tournament's audit trail, with the box's
  name and version.

## Out of scope

Said here so nobody builds against something that is not there.

- **A desktop copy and a box on another machine.** The desktop edition binds
  to loopback, and that is a safety property of having no login, not a
  default. Same-PC works. Reaching a desktop copy over the hall's LAN needs a
  decision by the owner and a separate listener that serves this API and
  nothing else; it is not built, and no setting turns it on.
- **Push.** No WebSocket, no long poll, no callback URL. Poll.
- **Entering results from a board.** By design, not by omission.
- **Legality and canonical SAN.** Not checked here.
- **A broadcast delay.** That belongs to the results site. What is reported
  here is seen by the arbiter at once.
- **Deleting a stored game through the API.** Report a newer state instead.
- **Table assignment.** Which physical board is which `game` is the box's
  business. OpenPairings has no notion of a table or a board's serial number.
- **Binding a code to one box.** A code is a bearer secret; two boxes given
  the same code both work, and the settings page then shows whichever called
  last. Make one code per box.

## Proposed, not built

Two things a box's side of this turned up, written down so they are not
found again. Neither is in the API.

- **More than one game for a pairing.** A report is one game per `game`, and
  a newer report replaces the older. A play-off of two rapid games on the
  same board, or a game begun again, has nowhere to go: the box keeps the
  earlier games to itself. A second key beside `game` (a game number within
  the pairing, default 1) would hold them; the arbiter's page would then
  list the games of a pairing and compare the result with the last.
- **A page behind the code's address.** The QR code holds
  `<root>#<secret>`, which a phone's camera offers to *open*. Opened, it is
  a `404` (the fragment is not sent, so nothing leaks). A small page at
  `<root>` that reads its own fragment in the browser and says "this is a
  connect code for a hall box: copy it" with a copy button would turn a
  dead end into the next step, without the secret ever reaching the server.

## A session, start to finish

```
box  GET  <root>/link                      Authorization: Bearer oplt_...
     200  {"kind":"tournament","tournaments":[{"id":17,"version":"3f9a..."}],"poll_seconds":5}   ETag: "8c1f..."
box  POST <root>/box                       {"name":"Hall A","version":"0.4.0","boards":{"17":6}}
     200  {"status":"ok"}
box  GET  <root>/tournaments/17
     200  {... "current_round": 2, "rounds":[...], "openresults": {...}}                          ETag: "3f9a..."

     ... every 5 s ...
box  GET  <root>/link                      If-None-Match: "8c1f..."
     304

     ... the arbiter pairs round 3 ...
box  GET  <root>/link                      If-None-Match: "8c1f..."
     200  {"tournaments":[{"id":17,"version":"b204..."}], ...}                                   ETag: "e77a..."
box  GET  <root>/tournaments/17            If-None-Match: "3f9a..."
     200  {... "current_round": 3, ...}    -> the box starts round 3

     ... a move on board 1 ...
box  POST <root>/tournaments/17/games      {"game":"9b1d...","white":501,"black":502,"seq":1,"moves":["e4"],...}
     200  {"status":"ok","game":"9b1d...","applied":true,"seq":1}
box  POST <results>/api/tournaments/k3v9x2/live   Authorization: Bearer orrk_...   {"round":3,"board":1,"moves":["e4"],...}

     ... the game ends ...
box  POST <root>/tournaments/17/games      {"game":"9b1d...","seq":63,"status":"finished","result":"1-0","moves":[...],...}
     200  {"status":"ok","game":"9b1d...","applied":true,"seq":63}
     (the arbiter sees "1-0" in the board column, and enters the result)
```
