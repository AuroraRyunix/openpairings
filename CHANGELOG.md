# Changelog

All notable changes to OpenPairings are documented here. Format loosely
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.12.0] — 2026-08-11

The version number sat at 0.11.1 for five weeks while the app kept
shipping — this release is everything that landed in that gap, in one
batch rather than the many small ones it should have been. Going
forward this file gets an entry every time the version bumps.

### Added

- **SWAR `.swar` v7 export** — a real, opinionated SWAR file OpenPairings
  can write from any tournament, not just import. Settings → Export /
  backup.
- **Hand-editing a paired round** — right-click any player on the
  Pairings page to swap them with someone else, mark them absent, award
  a bye, or fill an empty seat from the round's "not playing" pool. Two
  people sitting the round out can be paired straight into a new board.
- **Threshold prize categories** — a category can now be "below/above
  this Elo" or "below/above this age" instead of only a hand-picked
  name, with a one-click "Assign categories" button that fills in every
  player at once.
- **Public self-registration** — players can register themselves for a
  tournament without an arbiter account (off by default, rate-limited).
- **Mobile "enrol a phone"** — no-account result entry from a phone at
  the board, for arbiters or helpers without a login.
- **Automatic FIDE title-norm judgment (B.01)** on the Norms page.
- **TRF06 import support**, and VCL.13's asymmetric ½-0 / 0-½ result
  code across the whole pipeline.
- **Standalone single-file binaries** — no separate Elixir/Erlang
  install needed to run OpenPairings.
- **Alphabetical pairing list and printable score sheets.**
- Settings → About page: which pairing engine a tournament is using, and
  a credits line.
- 02cloud SSO (Keycloak) as an optional login method; configurable FIDE
  rating-list source URL.
- Light/dark theming and an accent-colour picker — now with 4 more accent
  colours (Indigo, Cyan, Orange, Fuchsia, 11 total) and 5 more full themes
  (Solarized Dark, Nord, Dracula, Catppuccin Mocha, Gruvbox Dark) alongside
  System/Light/Dark, 8 total. The theme switch is now a popover instead of
  an inline button row, to fit them all.
- **Tempo-aware FIDE ratings** — a player's FIDE lookup/refresh now pulls
  the Standard, Rapid, or Blitz rating matching the tournament's own
  cadence (Settings → Options → Type), falling back to Standard when the
  player has no rating in that specific list yet. The player registration
  dialog shows all three alongside "Elo used" (whichever one the pairing
  engine actually reads). Changing a tournament's Type after players are
  already registered doesn't retroactively re-fetch anyone's rating — a
  save note points arbiters to the Players page refresh instead.

### Changed

- The Players page's right-click "Absent" now has a real bulk mode (the
  Pr. column header) that touches every player at once without
  disturbing anyone's individually-set absent rounds.
- Printed player lists follow exactly the columns ticked in the Display
  panel, instead of a fixed five.
- FIDE report generation (IT3/FA1/IA1/IT4): arbiters are no longer
  capped at two, the organizer is a searchable FIDE person instead of
  free text, and arbiter/organizer e-mail became mandatory for a
  download.
- JaVaFo's pairing input for round 2 onward is built in current-
  standings order rather than fixed pairing_number order — this is what
  a real SWAR-vs-OpenPairings pairing mismatch on the same data turned
  out to be.
- The bracket-map pairing-rationale view: unpin no longer stray-scrolls
  the hover panel, plus a head-to-head duo view.
- The "updated by another arbiter" toast (already on Pairings) now also
  shows on the Players page.
- Mobile result entry: forfeit and asymmetric-disciplinary result codes
  (1-0 FF, 0-0 FF, ½-0, etc.) are now reachable from a phone, behind a
  "More…" toggle per board rather than crowding the three main buttons —
  chosen over a long-press gesture, which has no visible affordance and
  behaves inconsistently across mobile browsers.

### Fixed

- **Results entered from a phone weren't being written to the audit
  trail at all** — every other way of entering a result was, mobile was
  simply never wired up. Now logs the same `pairing.result_entered`/
  `_changed`/`_cleared` actions the desktop flow does, attributed to
  "System" (no user account exists for an enrolled phone) with the
  enrollment's own label/id recorded so an arbiter can still tell which
  phone made the change.

- **Round 2+ pairing input had no tie-break for players equal on both
  score and rating** — JaVaFo's Dutch-system engine falls back to input
  order when a bracket has more than one structurally-equal pairing, and
  that fallback order was effectively arbitrary (unordered map
  enumeration), not a real rule. Found via the same real SWAR-vs-
  OpenPairings comparison above; fixed by adding `pairing_number` (FIDE
  Art. 1.14's starting-rank fallback) as the third sort key.
- **`SW321_PreBye` presence points** on pairing-allocated byes were not
  modeled at all — a real scoring gap for clubs running SWAR's 3-2-1
  point scale.
- **FIDE C.07's Cut-1 Exception** (Art. 16.5.1) was missing, and a
  trailing pairing-allocated bye was scored as a draw instead of a bye.
- **Article 16.4** unplayed-round tiebreak scoring (Buchholz / BHC1 /
  Sonneborn-Berger) was wrong for a specific unplayed-round shape.
- **SWAR `AbsValue` mapping** was backwards — a checked "pay ½ point for
  absence" box imported as 0 points, not 0.5.
- SWAR handicap-table boards were misplacing pairings in board order.
- The registration form's FIDE-id dropdown could silently fail to
  appear at all.

### Security

- Content-Security-Policy with a per-response nonce.
- Rate-limiting keyed on the real client IP; throttled magic-link sends
  and registration-form submissions.
- Mobile enrollment codes moved to a CSPRNG, 8 digits over one global
  space instead of per-tournament.
- Closed an `/invites` link enumeration issue; tournament owners can now
  disable or rotate a public link.
- Bumped `bandit` for a HIGH-severity WebSocket DoS advisory.

---

Versions before 0.11.1 are not itemized here — see the git history.
