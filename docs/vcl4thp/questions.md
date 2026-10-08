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
