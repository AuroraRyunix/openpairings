# TODO / Roadmap

Version: **0.11.1** (not 1.0 yet — the maintainer will call that explicitly).
See [`docs/features.md`](docs/features.md) for what's already shipped.

## Known gaps / deferred features

These are real, identified gaps — not yet built, and not accidentally missed:

- **Admin/support role** (`users.role`) — no staff/support role exists yet;
  every user is a plain account owner. Deferred, no target date.
- **FIDE/KBSB "last synced" banner** — smaller than it sounds:
  `PairingsEngine.Fide.Sync` / `PairingsEngine.Kbsb.Sync` are already
  singleton GenServers and `Fide.last_sync/0` already tracks a timestamp;
  only the UI banner showing it is missing.
- **Live "round paired by someone else" notice** — PubSub already refreshes
  every open page silently when a round is paired elsewhere; there's no
  visible toast/banner calling that out to the arbiter who didn't do it.
- **Team tournaments** — explicitly deferred by the maintainer as a "future
  thing." No schema, no UI.
- **American (accelerated pairing) system** — explicitly dropped, not planned
  ("no one cares" — maintainer's own call).
- **SWAR presence points on pairing-allocated byes (`SW321_PreBye`)** —
  modelled now (`tournaments.presence_on_allocated_bye`,
  `Standings.bye_points/2`); if a real club file ever surfaces where this
  models differently than expected, re-verify against it (only synthetic
  fixtures + the one real file with a coincidental match have exercised it).

## Tech debt

- **Security advisory on a transitive dep** — `mix deps.get` surfaced a
  Hex security-advisory notice during the 2026-07-25 deploy (no details
  captured at the time). Run `mix hex.audit` and address whatever it flags.
- **`docs/AGENTS.md` / this file need to stay current** — both were written
  in a single documentation pass (2026-07-25); nothing enforces they get
  updated when the code moves on. Treat any obviously stale claim in either
  as a bug, not gospel — see the note at the top of `docs/AGENTS.md`.
- **`tournaments_live.ex` / `norms_live.ex`** carry `.form-grid` (not the
  Settings pages' `.set-*` layout primitives) by design — those two pages
  are outside the Settings nav, so the inconsistency is intentional, not
  unfinished. Worth a second look only if Settings' layout system is ever
  extended app-wide on purpose.
- **Round robin's `total_rounds/2` vs. a user-set `rounds_count`** — pairing
  now clamps to whichever is lower (an explicit product decision), but the
  two numbers can still legitimately disagree in the UI if an arbiter sets
  `rounds_count` below what the Berger schedule needs. Not a bug, just worth
  remembering when reading round-count logic.

## Backlog (no particular order, nothing blocking)

- Remaining SWAR-parity items: hard pairing variants (accelerated pairing
  beyond Baku, more exotic tiebreak orderings) and printing extras beyond
  what's in `docs/printing.md`.
- Extend the automatic B.01 title-norm judgment
  (`PairingsEngine.Norms.TitleNorms`) to the documented-but-unmodelled
  exemptions: national-championship/zonal federation-mix exemptions
  (art. 1.4.3a-e), the double-round-robin titled-opponent halving
  (art. 1.4.3d), and the 7/8-game event concessions (art. 1.4.1.1-1.4.1.3).
  Currently conservative (never claims a norm the numbers don't strictly
  support), which is the safe default but under-counts in those specific
  event types.
- Standalone binaries (`docs/binaries.md`) have no automated smoke test in
  CI beyond "it builds" — nothing currently boots each target and hits `/`.

## Process notes for whoever picks this up next

- `mix precommit` (compile --warnings-as-errors, deps.unlock --unused,
  format, test) is the pre-flight check; CI runs the equivalent.
- `mix format --check-formatted` must stay green — the whole repo was
  normalized to pass it in 2026-07-25; don't let it silently regress by
  editing with a tool that reintroduces CRLF (`.gitattributes` pins source
  files to LF, but a misconfigured editor can still fight it locally).
- Never commit `Co-Authored-By`/`Generated with Claude Code` trailers to
  this repo — an explicit, standing maintainer preference.
