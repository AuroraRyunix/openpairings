# OpenPairings documentation

OpenPairings is a chess tournament manager (Elixir/Phoenix + LiveView + SQLite):
Swiss pairing via JaVaFo, round robin (Berger), the Keizer system,
FIDE-compliant tiebreaks (C.07), TRF16, FIDE rating sync, SWAR import,
per-tournament sharing, and FIDE norm/report forms.

## Feature guides

- [Pairing systems](pairing-systems.md) — Swiss (FIDE Dutch via JaVaFo),
  round robin (Berger tables, single/double), and the Keizer system (ladder
  values, retroactive recalculation, Keizer-point standings); the per-tournament
  selector locks after the first pairing.
- [Forbidden pairings](forbidden-pairings.md) — pairs of players that must
  never meet: managed in Settings, enforced in Swiss (JaVaFo `XXP`) and Keizer;
  round robin ignores them by design.
- [SWAR import](swar-import.md) — .swar parsing, national vs FIDE id mapping,
  FIDE-database matching for players without a FIDE id (with a resolve step
  during import), full birth dates, federation normalization to FIDE codes.
- [Printing](printing.md) — print documents (player list, cards, pairings,
  standings, per-round result cards, cross table), the `?round=N` query param,
  and per-page/per-round print buttons.
- [Norms & FIDE forms](norms.md) — generating IT3 (per tournament) and FA1 / IA1
  (arbiter norms) / IT4 (player title norms) by filling the official FIDE Excel
  templates in place; the Officials data captured in Settings.
- [Import / export](import-export.md) — user-facing TRF export with round
  selection (`?rounds=1-5,7`), and full-fidelity JSON backup/restore of a single
  tournament or all of them (imports become new tournaments owned by you).
- [Team sharing](teams.md) — invite people to a tournament by email; they accept
  via a magic link before getting access, then can edit/pair/enter results.
  Owner-only: delete and collaborator management. Data model:
  `tournament_collaborators` (status pending/accepted).
- [Public pages](public-pages.md) — share `/p/<token>/pairings` and
  `/p/<token>/standings`: no login needed, read-only, live-updating, and the
  token is unguessable so tournaments can't be enumerated.
- [Mobile / responsive](mobile.md) — how the layout adapts at phone/tablet
  widths (breakpoints, scrollable tables, wrapping nav) while desktop stays
  full-width and unchanged.
- [Email / SMTP](email.md) — local mailbox preview in dev (`/dev/mailbox`), Gmail
  SMTP configuration via `.env` for production, credential management.

## Cross-cutting behavior

- **Live refresh** — every tournament LiveView subscribes to
  `"tournament:#{id}"` over Phoenix PubSub; any write (result, player, settings,
  sharing) pushes to all open pages instantly, no polling. Open the projector
  view at `/t/:id/live`.
- **Result codes** — `1-0`, `½-½`, `0-1`, plus forfeits `1-0FF` / `0-1FF` /
  `0-0FF` (double forfeit, unplayed) and a played `0-0` (both lose). Forfeits are
  Art. 16 unplayed for tiebreaks; played `0-0` counts as played. `Trf.serialize`
  raises `Trf.ValidationError` on illegal result combinations.

## Where things live

- `lib/pairings_engine/` — domain: `pairing.ex` (JaVaFo), `standings.ex` (C.07
  tiebreaks, supports `through_round:`), `trf.ex` (TRF16 + result validation),
  `trf_export.ex` / `tournament_export.ex` / `tournament_import.ex` (exports),
  `fide/sync.ex` (rating-list sync), `swar_import.ex` (.swar importer),
  `norms/` (Excel form fill engine + form mappers), `player_card.ex`,
  `tournaments/collaborator.ex` (sharing).
- `lib/pairings_engine_web/live/` — LiveView pages (one per top-bar tab), all
  subscribing to `"tournament:#{id}"` PubSub for instant live refresh.
- `priv/norm_templates/` — the official FIDE `.xlsx` templates.
