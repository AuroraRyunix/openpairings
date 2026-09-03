defmodule PairingsEngine.Federations.BEL.SwarExport do
  @moduledoc """
  Writes a `.swar` file from an OpenPairings tournament - the inverse of
  `PairingsEngine.Federations.BEL.SwarImport`, built field-for-field against its read
  order and its reverse-mapping tables. See that module's moduledoc for
  the format background, and `docs/swar-import.md` for the underlying
  reverse-engineering notes.

  ## Why v7, and only v7

  `SwarImport` copes with v5/v6/v7 because it has to handle whatever an
  arbiter hands it. `export/1` only ever writes ONE version, hardcoded as
  `"v7.00"` - there is no reason to synthesize an older layout, and one
  concrete reason not to: v6's `[JOUEURS]` record carries
  `points_adjusted`, an arbiter's own manual correction entered inside
  SWAR itself, which does not exist for a tournament that has never been
  opened there. Targeting v7 sidesteps that field, and the separate
  `EloFide` field (v7 reuses `Elo` for both - see `reverse_player/1`).

  ## What's been checked, and against what

  Confirmed opening cleanly in a real SWAR v7 install (not just
  `SwarImport.parse/1` reading it back) - so `@tournoi_layout` below is
  right, at least for a file with the arbiter/remarks tail this codebase
  has tried so far.

  Whether a re-paired round then MATCHES what continuing the original
  file in SWAR would have produced is a separate question - "does the
  seed survive" - and cost one real wrong answer before it was actually
  right. SWAR's Swiss pairing sorts players by `(Category, Class,
  Rank)` before calling its own pairing engine, and it was tempting to
  assume both get recomputed from the file's results the same way -
  they don't. Checked against a real copy of SWAR's source
  (`Swar - 20250906 v6.65 FRBE`, not inferred): `class` genuinely is
  safe, recomputed unconditionally right before every Swiss pairing -
  but `rank` (the seed) is only recomputed from the "add a player" UI
  action, which a bulk file load never goes through. This function's
  first version wrote `rank` as `Ni` (plain registration order); found
  wrong by exporting a real tournament, pairing round 1 in a real SWAR
  install, and comparing boards against a rating-seeded pairing - they
  didn't match at all. `assign_ranks/1` now computes the same
  rating/title/name sort SWAR's own `CmpRnkNormal` does. Full story,
  with the exact source citations, is on `reverse_player/5`'s own
  comment, and `test/pairings_engine/swar_export_test.exs` pins the
  fix down (scrambled rating vs. registration order, so a regression
  back to `rank = ni` fails loudly).

  What the test suite can check on its own, separately: the round-by-
  round RESULT data survives re-import - export, reimport through the
  real persisting path, reread the resulting `Pairing` rows.

  What's still a documented guess rather than a checked fact: whether
  `@tournoi_layout` is ALSO right for a file where the arbiter/remarks
  strings are genuinely non-blank - `SwarImport` itself couldn't pin
  that region down from the one v7 sample it had either (see
  `@tournoi_layout` below), and it's exactly why arbiter-1/arbiter-2
  don't round-trip (see `reverse_tournoi_tail_strings/2`). If a real
  export's arbiter fields come back wrong in SWAR, that's this
  ambiguity; flip `@tournoi_layout`.

  ## Known-lossy mappings

  Several `SwarImport` mappings are many-to-one - several SWAR codes
  collapse onto one OpenPairings value - and have no principled inverse.
  Each is documented at its own `reverse_*` function below rather than
  here, since the reasoning differs per field. The two structural ones
  worth knowing before reading further:

    * SWAR's `[EXCLUSION]` section is parsed but never mapped to
      anything on import (`data.exclusion` is read and discarded), so
      there is no reverse to write either - always exported empty.
    * SWAR's `[CATEGORIES]` section is TWO parallel 16-slot lists
      (`value1`/`value2`, presumably two independent category
      dimensions); import already collapses them into one flat list
      (`map_categories/1` concatenates both). Export puts everything
      back into `value1` and leaves `value2` blank - which dimension a
      category belonged to was never captured, so there is nothing to
      restore it from.
  """

  import Ecto.Query
  require Logger

  alias PairingsEngine.{Encoding, Repo, Standings, Tournaments}
  alias PairingsEngine.Federations.BEL.SwarImport
  alias PairingsEngine.Tournaments.Tournament

  # Table number sentinel for a pairing-allocated bye (Swar.h TABLE_BYE) -
  # mirrors `SwarImport`'s own `@table_bye`, kept as a second copy rather
  # than made public there: it is read-side vocabulary that export needs
  # too, not a shared concept worth coupling the two modules over.
  @table_bye 0x1000

  # `{fide-id entries, trailing strings}` - see `SwarImport`'s own
  # `@tournoi_layouts` and the moduledoc above. `:v7_strings` is
  # `SwarImport`'s own FIRST guess for a v7 file (see
  # `parse_tournoi_section/2`'s `order`), so writing that layout is what a
  # real v7 `.swar` most likely already looks like, on the evidence this
  # codebase has. Sixteen FIDE-id entries, ONE trailing string (folding
  # arbiter-1/arbiter-2/remarks into a single free-text field - see
  # `reverse_tournoi/1`).
  @tournoi_layout {16, 1}

  @doc """
  Builds a v7 `.swar` binary for `tournament`. Loads players, rounds and
  byes itself - pass a plain `%Tournament{}` (or its `id`), not a
  pre-preloaded one, since the round/pairing assembly below needs several
  separate queries `Repo.preload/2` would not give it in the right shape.
  """
  def export(%Tournament{} = tournament), do: export(tournament.id)

  def export(tournament_id) when is_integer(tournament_id) do
    tournament = Tournaments.get_tournament!(tournament_id)
    players = Tournaments.list_players(tournament_id)
    ni_by_player_id = assign_ni(players)

    rounds =
      Tournaments.list_rounds(tournament_id)
      |> Enum.map(fn round ->
        pairings = get_pairings(round.id)
        byes = Tournaments.list_byes_for_round(tournament_id, round.number)
        {round.number, pairings, byes}
      end)

    round_records = build_round_records(players, rounds, ni_by_player_id)
    categories = tournament.categories |> Enum.take(16)

    w_str("v7.00") <>
      w_str(tournament.swar_guid || Ecto.UUID.generate()) <>
      w_str("") <>
      reverse_tournoi(tournament) <>
      reverse_dates(tournament) <>
      reverse_tie_break(tournament) <>
      reverse_exclusion() <>
      reverse_categories(categories) <>
      reverse_xtra_points() <>
      reverse_joueurs(players, categories, ni_by_player_id, round_records)
  end

  ## ---------- Write primitives - the exact inverse of SwarImport's read_* ----------

  defp w_i32(v), do: <<v::little-signed-32>>
  defp w_i16(v), do: <<v::little-signed-16>>
  defp w_u8(v), do: <<v::8>>

  defp w_str(s) do
    bytes = Encoding.cp1252_encode(s || "")
    w_i32(byte_size(bytes)) <> bytes
  end

  defp w_n(list, fun), do: Enum.map_join(list, "", fun)

  ## ---------- [TOURNOI] ----------

  defp reverse_tournoi(t) do
    {n_fide_ids, n_strings} = @tournoi_layout

    # `arbiter1`/`arbiter2` on import: `arbiter1` becomes `chief_arbiter`
    # via `strip_arbiter_title/1` (a one-way trim - a stripped title
    # can't be reconstructed, so this writes the title-less name SWAR
    # would have to re-derive the same way); `arbiter2`/`deputy_arbiter`
    # is kept raw both directions.
    # FRBE/FIDE homologation-range fields: no OpenPairings equivalent
    # (rounds_count-wide homologation is tracked as a single boolean,
    # `fide_homologated`, not a from/to round range) - written as "not
    # set" rather than guessed.
    # `cat_separes` ("categories use separate standings tables") - no
    # OpenPairings equivalent; 0 (off) is the safe default.
    # `elo_ou_pays` ("prefer Elo or federation for tiebreak/seeding
    # display") - no OpenPairings equivalent; 0 is SWAR's own default.
    # `plusieurs` ("several tournaments in one club session") - no
    # OpenPairings equivalent; 0 (off).
    # `first_table` (starting board number offset) - OpenPairings always
    # numbers boards from 1.
    # `elo_used` (which rating column feeds pairing/tiebreak) - no
    # single OpenPairings equivalent (`Player.rating/1` always prefers
    # FIDE); 0 is SWAR's own default.
    # `tb_personel` (custom tiebreak formula toggle) - not modeled.
    # `appar_order` (pairing-list display order) - not modeled.
    # `elo_equal` (how equal-rated players are ordered) - not modeled.
    # `ff_value` - the points paid for a forfeit, distinct from
    # `abs_value`; not modeled as its own tournament setting
    # (`Standings` scores a forfeit the same as an ordinary
    # win/loss/draw code, not via a separate club-configured value), so
    # this can't be reconstructed. 0 (SWAR's own "zero points") is the
    # closest safe default.
    w_str("[TOURNOI]") <>
      w_str(t.name) <>
      w_str(t.organizer) <>
      w_str(t.organizer_club_number) <>
      w_str(t.city) <>
      w_str(t.chief_arbiter) <>
      w_str(t.deputy_arbiter) <>
      w_str(t.start_date) <>
      w_str(t.end_date) <>
      w_i32(reverse_cadence(t)) <>
      w_str(if reverse_cadence(t) == -1, do: t.rate_of_play, else: "") <>
      w_i32(t.rounds_count) <>
      w_i32(0) <>
      w_i32(0) <>
      w_i32(0) <>
      w_i32(0) <>
      w_i32(0) <>
      w_i32(0) <>
      w_i32(if t.fide_homologated, do: 1, else: 0) <>
      w_n(List.duplicate(nil, n_fide_ids), fn _ -> w_i32(0) <> w_i32(0) <> w_i32(0) end) <>
      w_n(reverse_tournoi_tail_strings(t, n_strings), &w_str/1) <>
      w_i32(reverse_tournament_type(t.type)) <>
      w_i32(0) <>
      w_i32(0) <>
      w_i32(0) <>
      w_i32(1) <>
      w_i32(round(t.points_win * 4)) <>
      w_i32(round(t.points_draw * 4)) <>
      w_i32(round(t.points_loss * 4)) <>
      w_i32(round((t.bye_value || 0.0) * 4)) <>
      w_i32(round((t.presence_value || 0.0) * 4)) <>
      w_i32(if t.presence_on_allocated_bye, do: 1, else: 0) <>
      w_i32(0) <>
      w_i32(reverse_standard(t.standard)) <>
      w_i32(0) <>
      w_i32(0) <>
      w_i32(0) <>
      w_i32(reverse_bye_value(t.bye_value)) <>
      w_u8(if (t.abs_value || 0.0) > 0, do: 1, else: 0) <>
      w_u8(abs_cap(t, t.abs_nbfois)) <>
      w_u8(abs_cap(t, t.abs_jusque)) <>
      w_u8(0) <>
      w_i32(0) <>
      w_i32(reverse_federation(t.federation))
  end

  # `Cadence` is a 0-based index into a dropdown SWAR fills at runtime from
  # `t.standard` (see `SwarImport.cadence_label/2`) - reversing it means
  # finding which index THAT dropdown would show `t.rate_of_play` at. -1
  # (SWAR's own "custom" sentinel - verified against `cadence_label/2`
  # returning `nil` for any cadence outside its known table) falls back to
  # writing `t.rate_of_play` as free text in `Cadence_Other` instead.
  defp reverse_cadence(t) do
    0..20
    |> Enum.find(-1, &(SwarImport.cadence_label(t.standard, &1) == t.rate_of_play))
  end

  # v7_strings folds arbiter-1/arbiter-2/remarks into ONE trailing string
  # (see `@tournoi_layout`) - `SwarImport.parse_tournoi/3` reads a
  # single-element list back as `{"", "", remarks}`, so anything written
  # as `fide_arb1`/`fide_arb2` here is unrecoverable on reimport no matter
  # what goes in it. There's no dedicated "FIDE remarks" field on
  # `Tournament` either, so this carries the deputy arbiter text instead
  # of nothing - better than an empty string, not a claim it's correct.
  defp reverse_tournoi_tail_strings(t, 1), do: [t.deputy_arbiter]
  defp reverse_tournoi_tail_strings(t, 4), do: [t.chief_arbiter, t.deputy_arbiter, "", ""]

  @tournament_type_reverse %{"swiss" => 0, "roundrobin" => 4}
  # `team-swiss`/`team-roundrobin` have no SWAR code of their own (import
  # never produces them - see `SwarImport`'s `@tournament_types`, every
  # entry maps to plain "swiss"/"roundrobin"), so they fall back to their
  # non-team base type: the closest SWAR concept, not an exact one.
  defp reverse_tournament_type("team-swiss"), do: 0
  defp reverse_tournament_type("team-roundrobin"), do: 4
  defp reverse_tournament_type(type), do: Map.get(@tournament_type_reverse, type, 0)

  defp reverse_standard("standard"), do: 0
  defp reverse_standard("rapid"), do: 1
  defp reverse_standard("blitz"), do: 2
  defp reverse_standard(_), do: 0

  # SWAR's absence caps, where nil does NOT mean zero.
  #
  # In OpenPairings a nil `abs_jusque`/`abs_nbfois` means "no cap" -
  # `Standings.round_capped?/2` and `count_capped?/2` only fire
  # `when is_integer(cap)`. In SWAR's format 0 is a real value meaning "no
  # round qualifies" / "no absence qualifies", i.e. pay nothing. Writing
  # `|| 0` mapped nil onto the byte that means the opposite of nil, so a
  # tournament paying an uncapped half point for every round sat out
  # exported as one paying nothing, and re-importing it made that true.
  #
  # Reachable from the ordinary UI, not just an import: SettingsScoringLive
  # tells the arbiter to leave the limits blank for "no cutoff round" and
  # "every one pays", and blank casts to nil.
  #
  # Three cases:
  #   * the checkbox is off (`abs_value` nil or 0) - write 0, which is what
  #     SWAR itself writes and what line 223 has already said;
  #   * a real cap - write it;
  #   * no cap, with a value to pay - write the round count, which is
  #     "every round" and "every absence" in a tournament that long. It is
  #     the largest honest number rather than a sentinel, and it survives
  #     the u8 because `rounds_count` is capped at 30.
  #
  # Whatever the branch, the result goes through `w_u8/1` (`<<v::8>>`), which
  # MASKS rather than fails: 256 came out as 0, i.e. "no round qualifies",
  # the exact opposite of a very high cap. So the integer branch is clamped
  # to `@max_abs_cap` and says so in the log, the same way
  # `reverse_handy_table/1` handles its own field's range. `Tournament`'s
  # changeset now bounds both columns at 255 as well, so this is a backstop
  # for rows written before that bound existed.
  defp abs_cap(t, cap) do
    cond do
      (t.abs_value || 0.0) <= 0 -> 0
      is_integer(cap) -> clamp_abs_cap(t, cap)
      true -> t.rounds_count || 0
    end
  end

  # The largest value SWAR's one-byte absence-cap fields can hold.
  @max_abs_cap 255

  defp clamp_abs_cap(_t, cap) when cap <= @max_abs_cap, do: cap

  defp clamp_abs_cap(t, cap) do
    Logger.warning(
      "SWAR export: #{t.name}'s absence cap #{cap} is past SWAR's one-byte range " <>
        "(max #{@max_abs_cap}); exporting #{@max_abs_cap} instead."
    )

    @max_abs_cap
  end

  defp reverse_bye_value(1.0), do: 0
  defp reverse_bye_value(0.5), do: 1
  defp reverse_bye_value(v) when v == 0.0, do: 2
  defp reverse_bye_value(_), do: 0

  # Belgian sub-federation codes 1-6 all collapse to the single FIDE
  # country code "BEL" on import (`normalize_federation/1`) - which ONE
  # organized the tournament is gone by the time it reaches
  # `tournament.federation`. 2 (KBSB, the national federation itself) is
  # the arbitrary-but-documented choice for writing it back; any other
  # value (a real FIDE country code, or "") has no SWAR federation-code
  # equivalent at all - that field means "which Belgian entity", not "which
  # country" - so it becomes 0 ("none selected").
  defp reverse_federation("BEL"), do: 2
  defp reverse_federation(_), do: 0

  ## ---------- [DATES] ----------

  defp reverse_dates(t) do
    dates = t.round_dates || []
    padded = dates ++ List.duplicate("", max(t.rounds_count - length(dates), 0))
    w_str("[DATES]") <> w_n(Enum.take(padded, t.rounds_count), &w_str/1)
  end

  ## ---------- [TIE_BREAK] ----------

  @tiebreak_reverse %{"BH" => 1, "BHC1" => 4, "SB" => 6, "DE" => 8, "WIN" => 10, "PS" => 7}

  defp reverse_tie_break(t) do
    codes =
      (t.tiebreaks || [])
      |> Enum.map(&Map.get(@tiebreak_reverse, &1))
      |> Enum.reject(&is_nil/1)

    padded = codes ++ List.duplicate(0, max(5 - length(codes), 0))
    w_str("[TIE_BREAK]") <> w_n(Enum.take(padded, 5), &w_i32/1)
  end

  ## ---------- [EXCLUSION] ----------

  # Never mapped to anything on import (see moduledoc) - written as "off,
  # no list" rather than guessed.
  defp reverse_exclusion, do: w_str("[EXCLUSION]") <> w_i32(0) <> w_str("")

  ## ---------- [CATEGORIES] ----------

  defp reverse_categories(categories) do
    value1 = ["" | categories] |> pad_strings(17)
    value2 = List.duplicate("", 17)

    w_str("[CATEGORIES]") <>
      w_i32(if categories == [], do: 0, else: 1) <>
      w_n(value1, &w_str/1) <>
      w_n(value2, &w_str/1)
  end

  defp pad_strings(list, n) when length(list) >= n, do: Enum.take(list, n)
  defp pad_strings(list, n), do: list ++ List.duplicate("", n - length(list))

  ## ---------- [XTRA_POINTS] ----------

  # SWAR's own Elo-band extra-points table - a DIFFERENT mechanism from
  # `Tournament.extra_points_bands` (OpenPairings' own band syntax, an
  # importer-side addition with no SWAR-side field to write back to; see
  # `docs/extra-points.md`). Four empty bands, matching "feature unused".
  defp reverse_xtra_points,
    do: w_str("[XTRA_POINTS]") <> w_n(1..4, fn _ -> w_i32(0) <> w_i32(0) end)

  ## ---------- [JOUEURS] ----------

  # SWAR's own internal player number (`NI`) IS `pairing_number` - checked
  # directly against `SwarImport.player_attrs/2`, `pairing_number: p.ni`.
  # A player who was never paired has no `pairing_number`; such a player
  # has no round records either (see `build_round_records/3`), so their NI
  # is cosmetic - just needs to be distinct - and gets one continuing past
  # the highest real pairing number.
  defp assign_ni(players) do
    max_assigned =
      players |> Enum.map(& &1.pairing_number) |> Enum.filter(& &1) |> Enum.max(fn -> 0 end)

    {map, _next} =
      Enum.reduce(players, {%{}, max_assigned + 1}, fn player, {map, next} ->
        case player.pairing_number do
          nil -> {Map.put(map, player.id, next), next + 1}
          ni -> {Map.put(map, player.id, ni), next}
        end
      end)

    map
  end

  # `Rank` is SWAR's own initial seed - checked against a real copy of its
  # source (`Swar - 20250906 v6.65 FRBE`), NOT inferred: `Joueur.cpp`'s
  # `CmpRnkNormal` sorts by rating descending, then title descending
  # (`J_TITRE`'s own enum order - GM highest), then a configurable
  # tie-break defaulting to name (`ELO_EQUAL`'s `EQUAL_ALPHA = 0`, the
  # value `reverse_tournoi/1` already writes for `elo_equal`, since it had
  # no better default at the time - this makes that choice load-bearing
  # rather than arbitrary, so the two now agree on purpose).
  #
  # Unlike `Class` (see `reverse_player/4`'s own comment), `Rank` is NOT
  # recomputed on a plain file load for a Swiss tournament - checked
  # directly: `RecomputeRank()` only runs from the "add a player" action
  # (`Base.cpp`) or Round Robin's own pre-pairing prompt
  # (`SwarView.cpp`'s `AskRankingMethode()`, itself Robin-only), neither
  # of which a bulk file-open goes through. Writing `Rank` as `Ni`
  # (registration order) here - this function's first version - meant
  # SWAR paired round 1 by registration order instead of rating: found by
  # exporting a real tournament, pairing round 1 in a real SWAR install,
  # and comparing boards. `Class` doesn't have the same failure mode (see
  # its own comment) because `CalculLeClassement` - which DOES run
  # unconditionally before every Swiss pairing - computes it fresh from
  # each player's actual points every time, with no "only on this one
  # action" gap for it to fall through.
  # `reverse_title/1`'s `@title_reverse` IS `J_TITRE`'s own enum order -
  # higher value wins a rating tie, same table, reused rather than
  # duplicated.
  defp assign_ranks(players) do
    players
    |> Enum.sort_by(&{-(&1.fide_rating || 0), -reverse_title(&1.title), &1.name})
    |> Enum.with_index(1)
    |> Map.new(fn {p, i} -> {p.id, i} end)
  end

  defp reverse_joueurs(players, categories, ni_by_player_id, round_records) do
    rank_by_player_id = assign_ranks(players)

    w_str("[JOUEURS]") <>
      w_i32(length(players)) <>
      w_n(
        players,
        &reverse_player(&1, categories, ni_by_player_id, rank_by_player_id, round_records)
      )
  end

  defp reverse_player(p, categories, ni_by_player_id, rank_by_player_id, round_records) do
    ni = Map.fetch!(ni_by_player_id, p.id)
    rank = Map.fetch!(rank_by_player_id, p.id)
    rounds = Map.get(round_records, p.id, [])
    nb_parties = Enum.count(rounds, & &1.played?)
    points_x2 = round(Enum.sum(Enum.map(rounds, & &1.points)) * 2)

    # `class` and `rank` are the two fields the SWAR question "does the
    # seed survive?" turns on - SWAR's Swiss pairing sorts players by
    # exactly `(Category, Class, Rank)` before it ever calls its pairing
    # engine (`PairingSwiss.cpp`'s `InitSwiss()`: "Tri par Cat, Class,
    # Rank") - and the two behave differently, checked against a real
    # copy of SWAR's source (`Swar - 20250906 v6.65 FRBE`), not guessed:
    #
    #   * `class` is genuinely safe at a constant 0. `Swar.h` marks it
    #     "à Calculer" ("to be calculated"), and `CalculLeClassement()`
    #     - which computes it fresh from each player's actual points -
    #     runs unconditionally right before every Swiss pairing
    #     (`SwarView.cpp`'s "Première chose à faire avant appariement",
    #     "first thing done before pairing"). Whatever is on disk gets
    #     overwritten before it can matter.
    #
    #   * `rank` is NOT safe at a placeholder, despite `Swar.h` marking
    #     it "à Calculer" too - the recompute has a gap `class` doesn't.
    #     `RecomputeRank()` only runs from the "add a player" action
    #     (`Base.cpp`) or Round Robin's own pre-pairing prompt
    #     (`AskRankingMethode()`, itself Robin-only) - neither of which
    #     a bulk file load goes through. A Swiss tournament opened
    #     straight from a file pairs using WHATEVER `rank` the file
    #     said. This function's first version wrote `rank = ni`
    #     (registration order); confirmed wrong by exporting a real
    #     tournament, pairing round 1 in a real SWAR install, and
    #     finding the boards didn't match a rating-seeded pairing at
    #     all. `assign_ranks/1` now computes what
    #     `Joueur.cpp`'s `CmpRnkNormal` would: sorted by rating
    #     descending, title descending, name ascending.
    #
    # `test/pairings_engine/swar_export_test.exs` proves the round DATA
    # survives re-import; it can't prove `rank` matches what a live SWAR
    # pairing action would produce, since that needs SWAR itself to
    # check - which this specific fix already was.
    #
    # v7's single wire `Elo` IS the FIDE rating - see
    # `SwarImport.parse_player/2`'s `elo_fide` comment ("Belgium retired
    # its own rating list... the single Elo a v7 record still carries
    # IS the FIDE rating"). `national_rating` has nowhere to go in a v7
    # record at all.
    # no `points_adjusted` for v7 (see moduledoc)
    # `amer_pts` (American/Fischer-scoring points) - not modeled.
    # `perf` - SWAR's own cached performance rating; not read by
    # `player_attrs/2` on import (OpenPairings recomputes its own via
    # `PlayerStats.performance/3`), so left at 0 for SWAR to recompute
    # the same way this codebase already treats it as disposable.
    # `special_pts` - parsed but never bound into any output field on
    # import; unknown meaning.
    w_i32(0) <>
      w_str(p.name) <>
      w_i32(ni) <>
      w_i32(rank) <>
      w_i32(reverse_cat_index(p.category, categories)) <>
      w_str(reverse_birth(p)) <>
      w_i32(reverse_sex(p.sex)) <>
      w_str(reverse_federation_code(p.federation)) <>
      w_i32(reverse_national_id(p.national_id)) <>
      w_i32(p.fide_id || 0) <>
      w_i32(if p.affiliated, do: 1, else: 0) <>
      w_i32(p.fide_rating || 0) <>
      w_i32(reverse_title(p.title)) <>
      w_i32(p.club_number || 0) <>
      w_str(p.club) <>
      w_i32(nb_parties) <>
      w_i32(points_x2) <>
      w_i32(0) <>
      w_n(1..5, fn _ -> w_i32(0) end) <>
      w_i32(0) <>
      w_i32(reverse_paid(p.paid)) <>
      w_i32(reverse_absent_code(p)) <>
      w_str(p.absent_rounds || "") <>
      w_i32(round((p.extra_points || 0.0) * 4)) <>
      w_i32(0) <>
      w_i16(length(rounds)) <>
      w_i16(reverse_handy_table(p)) <>
      w_str("[RONDE]") <>
      w_n(rounds, &reverse_round/1)
  end

  # The largest table number a signed 16-bit HandyTable field can hold.
  # `w_i16/1` would WRAP anything past it rather than fail - 40000 comes out
  # as -25536 - handing SWAR a negative table and re-importing as no table at
  # all, which is the silent loss this whole field just stopped having.
  @max_handy_table 32_767

  # HandyTable is a table NUMBER, not a flag: `SwarImport`'s
  # `@table_handicap` documents SWAR's own 1001+ numbering for this very
  # field, and the importer reads it straight back into `fixed_board`. This
  # used to write `if p.special_table, do: 1, else: 0`, which degraded an
  # accessible table to a boolean - a backup/restore, an ordinary arbiter
  # workflow, quietly turned "table 7, the accessible one" into "special,
  # table unknown", and the importer then dropped even that.
  #
  # Two rows can still not carry a number, and both are explicit rather than
  # silent:
  #
  #   * A legacy `special_table: true` with no `fixed_board` - exactly what
  #     the old SWAR importer wrote, and still sitting in databases it
  #     touched. The flag is genuinely all that row has ever held, so the
  #     flag is what travels. No warning: nothing is being lost here that
  #     the row ever knew.
  #   * A `fixed_board` past `@max_handy_table`. The format cannot hold it,
  #     so the number IS lost - it degrades to the old flag (the marking
  #     survives; the table does not) and says so in the log, rather than
  #     wrapping into a negative table nobody would ever notice. Nothing is
  #     rejected over it: refusing to export the whole tournament because
  #     one table is numbered 40000 helps no arbiter.
  defp reverse_handy_table(%{fixed_board: board} = p) when is_integer(board) and board > 0 do
    if board <= @max_handy_table do
      board
    else
      Logger.warning(
        "SWAR export: #{p.name}'s fixed table #{board} is past SWAR's HandyTable range " <>
          "(max #{@max_handy_table}); exporting the accessible-table marking without the " <>
          "number, which will re-import as a fixed table of 1."
      )

      1
    end
  end

  defp reverse_handy_table(%{special_table: true}), do: 1
  defp reverse_handy_table(_p), do: 0

  defp reverse_cat_index("", _categories), do: 0
  defp reverse_cat_index(nil, _categories), do: 0

  defp reverse_cat_index(category, categories) do
    case Enum.find_index(categories, &(&1 == category)) do
      nil -> 0
      index -> (index + 1) * 100
    end
  end

  # "YYYYMMDD" when the full date is known, "YYYY0000" when only the year
  # is (still recovers `birth_year/1` on reimport - `Integer.parse` only
  # reads the first 4 characters; `birth_date/1` correctly comes back nil,
  # since month/day 00 isn't a real date), "" when neither is.
  defp reverse_birth(%{birth_date: %Date{} = d}),
    do: :io_lib.format("~4..0B~2..0B~2..0B", [d.year, d.month, d.day]) |> IO.iodata_to_binary()

  defp reverse_birth(%{birth_year: year}) when is_integer(year),
    do: :io_lib.format("~4..0B0000", [year]) |> IO.iodata_to_binary()

  defp reverse_birth(_p), do: ""

  defp reverse_sex("m"), do: 1
  defp reverse_sex("w"), do: 2
  defp reverse_sex(_), do: 0

  @title_reverse %{
    "WCM" => 1,
    "WFM" => 2,
    "CM" => 3,
    "WIM" => 4,
    "FM" => 5,
    "WGM" => 6,
    "HM" => 7,
    "IM" => 8,
    "HG" => 9,
    "GM" => 10
  }
  defp reverse_title(title), do: Map.get(@title_reverse, title, 0)

  defp reverse_paid("nopaid"), do: 0
  defp reverse_paid("paid"), do: 1
  defp reverse_paid("gratis"), do: 2
  defp reverse_paid(_), do: 1

  # `federation` on `Player` is a plain FIDE country code (e.g. "BEL"), but
  # SWAR's per-player `Country` field on import is read as a STRING and
  # passed through `normalize_federation/1` - so unlike the tournament-level
  # `federation` int field above, this one really is just the code itself,
  # written back verbatim.
  defp reverse_federation_code(code), do: code || ""

  # `national_id`/`mat_nat` - SWAR stores this as an int; OpenPairings
  # keeps it as a string (`zero_to_blank/1` is the import-side reverse:
  # `0 -> ""`, `n -> Integer.to_string(n)`). A non-numeric national_id
  # (federations that use alphanumeric ids) has no SWAR representation at
  # all - 0, same as blank.
  defp reverse_national_id(nil), do: 0

  defp reverse_national_id(str) do
    case Integer.parse(str) do
      {n, ""} -> n
      _ -> 0
    end
  end

  # Absent: 1=Forfeit, 2=Absent, 4=Present (manual §5.19) - see
  # `SwarImport.map_absent/2`'s doc for why raw 2 covers BOTH "globally
  # absent" and "sitting out specific rounds via AbsentRondes": reimporting
  # only recovers `absent: true` when `absent_rounds` comes back blank, so
  # a player who is BOTH globally absent AND carries round-specific text
  # cannot round-trip through this one field - an ambiguity in SWAR's own
  # encoding, not something export can fix.
  defp reverse_absent_code(%{forfeit: true}), do: 1
  defp reverse_absent_code(%{absent: true}), do: 2
  defp reverse_absent_code(%{absent_rounds: rounds}) when rounds not in [nil, ""], do: 2
  defp reverse_absent_code(_p), do: 4

  ## ---------- [RONDE] ----------

  defp reverse_round(%{round_nr: n, table: table, advers: advers, result: result, colour: colour}) do
    w_i32(n) <>
      w_i32(table) <> w_i32(advers) <> w_i32(result) <> w_i32(colour) <> w_i32(0) <> w_i32(0)
  end

  # One preloaded round's pairings, keyed the way `reverse_player/4` wants
  # them: white/black players + result, board number, nothing sentinel
  # about pairing-allocated byes still to resolve (that happens in
  # `round_record_for/4`).
  defp get_pairings(round_id) do
    from(p in PairingsEngine.Tournaments.Pairing,
      where: p.round_id == ^round_id,
      preload: [:white_player, :black_player]
    )
    |> Repo.all()
  end

  # Builds every player's per-round `[RONDE]` entries across the whole
  # tournament, keyed by player id. A round BEFORE the player's
  # `start_round` (they hadn't joined yet) is omitted - genuinely never
  # happened for them. A round from `start_round` onward with no pairing
  # and no byes row (globally `absent: true`, no per-round bye recorded)
  # gets an explicit zero-point "absent" record instead of being skipped.
  #
  # This used to omit those rounds outright, on the theory that our own
  # reader (`SwarImport.parse_round/1`) doesn't need the array to be
  # contiguous - true, but irrelevant: real SWAR never produces a player
  # with fewer round-entries than rounds they were registered for (every
  # absence there is an explicit UI action), and real SWAR's own reader
  # turned out not to tolerate the shape either - a real tournament
  # export with a player like this (many rounds absent, no per-round bye
  # rows) came back from actual SWAR with garbled rounds for exactly that
  # player: "???" opponent names and phantom results for rounds that were
  # never recorded that way, i.e. the reader desyncing past a truncated
  # block into the next player's raw bytes. Always writing a full,
  # gap-free block avoids the shape entirely.
  defp build_round_records(players, rounds, ni_by_player_id) do
    for player <- players, into: %{} do
      records =
        for {number, pairings, byes} <- rounds,
            record = round_record_for(player, number, pairings, byes, ni_by_player_id),
            record != nil,
            do: record

      {player.id, records}
    end
  end

  defp round_record_for(player, number, pairings, byes, ni_by_player_id) do
    pairing =
      Enum.find(pairings, &(&1.white_player_id == player.id or &1.black_player_id == player.id))

    bye = Enum.find(byes, &(&1.player_id == player.id))

    cond do
      pairing && is_nil(pairing.black_player_id) ->
        # Pairing-allocated bye: `SwarImport.single_sided/2`'s FIRST check
        # is the result bitmask (`:win_bye`, 0x0040) - table only matters
        # as a fallback for a result-less bye, so writing both is
        # belt-and-braces, not strictly required by the read side.
        %{
          round_nr: number,
          table: @table_bye,
          advers: 0,
          colour: 0,
          result: 0x0040,
          points: 1.0,
          played?: false
        }

      pairing ->
        white? = pairing.white_player_id == player.id
        opponent = if white?, do: pairing.black_player, else: pairing.white_player
        opponent_ni = Map.fetch!(ni_by_player_id, opponent.id)
        {my_result, my_points} = result_bits(pairing.result, white?)

        %{
          round_nr: number,
          table: pairing.board,
          advers: opponent_ni,
          colour: if(white?, do: 1, else: -1),
          result: my_result,
          points: my_points,
          # `Standings.played_result?/1`, not a private list. This was
          # `~w(1-0 1/2-1/2 0-1 0-0)` - four of the nine codes Standings
          # marks played - so the VCL.13 asymmetric results and the unrated
          # W/D/L twins all counted as not played. That flag feeds exactly
          # one output, the `NbParties` i32, so a player whose games were
          # unrated exported as "0 games played" next to nonzero points and
          # three populated round records.
          #
          # Provably drift rather than intent: `result_bits/2` in this same
          # file already handled all five missing codes before this line was
          # written.
          played?: Standings.played_result?(pairing.result)
        }

      bye && bye.type == "requested-half" ->
        %{
          round_nr: bye.round,
          table: 0,
          advers: 0,
          colour: 0,
          result: 0x0020,
          points: 0.5,
          played?: false
        }

      bye && bye.type == "requested-zero" ->
        %{
          round_nr: bye.round,
          table: 0,
          advers: 0,
          colour: 0,
          result: 0x0010,
          points: 0.0,
          played?: false
        }

      bye && bye.type == "absent" ->
        absent_record(bye.round)

      # No pairing, no byes row - the round the player wasn't there for
      # and nobody logged a bye/absence type for. Before, this was a `nil`
      # (round omitted from the array); see `build_round_records/3`'s
      # comment for why that produced garbled real-SWAR reads. Anything
      # from the player's `start_round` onward gets the exact same
      # zero-point shape as a real declared absence, just above - a round
      # BEFORE `start_round` (not registered yet) stays correctly omitted.
      number >= (player.start_round || 1) ->
        absent_record(number)

      true ->
        nil
    end
  end

  # Shared shape for a zero-point declared-absence round, used both for a
  # real "absent" byes-table row and for a gap round with neither a
  # pairing nor a byes row (see `round_record_for/5`'s two call sites).
  defp absent_record(round_nr) do
    %{
      round_nr: round_nr,
      table: 0,
      advers: 0,
      colour: 0,
      result: 0,
      points: 0.0,
      played?: false
    }
  end

  # Splits `Pairing.result` (a combined FIDE code - "1-0", "1/2-1/2", ...)
  # back into ONE side's own SWAR result bitmask + point value - the exact
  # inverse of `SwarImport.combine_results/2`, split per side. "" (not
  # played yet) is bitmask 0, matching `result_class(0) == :none`.
  defp result_bits("1-0", true), do: {0x4000, 1.0}
  defp result_bits("1-0", false), do: {0x1000, 0.0}
  defp result_bits("0-1", true), do: {0x1000, 0.0}
  defp result_bits("0-1", false), do: {0x4000, 1.0}
  defp result_bits("1/2-1/2", _white?), do: {0x2000, 0.5}
  defp result_bits("1-0FF", true), do: {0x0004, 1.0}
  defp result_bits("1-0FF", false), do: {0x0001, 0.0}
  defp result_bits("0-1FF", true), do: {0x0001, 0.0}
  defp result_bits("0-1FF", false), do: {0x0004, 1.0}
  defp result_bits("0-0FF", _white?), do: {0x0008, 0.0}
  defp result_bits("0-0", _white?), do: {0x0400, 0.0}
  defp result_bits("1/2-0", true), do: {0x0200, 0.5}
  defp result_bits("1/2-0", false), do: {0x0100, 0.0}
  defp result_bits("0-1/2", true), do: {0x0100, 0.0}
  defp result_bits("0-1/2", false), do: {0x0200, 0.5}
  # Played but unrated. SWAR has no code for "played, not rated", so these
  # map onto their rated twins: the game and its points survive, the
  # unrated flag does not. Better than falling through to the catch-all
  # below, which would silently drop the points as well.
  defp result_bits("1-0U", true), do: {0x4000, 1.0}
  defp result_bits("1-0U", false), do: {0x1000, 0.0}
  defp result_bits("0-1U", true), do: {0x1000, 0.0}
  defp result_bits("0-1U", false), do: {0x4000, 1.0}
  defp result_bits("1/2-1/2U", _white?), do: {0x2000, 0.5}
  defp result_bits(_other, _white?), do: {0, 0.0}
end
