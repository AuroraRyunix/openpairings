# Postponed games, rethought (2026-10-15)

Belgian club championships are round robins played one round a week over a
season. Games get moved. This note is about what the public standings do
when they are, why that made the results link useless on a club website,
and what changes. Branch `postponed-rethink`, both repos.

## What happens today

Two separate things decide what spectators see.

**The bound.** Public standings go through
`Tournaments.effective_standings_through/1`, which is capped by
`Tournaments.standings_through_round/1`: the longest contiguous run of rounds,
from round 1, that are published AND complete. Complete is
`Pairing.round_complete?/2`: no board has a blank result. Contiguity and
completeness are the honesty rule (publish model, rule 7): "standings after
round N" means N rounds with every result in, never a round half typed.

**The postponed game.** A board can carry `*W`, `*B` or `*`
(`Results.postponed_codes/0`): a game paired and still to be played. It is not
blank, so its round counts as complete. Until it is played it scores as the
tournament's setting says (`postponed_requester_outcome`,
`postponed_opponent_outcome`, a draw for both by default, the FIDE value),
stamped on the board when it is postponed. The standings, tie-breaks, pairing
and team matches all read that one valuation (`Standings.pairing_records/4`).
The snapshot then says `standings.provisional: true` with
`postponed_games: N`, and marks the board `postponed: true`. The results site
writes "Provisional: N postponed games are still to be played..." above the
table and an hourglass on the board. FIDE mode refuses final standings and a
TRF that holds an open game (VCL4THP Q169). A game played later in another
rating period goes in the separate postponed-games tournament
(`TrfExport.postponed_export/1`).

Postponed codes are offered only when the tournament has **Allow postponed
games** ticked (`tournaments.postponed_games`, off by default).

## The problem

1. In a round robin all rounds are paired up front, so a game that is not
   played simply stays blank. Nothing asks the arbiter about it: the Swiss
   pairing run that offers "record missing results as postponed" never runs.
2. One blank in round 3 makes round 3 incomplete. The contiguous bound stops at
   round 2 and stays there for months while rounds 4 to 9 are played. That is
   honest and useless.
3. The way out exists but it is hidden: tick a setting on the Scoring page,
   then pick "postponed by White/Black" on the board. Arbiters do not know
   about it, and the setting is off by default.
4. On the arbiter's own Standings page the same blank is worse than useless.
   It produces no game record, so the tie-breaks read the round as a
   zero-point voluntary unplayed round (Ainalrami fills a missing round with
   one). Under C.07 Article 16.4 that brings in a dummy opponent for a game
   that is going to be played.

## Options considered

**A. Leave the data alone and tell the arbiter.** Add a notice ("round 3 has
1 board without a result; the public standings stop at round 2") and make
postponing easier. That is correct and keeps the arbiter in charge, but it
fixes nothing for the arbiter who never reads the notice, and that arbiter is
the one who complained.

**B. Write `*` automatically.** When a later round finishes, record every
older blank as postponed. All the downstream machinery already exists. But it
writes a result nobody entered. VCL4THP Q159/Q160 allow recording missing
results as adjourned only behind a warning the arbiter confirms. A blank is
also often a game that was played and not typed in yet, so a `*` would be
false. It would also change what goes to FIDE: a round sent with `*` goes out
as `?`, where a round with a blank is refused for sending.

**C. Merge blank and postponed for round robins.** Every blank in a round robin
is postponed. Same objections as B, harder, and it removes the one signal
("nobody has reported on this board") that the result-entry pages and the
send check rely on.

**D. Derive it at read time (chosen).** Keep the two stored states. Add a third
state that is never stored: an **overdue** board. The standings and the
publisher read it as an unnamed postponed game. Nothing is written, so the TRF,
the send check, the pairing and the rating report see exactly what they see
today.

**E. Count pending games as nothing.** Only played games count; a pending game
adds no points and no tie-break. This was rejected as the valuation. It ranks
players by how many of their games happen to have been played. C.07 also has no
"not yet played" category: leaving the game out makes Ainalrami see a
zero-point voluntary unplayed round (problem 4), with a dummy opponent in
Buchholz.

## The design

### 1. Overdue boards (round robins)

In an individual round robin, a blank board with two players is **overdue**
when a later round is already complete (no blank board at all; postponed
boards count as filled). The function is `PostponedGames.overdue_blanks/1`.

Why "a later round is complete" and not "a later round has any result": in a
club round robin a game is often played early. If one round-7 result entered on
a Monday turned every round-6 board into an overdue game, the next spectator
would see "standings after round 6, 6 games still to be played". With a later
complete round, the blank is a game the round moved past. The cost is a lag:
an isolated blank in round 5 stops counting against the bound once round 6 is
fully in, not on the evening itself. An arbiter who wants it sooner marks the
board postponed (section 3).

Not for team events. A team round robin's match points come from
`TeamStandings`, which reads boards its own way; turning blanks there into
provisional draws would change match results, which is a bigger decision than
this note takes. Team events keep today's rule, and their postponed boards
already work.

Not for Swiss or Keizer. There, pairing the next round needs every result of
the last one, or the confirmed "record missing results as postponed" step
(Q159/Q160). A blank in an older round cannot arise in normal play, so the rule
would never fire.

### 2. What a pending game counts as

A **pending game** is an open postponed game or an overdue board. An overdue
board counts exactly as an unnamed postponed game (`*`). Nobody asked for it,
so both seats get the tournament's **for the opponent** value: a draw for both
by default, which is FIDE's value. It is computed by turning the board into a
`*` board in memory and running it through `Standings.pairing_records/4`.
There is still one result-to-points mapping. The arbiter configures it with the
existing setting on the Scoring page, and nothing new is added.

Tie-breaks follow from that. Phase 5 of `docs/design-fide-mode.md` already
argues the case for postponed games, and it applies unchanged:

- **Buchholz family** (C.07 Article 8.1, cuts and medians): the pending game is a
  played game against its scheduled opponent. The player's own Buchholz counts
  that opponent's score. The opponent's 16.3 adjusted score counts the draw. No
  dummy opponent (16.4) is brought in, because the round is not an unplayed
  round: Article 16 is for rounds nobody will play.
- **Sonneborn-Berger** (Article 8.2): half the opponent's score. This is the
  same draw the points column counts, so SB never disagrees with the score
  beside it.
- **Direct encounter, wins, games with Black and the rest**: whatever a played
  draw gives. A draw is not a win (7.1). Colour counts because the colours of a
  round-robin game are fixed by the schedule.
- **In a round robin** C.07 sends forfeits through the predetermined branch
  (Article 15.2, Ainalrami's `predetermined?`), which treats them as games.
  Valuing a pending game as a provisional played game is the same reading.

C.07 has no rule for a game still to be played. Every option invents
something. This one invents the value FIDE already uses for pairing (Q158,
Q167), keeps the score and the tie-breaks consistent with each other, and is
never final. A pending game also carries `postponed: true` on its standings
record, so norms, rating estimates and performance (`Standings.finished_game?/1`)
leave it out, as they leave out a postponed game.

These views use the option (`Standings.standings(t, pending: true)`): the
snapshot, the arbiter's Standings page and the printed standings. The TRF
exports, the SWAR/KBSB upload, the norm checks, tie lots and the
tie-break gate keep the plain computation. A file sent to FIDE must not
contain a valuation nobody entered.

### 3. Blank and postponed stay two states; postponing is always on in a round robin

They stay two states because they mean different things. Blank means "nobody
has reported on this board". Postponed means "the arbiter knows it is open".
The send check, Q159/Q160 and the result-entry pages depend on the difference.
The overdue rule (1) makes a blank harmless after a week. Making postponing
easy makes it harmless the same evening.

**Round robins always offer the postponed results**, whatever *Allow postponed
games* says (`Tournament.postponed_allowed?/1`). A round robin's schedule never
depends on scores, so the reason the setting is off by default (a provisional
score feeding a Swiss pairing) does not apply. The Scoring page shows the switch
on and locked for a round robin and keeps the valuation fields editable. The
Compliance check (a non-draw valuation leaves FIDE mode) uses the same helper,
so a round robin with a non-draw value is flagged as before.

Trade-off: an overdue board and a postponed game score the same but read
differently. The board says "result not yet in", not "postponed", because the
program does not know which of the two it is. That is the honest version of
"merge them".

### 4. The bound

`Tournaments.standings_through_round/1` keeps contiguity and keeps "published".
"Complete" becomes **settled**: every board has a result, is postponed, or is
overdue (`Tournaments.round_settled?/2`). A vacated seat with no result still
blocks: there is no game to count. The arbiter's own "Standings after round
N" control uses the same test, so they can publish what the automation would.

Honesty is kept by labelling. Standings that cover a pending game say so: with
the count, on the arbiter's page, on the print and on the results site. Each
player with one is marked ("1 pending"). Every board the count refers to is
marked. "Standings after round 6" with "2 games still to be played" is
true. "Standings after round 2" for four months was also true, but it told
spectators nothing they could use.

The round being played now does not change. Its blanks are not overdue until a
later round is complete, so while round 6 is being entered the public
standings stay at round 5. A round in progress is not pending, it is in
progress.

### 5. Swiss

Pairing time is unchanged. "Record missing results as postponed and pair round
N" stays the confirmed step (Q159/Q160). Pairing with an older open game asks
first (Q168), and the engine sees a postponed game as a draw (Q158, Q167). The
overdue rule never applies to a Swiss. The provisional labelling does: a
Swiss with a postponed game already published `provisional: true` and still
does. The pairing never reads the `pending` option, so nothing published can
change a pairing.

### 6. FIDE mode and the rating report

Nothing changes:

- **Q161/Q169.** The bound can now reach the last round while a game is
  overdue. Those standings are labelled provisional (here and on the results
  site), and the banner for missing results is still shown. The FIDE-mode
  refusal of final standings (`final_standings_refused?/2`) still keys on open
  postponed games. An overdue board is a blank as far as any file is concerned,
  and a round with a blank still cannot be sent (`PostponedGames.finalise/2`).
- **No game is rated twice.** No data is written, so a game played late is
  reported exactly as today: in its round if the round has not been sent, or
  in the postponed-games tournament ("... uitgestelde partijen") if it went out
  as `?`.

### 7. The snapshot and OpenResults

Additive keys only. Absent means today's behaviour.

- `boards[].pending: true` on an overdue board, with `result: null`. It also
  carries `points` and `postponed_as`, the same as a postponed board, so the
  results site's running totals add up to the standings beside them.
  `postponed` stays absent on it: nobody postponed it.
- `standings.pending_games: N` counts the pending games in the rounds the
  standings cover: open postponed games plus overdue boards. `provisional:
  true` is sent whenever N > 0. `postponed_games` keeps its meaning (postponed
  boards only) and is absent when there are none. An older reader that only
  knows `provisional` still says "provisional".

The results site writes one line above the standings: "Provisional: 2 games
have no result yet and count as draws until they do." The valuation phrase is
the existing one. It marks overdue boards on the round page ("Result not yet
in") and in the crosstable (the hourglass, titled the same way). Each one is
treated like a postponed board in every place the site adds points up, so it
counts as an outstanding game and not as a missing result.

## What changes for an arbiter

- In a round robin, a game nobody has entered stops freezing the public
  standings once a later round is complete. The standings show the latest
  round, say how many games are still open, and count each one as a draw (or
  as the Scoring page's postponed setting says).
- To make that happen the same evening, choose *postponed by White/Black* on
  the board. In a round robin that is always offered.
- Swiss, Keizer and team events: no change.
- Files for FIDE: no change.
