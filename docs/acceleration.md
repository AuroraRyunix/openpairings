# Accelerated pairings (Baku, FIDE C.04.7)

SWAR parity #13. `tournaments.acceleration` is `"none"` (default) or
`"baku"`, set from the Settings screen ("Baku acceleration (FIDE C.04.7)"
dropdown, `PairingsEngineWeb.SettingsLive`). It only affects the **Swiss**
pairing engine (`tournament.pairing_system == "swiss"`) - round robin has a
fixed Berger schedule and Keizer never goes through JaVaFo at all, so both
silently ignore it.

## Why this needed engine work, not just a setting

`tournaments.acceleration`, its changeset validation, the Settings dropdown,
and the IT3 form label ("Accelerated") already existed before this feature -
but nothing ever read the setting when actually building a round's pairing
input. An arbiter could turn Baku acceleration on, see it reflected on the
FIDE report, and it would have exactly zero effect on the pairings JaVaFo
produced. `PairingsEngine.Pairing.acceleration_lines/3` (and its call from
`javafo_input/2`) is the fix: it's the only place `tournament.acceleration`
now actually reaches the pairing engine.

## The verified mechanism

JaVaFo 2.2 does **not** compute Baku acceleration on its own from a single
flag. Per the JaVaFo Advanced User Manual
(`rrweb.org/javafo/aum/JaVaFo2_AUM.htm`), JaVaFo's own words:

> JaVaFo can be informed of the fictitious points that are assigned to each
> player, using the extension code XXA.

> It is mandatory to keep the full record of the fictitious points assigned
> round by round, because this record is used to determine the floaters
> history of each player.

So **we** compute every Group-A player's virtual points ourselves, straight
from FIDE C.04.7, and hand JaVaFo the full round-by-round history via one
`XXA` TRF16 extension line per Group-A player:

```
XXA NNNN pp.p pp.p ...
```

`XXA` at column 1, the player's starting rank (`NNNN`) right-aligned in
columns 5-9, then one right-aligned `pp.p` virtual-points value per round in
5-column slots starting at column 10 - a genuinely **fixed-column** format,
unlike this codebase's other free-form `XXR`/`XXP` extension lines. This was
confirmed by direct experiment against the real `priv/javafo/javafo.jar`: a
free-form space-separated `"XXA 1 1.0 1.0\r\n"` line crashes JaVaFo with a
bare `NullPointerException` (`B.A.B.D.J` / `B.A.B.I.K` / ...), while the
fixed-column form runs clean and genuinely changes the resulting pairing.
That same experiment is now the automated, `:javafo`-tagged end-to-end test
`PairingsEngine.PairingTest` - "`pair_next_round/1` pairs round 2
differently when Baku acceleration is on vs off" - the test that proves
JaVaFo actually *honours* the directive rather than silently ignoring it,
which is the exact bug this feature closes.

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

See `PairingsEngine.Pairing.acceleration_lines/3` for the implementation
and its full doc comment (same content as above, plus the exact column
math).
