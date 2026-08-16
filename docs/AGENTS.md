# AGENTS.md — deep technical context for AI coding agents

This is project-specific, deep technical documentation for an AI agent
working on OpenPairings' actual domain logic. It is **not** the generic
Phoenix/Elixir framework usage rules — those live in the root
[`AGENTS.md`](../AGENTS.md) (auto-generated boilerplate about `phx.gen.auth`,
LiveView conventions, Tailwind syntax, etc.) and are unrelated to this file.

This file was written in one pass on 2026-07-25 from direct knowledge of the
codebase at that point. It is not auto-generated and nothing keeps it in sync
with later changes — if a claim here contradicts the actual code, **trust the
code** and treat this file as stale on that specific point (see `TODO.md`).

## What this app is

A web-based chess tournament manager: FIDE Swiss pairing (via the external
JaVaFo engine), round robin (Berger), the Keizer system, FIDE tiebreaks
(C.07), result entry, live standings, printing, TRF16/SWAR import-export,
FIDE/KBSB rating-list sync, automatic FIDE title-norm judgment (B.01), and
no-account mobile result entry. Single-user-owned tournaments with optional
per-tournament collaborator sharing.

## Stack & why

- **Elixir/Phoenix/LiveView**, not a JSON API + SPA. Pages are
  server-rendered and update live over a WebSocket via Phoenix PubSub — there
  is no separate frontend build, no React/Vue, no client-side state
  management. If you're used to "backend API + frontend app" architectures,
  recalibrate: a LiveView module *is* both the controller and the view.
- **SQLite**, not Postgres — chosen so the whole app is one file plus one
  process, deployable to a small VPS or as a standalone binary with zero
  external service dependencies. This has real consequences (see "SQLite
  concurrency" below) that don't exist in a Postgres-backed Phoenix app.
- **JaVaFo** (a real, external, FIDE-endorsed Java program) does the actual
  Swiss pairing math. This app's job for Swiss is building a correct TRF16
  input file, shelling out to `java -jar javafo.jar`, and parsing the output
  — **not** reimplementing the Dutch pairing algorithm. A tournament may
  opt into a second engine (`tournaments.pairing_engine == "openpair"`, the
  sibling pure-Elixir Dutch engine, beta) which is handed the byte-identical
  TRF; JaVaFo remains the default and the only engine permitted on a
  FIDE-homologated tournament. See `docs/pairing-systems.md`.
- **Burrito** wraps a release into a single self-contained executable
  (bundles the BEAM runtime itself) for zero-dependency distribution.

## Entry points

- `lib/pairings_engine/application.ex` — the supervision tree. Notable
  children beyond the standard Phoenix set: `Fide.Sync` and `Kbsb.Sync`
  (singleton GenServers holding rating-list sync state), `Tools.Session`
  (in-memory, no-DB store backing the public `/tools/norms` page),
  `RateLimit`.
- `lib/pairings_engine_web/router.ex` — six route groups, each its own
  `live_session` (LiveView on_mount hooks don't cross `live_session`
  boundaries, so know which one a page is in before touching auth logic):
  1. `:require_authenticated_tournaments` — the whole tournament-management
     UI (players, pairings, standings, settings, norms, print). Requires
     login.
  2. `:require_authenticated_user` — account settings.
  3. `:current_user` — register/login/confirm (works logged out OR in).
  4. `:public_tournament_pages` — `/p/:slug/...`, read-only, no login,
     reachable only via a tournament's unguessable `public_slug` (never its
     numeric id).
  5. `:tools` — `/tools/norms`, public, no login, no database at all (see
     `Tools.Session` below).
  6. `:mobile_results` (scope `/m`) — no-account phone result entry via a
     QR/short-code enrollment token, its own `MobileAuth.require_enrollment`
     on_mount, deliberately scoped to result-entry-only.
- `mix phx.server` (dev) / a release's `bin/pairings_engine start` / a
  Burrito binary's `start` subcommand all boot the same `Application.start/2`.

## Directory map (the parts that aren't self-explanatory)

- `lib/pairings_engine/pairing.ex` — the Swiss/JaVaFo pipeline: builds TRF
  text, shells to `java`, parses pairs, writes the `Round`/`Pairing` rows.
  This is the hottest, most-audited file in the codebase — read its module
  doc and the "Invariants" section below before touching it.
- `lib/pairings_engine/round_robin.ex` — Berger schedule, pure functions of
  frozen pairing numbers + round number; no JaVaFo involved.
- `lib/pairings_engine/keizer.ex` — the ladder system: fixed-point
  convergence, retroactive recalculation, its own pairing algorithm (not
  JaVaFo).
- `lib/pairings_engine/standings.ex` — FIDE C.07 tiebreaks (Buchholz,
  Sonneborn-Berger, DE, etc.), Article 16 unplayed-round handling.
- `lib/pairings_engine/trf.ex` / `trf_export.ex` / `trf_import.ex` — TRF16
  serialize/parse/validate; `trf.ex` is the single shared serializer both
  JaVaFo input and the user-facing TRF export go through.
- `lib/pairings_engine/swar_import.ex` — binary parser for SWAR's
  proprietary `.swar` format (sequential, no index — every field must be read
  in exact order; see its moduledoc for section layout).
- `lib/pairings_engine/norms/` — `xlsx_fill.ex` (generic in-place `.xlsx`
  cell surgery via `:zip` + regex, no dependency on any specific form),
  `forms.ex` (the actual IT3/FA1/IA1/IT4 field mappers), `title_norms.ex`
  (automatic B.01 norm judgment), `combine.ex` (multi-tournament "festival"
  reports).
- `lib/pairings_engine/tools/` — the public, database-free `/tools/norms`
  page's own session store and file parsing.
- `lib/pairings_engine/mobile.ex` + `mobile/` — no-account phone enrollment
  for result entry (QR/code, TTL, revocation).
- `lib/pairings_engine/fide.ex` / `fide/sync.ex`, `kbsb.ex` / `kbsb/` — rating
  list ingestion (FIDE: HTTP download + unzip; KBSB: file upload — no stable
  public bulk download exists for Belgian ratings).
- `lib/pairings_engine_web/live/` — one LiveView module per top-bar tab.
  Every tournament-scoped LiveView subscribes to `"tournament:#{id}"` on
  mount and reloads on any write elsewhere (see "Live-refresh model" below).
- `priv/norm_templates/` — the actual official FIDE `.xlsx` files, edited
  in place at report-generation time. Never regenerate these from scratch;
  `xlsx_fill.ex` only ever patches cells inside the existing zip.

## Data model essentials

- `Tournament` — one row per tournament, owned by a `user_id`. Holds pairing
  system choice (`pairing_system`: swiss/round_robin/keizer — **locked after
  the first round is paired**, no schema-level enforcement beyond the UI
  hiding the control), scoring config (`points_win`/`points_draw`/
  `points_loss`/`bye_value`/`presence_value`/`abs_value`/
  `presence_on_allocated_bye` — the last four exist only for SWAR-imported
  club-configured scoring), tiebreak list, acceleration mode, `officials`
  (a free-form map feeding the FIDE report forms), `public_slug` (unguessable
  token for public pages), `manual_ranking`/`manual_ranking_stale` (arbiter
  hand-set standings override).
- `Player` — `pairing_number` is **frozen forever once assigned** (at first
  pairing) — never reassigned, never recycled, even if the player later
  becomes `absent`/`forfeit`/`status: "withdrawn"`. A hard-deleted player
  (rare) is the *only* legitimate gap in the pairing-number sequence.
- `Round` / `Pairing` — one `Round` per round number; `Pairing.result` is a
  small fixed vocabulary (`"1-0"`, `"1/2-1/2"`, `"0-1"`, `"1-0FF"`/`"0-1FF"`/
  `"0-0FF"` forfeits, `"0-0"` played-both-lose, `"bye"`, `"+--"`/`"--+"`
  legacy SWAR/TRF forfeit notation, or `""` unset). `Trf.serialize/1` raises
  `Trf.ValidationError` on illegal combinations (both sides "win", etc.) —
  this is intentional; don't broaden the accepted vocabulary without
  updating every consumer that pattern-matches on it (`standings.ex`,
  `player_card.ex`, `pairing.ex`'s `trf_game/3`, `pgn_export.ex`).
- `byes` — a schemaless table (`Repo.insert_all("byes", ...)`, no Ecto
  schema module), `type` one of `"requested-half"` / `"requested-zero"` /
  `"absent"` / `"pairing-allocated"`. Has a `unique_index(:player_id, :round)`
  but **no `round_id` foreign key** — deleting a `Round` does NOT cascade to
  its bye rows; `Pairing.delete_round/2` explicitly deletes them too. If you
  add a new code path that deletes rounds, it must delete matching bye rows
  itself or you'll hit that unique index on re-pair.
- `forbidden_pairings` — order-insensitive pairs (`{a,b}` == `{b,a}`),
  enforced by storage normalization (`player_a_id` is always the smaller id)
  plus a real DB unique index on `(tournament_id, player_a_id, player_b_id)`
  — not just an application-level check.
- `Standings.standings/1` never trusts a `points`/`total` column on the
  player row for tiebreak-affecting numbers; it **replays every pairing/bye
  from scratch** every time it's called. This is deliberate (SWAR/TRF import
  data is trusted for game history, never for pre-computed totals) — don't
  "optimize" by caching a computed total on `Player`.

## The Swiss/JaVaFo pipeline in detail

This is the single most delicate part of the codebase. Read
`Pairing`'s moduledoc and `do_pair_single/4`'s doc comment before changing
anything here.

1. **Full roster, not just this round's eligible players, feeds the TRF.**
   `full_roster_players/1` returns every player who ever held a
   `pairing_number`, regardless of current active/absent/forfeit/withdrawn
   status. Every one of them gets a local contiguous rank AND a row in the
   TRF sent to JaVaFo. Players not actually eligible to be paired this round
   get an explicit `0000 - Z` line (`mark_ineligible_for_round/2`) instead of
   being omitted entirely.
   - **Why this matters**: JaVaFo crashes with a bare `NullPointerException`
     if starting ranks aren't contiguous 1..N — that's the *original* reason
     a remap existed. But the deeper reason full-roster inclusion is
     mandatory: if a past opponent is dropped from the TRF, the remap step
     (`remap_trf_rows_to_local_ranks/2`) can't resolve their rank and
     rewrites that opponent's real, *already-played* game into a synthetic
     bye code — silently destroying that game's colour for JaVaFo's
     alternation calculation. This was a real, shipped bug (a withdrawn
     player's opponent could get the same colour twice in a row) fixed by
     switching to full-roster scoping. Do not re-narrow this to "just the
     eligible subset" for any reason without re-reading that history.
2. **The scratch TRF/output files are written to a randomized, 0700,
   per-run directory** (`workdir!/0`) and **deleted the instant that run
   finishes** (`File.rm_rf(dir)` in an `after` block) — a shared-`/tmp`
   symlink/predictable-path hardening. If you need to observe the generated
   TRF text for a test, don't try to read it off disk after the call
   returns — it's already gone. `Pairing` fires a
   `[:pairings_engine, :pairing, :trf_built]` `:telemetry` event with the
   exact TRF text right before it's written, purely for test observability
   (nothing in the app itself subscribes to it) — attach to that instead.
3. **`javafo_input/4`'s 4th arg (`eligible_ids`)** is what actually decides
   who's a pairing candidate this round vs. who gets the `0000 - Z`
   ineligible marker. It defaults to `nil` (skip the marking step entirely)
   so every other caller — TRF export, tests calling with fewer args — is
   unaffected.
4. **Baku acceleration** (`acceleration_lines/4`) computes Group A (the
   virtual-points recipients) from the SAME full roster the rest of the
   pipeline now uses — this is deliberate and fixes a related bug where
   Group A membership used to shift round-to-round based on who happened to
   be eligible that specific round, violating the FIDE rule that Group A is
   fixed once at tournament start. JaVaFo does **not** compute acceleration
   from a flag on its own — see the doc comment above `acceleration_lines/4`
   for the verified-against-the-real-jar mechanism (`XXA` fixed-column
   extension lines, one virtual-points-per-round history per Group-A
   player).
5. **`swiss_match_format`** (two-leg matches, colours reversed on leg 2) is
   inserted as one unit by `create_round/5` → `create_mirrored_leg/4` — no
   second JaVaFo call. `delete_round/2` deletes **both legs together** under
   match format, or the invariant that `paired_rounds_count` always lands on
   an even number after a match-format run breaks, stranding the tournament
   against `max_pairable_round/1`.
6. **`pair_by_category` and `swiss_match_format` are mutually exclusive**
   (rejected at the changeset level) — the category path never mirrors a
   second leg. Same for `pair_by_category` + Baku acceleration.
7. **The engine is chosen at exactly one seam** — `run_engine/5`, which
   takes the finished TRF text and returns `{:ok, [{white, black}]}` (`0`
   for the pairing-allocated bye) or `{:error, message}`. Both Swiss paths
   (`do_pair_single/4` and the per-category one) funnel through it, so
   neither can drift from the other and a third engine would be added in
   one place. OpenPair reads only the TRF's `XXR` extension, so a round
   whose TRF would carry `XXP` (forbidden pairings / exclusions) is refused
   there outright rather than paired with the rule silently dropped.
8. **Round robin and Keizer never send anything to JaVaFo.** Round robin is
   a pure function of frozen pairing numbers (Berger tables, computed once
   at `ensure_frozen/1`); Keizer runs its own backtracking matcher. Neither
   is affected by anything in this section.

## 02cloud SSO, and the registration blocklist that goes with it

Added 2026-07-25. Three moving parts, deliberately split so the policy lives in
the schema rather than in a controller:

- `PairingsEngine.Keycloak` — a deliberately minimal OIDC client for exactly
  one provider (`auth.zerotwo.cloud`, realm `zerotwo`). The three endpoints are
  derived from the issuer by Keycloak's documented URL scheme rather than
  fetched from `.well-known/openid-configuration` (verified against the live
  realm: the advertised endpoints match the derived ones exactly). It is a
  **confidential** client, so there is no PKCE — PKCE protects a public
  client's code on the user's own device, whereas here the code is redeemed
  server-to-server with a client secret, which is the real boundary.
- `PairingsEngineWeb.KeycloakAuthController` — `/auth/keycloak` (redirect out)
  and `/auth/keycloak/callback` (verify `state`, exchange code, fetch userinfo,
  log in). A plain controller, not a LiveView: it only ever redirects, so there
  is nothing to keep alive over a socket. Its `with` has a catch-all `else`
  precisely so a userinfo response missing `sub`/`email` degrades to a flash
  rather than a 500.
- `Accounts.find_or_create_from_keycloak/1` — resolves **by `keycloak_sub`
  first, email second**. `sub` is the only stable key; an email can be renamed
  on either side. Matching on email second is what "couples" a pre-existing
  password/magic-link account to an SSO identity instead of creating a
  confusing duplicate.

**The invariant that ties it together:** `User.email_changeset/3` rejects
`@zerotwo.cloud` addresses (`validate_not_sso_domain/1`), so they cannot be
created by self-serve registration *or* by a settings-page email change —
otherwise someone could take a local password account on a domain they don't
control in the directory. `User.keycloak_changeset/2` deliberately does **not**
run that check, because SSO is the very on-ramp the blocklist redirects people
to. If you ever add a third way to write `users.email`, decide explicitly which
of those two changesets it belongs behind; a `cast` that bypasses both
reopens the hole.

Two consequences worth knowing before they surprise you:

- SSO-created accounts are **pre-confirmed** (`confirmed_at` set in
  `keycloak_changeset/2`) — Keycloak/AD already verified the identity, so
  routing them through magic-link confirmation would be theatre.
- The blocklist only guards *new* `@zerotwo.cloud` addresses. Accounts that
  already have one (pre-dating the rule, or coupled via SSO) keep logging in
  normally, including by password if they have one.

Configuration is optional everywhere: with no client id/secret,
`Keycloak.configured?/0` is false, the login button isn't rendered, and the
routes flash instead of crashing. Tests stub the HTTP calls with `Req.Test`
via `config :pairings_engine, :keycloak_req_plug` (see `config/test.exs`) —
`Keycloak.request/3` only injects that plug when the setting is present, so
production is untouched.

## FIDE norm judgment (`Norms.TitleNorms`)

Implements FIDE Title Regulations B.01 (verified against
handbook.fide.com, transcribed dp table checked for antisymmetry in tests).
Deliberately **conservative**: several real-world exemptions (national
championship/zonal federation-mix exemptions, double-round-robin halving,
7/8-game event concessions) aren't auto-detected, so it can under-count a
norm the arbiter knows is actually valid — it will never falsely claim one
the numbers don't support. It converts a tournament's own (possibly
club-configured) scoring back to the standard 1/½/0 scale before any
percentage math — never assume `points_win == 1.0`.

## FIDE report generation (`Norms.XlsxFill`)

Edits the real FIDE `.xlsx` templates in place by regex-surgery on the
zip's XML members — never regenerates a workbook from scratch (would lose
FIDE's exact formatting/formulas/validation). Two non-obvious traps already
hit and fixed here, worth knowing before touching this file again:

- **Cell ordering**: Excel's strict OOXML loader requires a `<row>`'s `<c>`
  children in ascending column order. A `<c>` inserted out of that order is
  well-formed XML (lenient readers like `:xmerl_scan`/openpyxl accept it) but
  triggers Excel's "problem with some content" repair prompt anyway. There's
  a dedicated regression test asserting ascending order per row across every
  cell `Forms` can fill.
- **Formula-cache stripping**: the templates cache formula results as either
  `<f>...</f><v>result</v>` or a self-closing `<v/>` (empty cache). A regex
  that tries the open-tag `<v ...>` form before the self-closing form, using
  a bare `[^>]*` before the closing `>`, will greedily consume the `/` of a
  self-closing `<v/>` and then scan forward to the next unrelated `</v>`
  later in the row — silently deleting every cell in between. This exact bug
  shipped and deleted 99-186 cells per fill before being caught; the fix
  matches self-closing forms first with a `(?<!\/)` lookbehind guard on the
  open-tag alternative. There's a cell-preservation invariant test (fills
  each of the four templates, asserts zero cells lost) specifically guarding
  against a regression of this class.

## SQLite concurrency

SQLite allows exactly one writer at a time. This project's config
(`config/test.exs`, `config/dev.exs`, `config/runtime.exs` prod block) sets
`journal_mode: :wal` + a generous `busy_timeout` (15s) everywhere —
rollback-journal mode lets a single reader starve every writer, and the
Exqlite adapter's 2000ms default timeout is too short for concurrent
arbiters/tests. **Do not remove either setting.** In tests specifically,
`test_helper.exs` also sets `max_cases: 1` for the same underlying reason —
the ExUnit sandbox holds a write-lock-adjacent transaction per test process
for its whole duration, and true parallelism exhausts the single-writer
budget past even the generous timeout. Any `async: true` test file that
writes heavily should still be reviewed for cross-test lock contention.

## Live-refresh model

Every tournament-scoped write calls `Tournaments.broadcast_tournament_change/2`
(topic `"tournament:#{id}"`) or `broadcast_user_tournaments/1` (topic
`"tournaments_user:#{uid}"`, for the tournament list page). Every
tournament LiveView subscribes on mount and reloads its own assigns on
receipt — there is no polling anywhere. A page mid-edit (e.g. a settings
form) uses a "dirty" flag pattern (`attach_dirty_tracker/1` in
`settings_support.ex`) so an incoming broadcast doesn't clobber text the
arbiter is actively typing; it shows a "stale, reload to see changes" banner
instead of silently overwriting the form.

## Testing conventions (see also `docs/setup-guide.md` for running them)

- **Test tags**: `@tag :javafo` (needs the real `javafo.jar` + a JRE —
  gitignored, present on real dev machines, absent in CI) and
  `@tag :swar_fixture` (needs the real, gitignored `.swar` fixture files
  under `test/fixtures/`, including the maintainer's own real 42-player club
  championship data). `test_helper.exs` excludes both automatically when the
  underlying artifact is absent, so `mix test` is safe to run anywhere, but
  a report of "N passed" from CI is a strictly smaller number than what a
  real dev machine sees — check the excluded count before assuming full
  coverage ran.
- **A LiveView test whose last action is a broadcast-triggering write**
  through a PubSub-subscribed LiveView must end with a synchronizing
  `render(lv)` — otherwise the test process can race past the async
  broadcast/reload and the sandboxed DB connection gets torn down mid-query
  from the LiveView's own re-render, surfacing as a flaky `Database busy`
  error that only shows up under load (CI's slower runners exposed this
  repeatedly; local runs often don't).
- **Testing a LiveView handler that's expected to RAISE**: `assert_raise`
  around `render_hook/3` does **not** work — a proxy process sits between
  the test and the actual LiveView process, so the raise happens in a
  process you're not asserting against. Use
  `Process.flag(:trap_exit, true)` then
  `assert catch_exit(render_hook(...))` — see
  `test/pairings_engine_web/live/player_scope_security_test.exs` for the
  working pattern.
- A player id reaching a handler from an event payload is
  **attacker-controlled** even inside an authorized tournament's LiveView —
  `get_player!/2` always takes the tournament as a scoping argument
  (`Repo.get_by!(Player, id: id, tournament_id: tournament_id)`), never a
  bare `get_player!(id)`. This was a real IDOR fixed in this codebase's
  history; don't reintroduce an unscoped lookup.

## Non-obvious patterns worth knowing before you're surprised by them

- **`.form-grid` vs. the Settings `.set-*` primitives**: the six Settings
  pages (`settings_*_live.ex`) use dedicated layout primitives
  (`settings_support.ex`'s `setting_group/1`/`setting_field/1`/
  `setting_toggle/1`) — a deliberate, from-scratch layout system, NOT
  `.form-grid`. Every other page (`tournaments_live.ex`, `norms_live.ex`,
  etc.) still uses the older `.form-grid` + `label.field` pattern (~99 uses
  across 11 files) and is **intentionally** left that way — don't migrate
  one page to the other system as a "cleanup" without discussing it first;
  they coexist on purpose.
- **Checkbox/radio row alignment**: `.field-check` (a `label.field` that
  wraps a checkbox, laid out as a row instead of `.field`'s default column)
  and `.opt-row`/`.opt-row.opt-baseline` (one inline radio/checkbox option
  per row) are the shared classes for this — added specifically to replace
  a pile of copy-pasted inline `style="display: flex; ..."` attributes.
  Reach for these before writing another one-off inline style for the same
  shape.
- **The bracket-map's popover height reservations are both deferred.** A
  popover opening downward has to fit inside `.pe-bracket-scroll`'s vertical
  clip, so the canvas must be tall enough to hold one — but the canvas's
  inline `min-height` rests at exactly the graph's own height, and the two
  reservations travel as custom properties (`--pe-hover-min` for the short
  hover popover, `--pe-pinned-min` for the much taller pinned one, which
  grows a cross-round trail) that CSS `:has()` rules on
  `.pe-bracket-canvas` apply only while a wrap is hovered/focused or
  pinned. Both were unconditional at some point and both left a dead scroll
  band under the chart — the pinned one a large obvious band, the hover one
  a ~110px band that looked intermittent because whether it cleared the
  graph's own height depended on the round's bracket shape. Don't turn
  either back into an unconditional reservation. The above/below flip
  (`dot_wrap/4`'s `pop_v`) is a separate decision and still tests against
  the *pinned* room, so a pinned popover always opens onto a side that can
  be grown; leave that alone too.
- **`bye_points/2` (in `standings.ex`) is the single source of truth** for
  what any bye type is worth, including the `presence_on_allocated_bye`
  SWAR add-on. `player_card.ex`'s bye row labels are driven by the bye's
  *kind* (a `:bye_type` key `Standings` carries on every game record), never
  by reverse-guessing the kind from the point value — custom scoring can
  make two different bye kinds pay the same number of points, and the old
  point-value-guessing heuristic mislabelled those.
- **DE (direct encounter) tiebreak groups by the same key standings ranks
  by** — `total` (points + extra) when `count_extra_points` is on, plain
  `points` otherwise — via one shared `rank_score/2` helper used by both the
  ranking sort and DE's grouping. They used to be able to disagree (DE
  always grouped by raw points even when ranking used `total`), silently
  skipping Article 6 comparison for players who were actually tied on the
  real ranking key.
- **`adjusted_score/2`** (Article 16.3, an opponent's trailing voluntarily
  unplayed rounds count as draws for tiebreak purposes) pads a withdrawn
  opponent's *missing* trailing rounds — not just rounds with an explicit
  "not played, voluntary" record — the same way, because a withdrawn/
  forfeited player stops generating ANY record (no pairing, no bye row) for
  every round after they leave, and the two cases must be scored
  identically or every one of their past opponents' Buchholz/SB is silently
  understated.
- **Git line endings**: `.gitattributes` pins every source file type to LF.
  `mix format --check-formatted` treats CRLF as "not formatted" — if it
  starts failing repo-wide for files you didn't touch, check
  `git config core.autocrlf` before assuming a real formatting regression.

## Deployment & release surfaces (see `docs/deployment.md` / `docs/binaries.md`)

Three independent ways this app ships, all from the same codebase, none
depending on the others:
1. **Traditional VPS deploy** — `mix phx.server` under systemd, MIX_ENV=prod,
   SQLite file on local disk. See `docs/deployment.md` for the actual live
   instance's specifics.
2. **Standalone Burrito binaries** — one self-contained executable per
   OS/arch, built in CI per-native-runner (the SQLite driver is a native NIF,
   so no cross-compiling). See `docs/binaries.md`.
3. **Local dev** — `mix phx.server` directly, SQLite file in the repo root
   (gitignored).

CI (`.github/workflows/elixir.yml`) runs the Elixir test/format/compile
checks; `.github/workflows/binaries.yml` builds and uploads the five Burrito
targets, and attaches them as release assets on a `v*` tag push.
