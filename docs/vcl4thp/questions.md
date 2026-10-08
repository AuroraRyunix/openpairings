# VCL4THP: questions for the maintainer or for FIDE

Items of FIDE's VCL4THP draft (v13) that code alone cannot settle. One entry
per item: what the item asks (paraphrased), what OpenPairings does today,
the options, and the exact question to answer. The tracker
(`docs/vcl4thp/tracker.json`) points here from each item's note.

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
