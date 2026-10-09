# Accelerated pairings (Baku, FIDE C.04.7)

SWAR parity #13. `tournaments.acceleration` is `"none"` (default) or
`"baku"`, set from the Settings screen ("Baku acceleration (FIDE C.04.7)"
dropdown, `PairingsEngineWeb.SettingsLive`). It only affects the **Swiss**
pairing engine (`tournament.pairing_system == "swiss"`) - round robin has a
fixed Berger schedule and Keizer never reaches the engine at all, so both
silently ignore it.

## Why this needed engine work, not just a setting

`tournaments.acceleration`, its changeset validation, the Settings dropdown,
and the IT3 form label ("Accelerated") already existed before this feature -
but nothing ever read the setting when actually building a round's pairing
input. An arbiter could turn Baku acceleration on, see it reflected on the
FIDE report, and it would have exactly zero effect on the pairings the engine
produced. `PairingsEngine.Pairing.accelerations/3` (and its call from
`trf_input/5`) is the fix: it's the only place `tournament.acceleration`
now actually reaches the pairing engine.

## The verified mechanism

The engine does **not** compute Baku acceleration on its own from a single
flag. Acceleration reaches a Dutch engine as fictitious points, using the
TRF extension code `XXA` (the mechanism JaVaFo's Advanced User Manual
documents, and which Ainalrami reads). The full round-by-round record
is mandatory, because it is used to determine each player's floater
history.

So **we** compute every Group-A player's virtual points ourselves, straight
from FIDE C.04.7, and hand the engine the full round-by-round history via one
`XXA` TRF16 extension line per Group-A player:

```
XXA NNNN pp.p pp.p ...
```

`XXA` at column 1, the player's starting rank (`NNNN`) right-aligned in
columns 5-9, then one right-aligned `pp.p` virtual-points value per round in
5-column slots starting at column 10 - a genuinely **fixed-column** format,
unlike this codebase's other free-form `XXR`/`XXP` extension lines. (This was
verified against JaVaFo when it was still part of the app: a free-form
`"XXA 1 1.0 1.0"` line crashed it, while the fixed-column form ran clean.)
The test `PairingsEngine.PairingTest` - "`pair_next_round/1` pairs round 2
differently when Baku acceleration is on vs off" - proves the engine
actually *honours* the directive rather than silently ignoring it, which is
the exact bug this feature closes.

## FIDE C.04.7, as implemented

* **Group A** - the group that receives virtual points - is the top half of
  the field by starting rank (`pairing_number`), rounded up to the nearest
  even number of players: `2 * ceil(player_count / 4)`. Computed once from
  the whole roster (starting rank is frozen for the tournament, never
  round-specific). Group B never receives points.
* **Accelerated rounds** are the first `ceil(rounds_count / 2)` rounds.
  Within those, Group A gets **1.0** virtual point per round for the first
  half (rounded up) of that span, then **0.5** for the remainder, then
  **0** forever after. This is FIDE's own worked example, reproduced
  verbatim by `PairingsEngine.PairingTest`:

  > In a nine-round tournament, the accelerated rounds are five. The
  > players in GA are assigned one virtual point in the first three rounds,
  > and half virtual point in the next two rounds.

* **Order inside a score group.** The rows handed to the engine are numbered
  in pairing order, and the engine takes a row's number as its rank inside
  a score group (C.04.3 A.2: score, then pairing number). So the rows are
  sorted by game points **plus the round's virtual points**
  (`order_for_pairing/4`), not by game points alone. Until 2026-10-02 they
  were sorted by game points, which ranked a Group-B player above a
  Group-A player on the same pairing score whenever the Group-B player had
  more game points; `PairingsEngine.BakuOrderTest` is the smallest
  tournament that shows it, and `PairingsEngine.BakuReferenceTest`
  compares random Baku tournaments with bbpPairings and Ainalrami on a
  file numbered by pairing number.

See `PairingsEngine.Pairing.accelerations/3` for the implementation and its
full doc comment. It returns each Group-A player's virtual-point history
and `Ainalrami.Trf.serialize/2` writes the `XXA` lines from it - the column
math lives with the writer, in that module's `@xxa_rank_cols` and
`xxa_points_cols/1`.

## The other acceleration: extra points

SWAR accelerates differently - by the players' own extra points (its
XtraPoints), assigned from rating bands and taken off by hand part-way.
That is extra points in acceleration mode here (`docs/extra-points.md`),
and it rides the same `XXA` channel with a recorded per-round history. The
two are never combined: the changeset refuses Baku while a tournament's
extra points feed the pairing, and `accelerations/3` gives Baku precedence
for a row that holds both anyway.
