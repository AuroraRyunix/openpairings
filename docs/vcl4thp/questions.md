# VCL4THP: questions for the maintainer or for FIDE

Items of FIDE's VCL4THP draft (v13) that code alone cannot settle. One entry
per item: what the item asks (paraphrased), what OpenPairings does today,
the options, and the exact question to answer. The tracker
(`docs/vcl4thp/tracker.json`) points here from each item's note.

## Q11 / Q15 - is the manual "fully functional"?

- **Asks:** a full English manual or online help (Q11). If FIDE judges it
  partial, the maker must commit to completing it within a year of the
  TAPC, which costs 5% (Q15); without that commitment it fails.
- **Today:** fifteen English chapters ship with the program and open from
  the Help link on every page (`priv/manual/`, `/help`). The publishing,
  teams and printing chapters are the briefest.
- **Options:** (a) review the manual and answer Q11 YES; (b) answer Q11 NO
  and give the Q15 commitment (5%).
- **Question:** Have you read `priv/manual/` and do you judge it complete
  enough to answer Q11 YES? If not, do you commit to completing it within
  one year of the TAPC (Q15, 5%)?

## Q37 - were the other engines' faults reported?

- **Asks:** discrepancies traced to other engines were reported to TEC or
  to their authors. NO costs 25% and opens Q38-Q39 (up to 50% more).
- **Today, on record as sent:** bbpPairings [C2] (2026-09-08 letter A.1 and
  upstream), Gacrux 5.2.4 (upstream). **Not on record:** the confirmed
  Gacrux 5.2.5 finding (seed 32007296; only an "offer it" item in
  `docs/tec-call-questions.md`) and TieBreakServer findings A-D
  (`deps/ainalrami/docs/finding-tiebreakserver-2026-09.md`).
- **Options:** send both now and keep the dated message; or answer NO.
- **Questions:** (1) Did the Gacrux 5.2.5 finding reach TEC or the Gacrux
  author (call or e-mail), and on what date? (2) Were TieBreakServer
  findings A-D sent to TEC or its author? If not, may I draft both
  messages for you to send?

## Q111 - Baku groups and round-1 byes

- **Asks:** percentage groups respect that a player with a round-1 bye has
  no TPN yet. NO costs 35%.
- **Today:** Group A is frozen at round 1 and late entrants never join it,
  but a player absent or on a bye in round 1 is numbered and counts in N
  (`pairing.ex` `baku_group_a_last`; `baku_group_a_test.exs:188-198`).
  The SPP's 2026-08-27 reading of C.04.2:2.4 says such a player has no
  TPN until arrival.
- **Options:** (a) keep counting them (35%); (b) count only players seated
  or numbered in round 1, number round-1 absentees on arrival (changes
  Group A size and TPNs in such events; goldens with a round-1 bye in a
  Baku event change).
- **Question:** Should a player who is absent or on a bye in round 1 of a
  Baku-accelerated event be left out of N and numbered only when they
  arrive, as the SPP read C.04.2:2.4?

## Q195 / Q196 - prohibited pairings after round 1

- **Asks:** prohibitions can be entered only before round 1 is paired
  (Q195 NO fails) and not after a round was played (Q196 YES fails),
  citing C.05:5.2.
- **Today:** a prohibition can be added at any time
  (`tournaments.ex add_forbidden_pairing`). Our 2026-09-08 letter (B.6)
  asked TEC to make this a Level-4 warning plus a `###` line instead;
  no answer yet.
- **Options:** (a) wait for TEC (both fail as written); (b) adding one after
  round 1 takes the tournament out of FIDE mode behind the Level-4 double
  confirmation (the gate built for Q43), stamped and written as `###` in
  TRF26 reports - in FIDE mode prohibitions are then before-round-1 only,
  which answers Q195 YES and Q196 NO; about 60 lines plus tests.
- **Questions:** (1) Should adding a prohibited pairing after round 1 leave
  FIDE mode behind the Level-4 confirmation, as in option (b), without
  waiting for TEC? (2) Should "only if possible" (soft) prohibitions count
  too, or hard ones only? (A soft one already leaves FIDE mode when it
  moves a board.)

## Q166 - unknown result codes read as "unknown"

- **Asks:** on import, any unexpected symbol in a result column (the draft's
  examples are digits that are no TRF code) is taken as a game with an
  unknown result. NO costs 10%.
- **Today:** only `?` is read as unknown (it becomes a postponed game);
  any other unrecognised code is refused by Ainalrami's parser on purpose
  (`deps/ainalrami/lib/ainalrami/trf.ex`, moduledoc): reading garbage as
  "unknown" turns a corrupt file into a plausible one, and the engine
  argued against that reading when FIDE consulted on the draft.
- **Options:** (a) keep refusing (10%); (b) in OpenPairings' import only,
  rewrite an unrecognised result code to `?` before parsing, and list each
  one on the import review step as an adjustment the arbiter confirms
  (the engine and its checker stay strict); about 40 lines plus tests.
- **Question:** For Q166, keep refusing unknown result codes (a), or accept
  them as unknown results with each one shown on the import review for
  confirmation (b)?

## Q156 - late entrants' pairing numbers: default

- **Asks:** a player entering after round 4 gets the correct TPN (the one
  their rating earns). NO costs 18%.
- **Today:** a per-tournament Swiss setting "Late entrants' pairing
  numbers" offers "By rating" (C.04.2 2.4; everyone below moves down one,
  played boards untouched, Baku's Group A follows its player) and "After
  the field" (the next free number). The default is still "After the
  field", because the bbpPairings reference expectations in
  `engine_input_test.exs` and `snapshot_test.exs`, the app-path harness and
  the TRF flow validation are built on it. The tracker answers YES because
  the program can do it; a tester using the defaults would see NO.
- **Options:** (a) keep the default (the tester must choose the setting);
  (b) make "By rating" the default for new Swiss events and regenerate those
  references; (c) also make "After the field" a FIDE-mode departure.
- **Questions:** (1) Should "By rating" be the default for new Swiss
  tournaments? (2) Should choosing "After the field" leave FIDE mode?
  (3) Should the printed pairings and standings show the tournament rating
  (the chosen method) instead of the FIDE-else-national rating?

## Q100 - manual round-robin pairing

- **Asks:** a round-robin round can be paired by hand. NO costs 7%; YES
  leads to Q101 (15% unless hand-made rounds are checked so everyone meets
  once per cycle) and Q102 (7% unless a hand-made double round robin is
  guarded against three same colours running).
- **Today:** Pair always builds the Berger schedule; starting numbers can
  be set by hand or by lot before round 1 (Q95).
- **Options:** (a) stay at NO (7%); (b) build manual round-robin pairing
  together with both checks (no penalty; a sizeable piece of work).
- **Question:** Is a manual round-robin pairing mode (with the meet-once
  and colour checks) worth building, or do we accept the 7%?

## Q179 / Q193 (and every `###` line) - in the file sent for rating?

- **Asks:** a `###` comment in the post-tournament report for a full-point
  bye (Q179) and for results that were used differently from the 001
  records (Q193); the TEC manual also logs MPA, Import and other PIBEs as
  `###` lines.
- **Today:** all `###` lines (FIDE-mode exit, Import, MPA, FPB, rating
  correction) are written in the TRF26 download and copies, never in the
  file sent for rating, which holds records only (your rule of 2026-10-03).
  The rating file does carry the corrected 001 results and the `F` byes.
- **Options:** (a) keep the rating file records-only (the tracker counts
  Q179/Q193 as met through the TRF26 report); (b) write the `###` lines into
  the file sent for rating too, if FIDE's rating server accepts comment
  lines (you confirmed it accepts TRF26).
- **Question:** Does FIDE's rating server accept `###` lines in an uploaded
  TRF26, and if so should the PIBE lines go into the file sent for rating?
