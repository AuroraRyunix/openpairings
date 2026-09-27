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
  with the exact source citations, is on `reverse_player/6`'s own
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

  ## Everything the import reads goes back

  Every setting `SwarImport` turns into a tournament setting is written
  back from that setting, and every SWAR setting this app has no place for
  travels in `Tournament.swar_settings` - kept by the import exactly as
  the file had it - and is written back from there. Where a SWAR value maps
  onto one of this app's in a way that cannot be undone (the chief
  arbiter's title, SWAR's exact tournament type, its cadence index, its
  tie-break list, its Belgian federation code, its FIDE-id block), the
  file's own value goes back while the tournament still says what the
  import made of it, and the tournament's own value otherwise. So a file
  imported and exported again comes back with what SWAR had in it, and a
  tournament imported from the export is the tournament that was exported
  (`test/pairings_engine/federations/bel/swar_round_trip_test.exs`).

  What the format cannot hold is listed by `export_notes/1`, one sentence
  each, beside the export button: SWAR keeps one exclusion rule where this
  app has a club rule, a federation rule and forbidden pairs (all of them
  are written as groups of player numbers when there is more than one),
  one "separate categories" switch for pairing and ranking both, one Elo
  per player, no soft pairing wishes, and so on. docs/swar-import.md,
  "Export: what the file holds", has the full table.
  """

  import Ecto.Query
  require Logger
  use Gettext, backend: PairingsEngineWeb.Gettext

  alias PairingsEngine.{Categories, Encoding, Exclusions, LateEntry, Repo, Standings, Tournaments}
  alias PairingsEngine.Federations.BEL.SwarImport
  alias PairingsEngine.Federations.BEL.SwarPublish
  alias PairingsEngine.Tournaments.Tournament

  # Table number sentinel for a pairing-allocated bye (Swar.h TABLE_BYE) -
  # mirrors `SwarImport`'s own `@table_bye`, kept as a second copy rather
  # than made public there: it is read-side vocabulary that export needs
  # too, not a shared concept worth coupling the two modules over.
  @table_bye 0x1000

  # Swar.h `TABLE_ABSENT`: the table number SWAR keeps for a round a player
  # was absent from - announced, or before they were added to the event
  # (`JoueurInit` in Joueur.cpp gives every round already paired this
  # table). SWAR pays such a round `AbsValue` under its two caps and counts
  # it towards `AbsNbFois` (`GetPoints`/`GetNbAbsence`, Utils.cpp) only by
  # this table number; every real file writes it with Advers -1, no result
  # and no colour.
  @table_absent 0x4000

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
    # Mint the SWAR identifier here if the tournament has none, and persist it.
    #
    # This file is how a tournament LEAVES for SWAR, and SWAR generates a guid
    # only when the field it reads is empty (`GenerateGUID()` in
    # `TournoiReadWrite.cpp` is guarded on exactly that). So whatever we write
    # here is the identity the tournament keeps for the rest of its life,
    # including when SWAR later uploads it to the federation.
    #
    # It used to fall back to a bare `Ecto.UUID.generate()`, which is wrong
    # twice over. It is not the shape the results site accepts - no club
    # prefix, no date, no braces - so an upload from SWAR would come back
    # "bad Guid date". And it was never stored, so exporting the same
    # tournament twice produced two different identities, which on a site that
    # overwrites by guid means two tournaments where there should be one.
    tournament = SwarPublish.ensure_guid!(Tournaments.get_tournament!(tournament_id))
    players = Tournaments.list_players(tournament_id)
    settings = tournament.swar_settings || %{}
    ni_by_player_id = assign_ni(players)

    # The rounds before a late entrant joined, when they count as absences
    # (`LateEntry`), join the round's real byes rows - written as the
    # absence SWAR itself keeps for a player added after rounds were paired.
    late = tournament |> LateEntry.absences() |> Enum.group_by(& &1.round)
    listed_rounds = Tournaments.list_rounds(tournament_id)

    rounds =
      Enum.map(listed_rounds, fn round ->
        pairings = get_pairings(round.id)

        byes =
          Tournaments.list_byes_for_round(tournament_id, round.number) ++
            Map.get(late, round.number, [])

        {round.number, pairings, byes}
      end)

    round_records =
      tournament
      |> build_round_records(players, rounds, ni_by_player_id)
      |> attach_round_xtra_points(
        tournament,
        Map.new(listed_rounds, &{&1.number, &1.virtual_points})
      )

    {axis1, axis2, cat_type} = category_axes_for_export(tournament)

    # Resolved here, where the tournament is still in scope, and threaded
    # down as a ready-made map rather than as the category list plus a
    # per-player lookup: SWAR has exactly one category slot per player, and
    # the thing that decides which of a player's categories fills it lives
    # in `PairingsEngine.Categories`, not in the writer.
    cat_index_by_player_id =
      Map.new(players, fn p ->
        pairing_cat = Categories.pairing_category(tournament, p)
        axis2_cat = if cat_type, do: Enum.find(p.categories || [], &(&1 in axis2)), else: nil
        {p.id, reverse_cat_index(pairing_cat, axis1, axis2_cat, axis2)}
      end)

    exclusion = exclusion_for_export(tournament, players, ni_by_player_id)

    w_str("v7.00") <>
      w_str(tournament.swar_guid) <>
      w_str(Map.get(settings, "mac") || "") <>
      reverse_tournoi(tournament, settings) <>
      reverse_dates(tournament) <>
      reverse_tie_break(tournament, settings) <>
      reverse_exclusion(exclusion) <>
      reverse_categories(axis1, axis2, category_type(cat_type, axis1, settings)) <>
      reverse_xtra_points(tournament, settings) <>
      reverse_joueurs(tournament, players, cat_index_by_player_id, ni_by_player_id, round_records)
  end

  @doc """
  What a `.swar` export of `tournament` cannot carry, one sentence each for
  the organiser, shown beside the export button - `[]` when the file holds
  the tournament whole. SWAR has one exclusion rule, one Elo per player,
  one "separate categories" switch for both pairing and ranking, no soft
  pairing wishes, and so on; each sentence says what SWAR will do instead.
  """
  def export_notes(%Tournament{} = tournament) do
    players = Tournaments.list_players(tournament.id)
    results = tournament_results(tournament.id)
    ni_by_player_id = assign_ni(players)
    {_type, _values, exclusion_notes} = exclusion_for_export(tournament, players, ni_by_player_id)

    exclusion_notes ++
      system_notes(tournament) ++
      scoring_notes(tournament, players) ++
      category_notes(tournament) ++
      tiebreak_notes(tournament) ++
      player_notes(tournament, players) ++
      result_notes(results)
  end

  # Splits `tournament.categories` back into the two axes SWAR reads it as,
  # when it can: `swar_category_type` (3 or 4) is set only when the
  # tournament's categories came from a two-axis SWAR import
  # (`SwarImport.map_categories/1`), and `swar_category_axis2` names which
  # of `categories` is axis 2 - `categories -- swar_category_axis2`, in
  # order, is axis 1. Anything else (a plain OpenPairings-authored list, or
  # a single-axis import) exports as a single axis, exactly as before.
  defp category_axes_for_export(%{
         categories: categories,
         swar_category_type: t,
         swar_category_axis2: axis2
       })
       when t in [3, 4] and axis2 != [] do
    axis2 = axis2 |> Enum.filter(&(&1 in categories)) |> Enum.take(16)
    axis1 = (categories -- axis2) |> Enum.take(16)
    {axis1, axis2, t}
  end

  defp category_axes_for_export(tournament) do
    {tournament.categories |> Enum.take(16), [], nil}
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

  # Every field SWAR's `[TOURNOI]` holds, from the tournament - and, for the
  # ones OpenPairings has no setting for, from `swar_settings`: the values
  # the file this tournament was imported from had (`SwarImport.
  # swar_settings/1`), or SWAR's own defaults for a tournament that never
  # came from SWAR. Where a setting maps onto one of this app's in a way
  # that loses something (the chief arbiter's title, SWAR's exact type,
  # its cadence index), the file's own value is written back as long as
  # the tournament still says the same thing - `settings_value/4`.
  defp reverse_tournoi(t, settings) do
    {n_fide_ids, n_strings} = @tournoi_layout
    {cadence, cadence_other} = reverse_cadence(t, settings)
    type = reverse_tournament_type(t, settings)

    w_str("[TOURNOI]") <>
      w_str(t.name) <>
      w_str(t.organizer) <>
      w_str(t.organizer_club_number) <>
      w_str(t.city) <>
      w_str(reverse_arbiter1(t, settings)) <>
      w_str(t.deputy_arbiter) <>
      w_str(swar_date(t.start_date)) <>
      w_str(swar_date(t.end_date)) <>
      w_i32(cadence) <>
      w_str(cadence_other) <>
      w_i32(t.rounds_count) <>
      w_i32(setting(settings, "frbe_from", 0)) <>
      w_i32(setting(settings, "frbe_to", 0)) <>
      w_i32(setting(settings, "fide_from", 0)) <>
      w_i32(setting(settings, "fide_to", 0)) <>
      w_i32(cat_separes(t, settings)) <>
      w_i32(setting(settings, "elo_ou_pays", 1)) <>
      w_i32(if t.fide_homologated, do: 1, else: 0) <>
      w_n(reverse_fide_ids(t, settings, n_fide_ids), fn [de, aa, id] ->
        w_i32(de) <> w_i32(aa) <> w_i32(id)
      end) <>
      w_n(reverse_tournoi_tail_strings(settings, n_strings), &w_str/1) <>
      w_i32(type) <>
      w_i32(setting(settings, "sw_elo_r1", 1)) <>
      w_i32(setting(settings, "sw_amer_presence", 0)) <>
      w_i32(setting(settings, "plusieurs", 0)) <>
      w_i32(setting(settings, "first_table", 1)) <>
      w_n(reverse_sw321(t, settings, type), &w_i32/1) <>
      w_i32(setting(settings, "elo_used", 1)) <>
      w_i32(reverse_standard(t.standard)) <>
      w_i32(setting(settings, "tb_personel", 0)) <>
      w_i32(reverse_appar_order(t, settings)) <>
      w_i32(setting(settings, "elo_equal", 0)) <>
      w_i32(reverse_bye_value(t, settings, type)) <>
      w_u8(if (t.abs_value || 0.0) > 0, do: 1, else: 0) <>
      w_u8(abs_cap(t, t.abs_nbfois)) <>
      w_u8(abs_cap(t, t.abs_jusque)) <>
      w_u8(0) <>
      w_i32(setting(settings, "ff_value", 2)) <>
      w_i32(reverse_federation(t.federation, settings))
  end

  # A `swar_settings` value that is an integer, or `default`.
  defp setting(settings, key, default) do
    case Map.get(settings, key) do
      v when is_integer(v) -> v
      _ -> default
    end
  end

  # SWAR keeps dates as "dd/mm/yyyy" (`Swar.h`: `DateDebut; // jj/mm/aaaa`);
  # this app keeps them ISO. A date that is not ISO goes out as it is.
  @doc false
  def swar_date(date) when is_binary(date) do
    case String.split(date, "-") do
      [y, m, d] when byte_size(y) == 4 -> "#{d}/#{m}/#{y}"
      _ -> date
    end
  end

  def swar_date(_date), do: ""

  # The chief arbiter as SWAR wrote them, title and all ("IA Luc Cornet"),
  # while the name here is still the one the import took from it - the
  # import drops the title, and may put a FIDE-matched name in its place.
  defp reverse_arbiter1(t, settings) do
    raw = Map.get(settings, "arbiter1")

    if is_binary(raw) and SwarImport.strip_arbiter_title(raw) == t.chief_arbiter,
      do: raw,
      else: t.chief_arbiter
  end

  # `Cadence` is a 0-based index into a dropdown SWAR fills at runtime from
  # `t.standard` (see `SwarImport.cadence_label/2`) - reversing it means
  # finding which index THAT dropdown would show `t.rate_of_play` at. -1
  # (SWAR's own "custom" sentinel - verified against `cadence_label/2`
  # returning `nil` for any cadence outside its known table) falls back to
  # writing `t.rate_of_play` as free text in `Cadence_Other` instead. The
  # file's own index and text go back while they still read as
  # `rate_of_play` - the "other cadence" entry is the last of SWAR's list,
  # which `cadence_label/2` leaves out, so the index alone does not say which
  # it was.
  defp reverse_cadence(t, settings) do
    raw = Map.get(settings, "cadence")
    raw_other = Map.get(settings, "cadence_other") || ""

    if is_integer(raw) and
         (SwarImport.cadence_label(reverse_standard(t.standard), raw) || raw_other) ==
           t.rate_of_play do
      {raw, raw_other}
    else
      case Enum.find(
             0..30,
             &(SwarImport.cadence_label(reverse_standard(t.standard), &1) == t.rate_of_play)
           ) do
        nil -> {-1, t.rate_of_play}
        index -> {index, ""}
      end
    end
  end

  # v7_strings folds arbiter-1/arbiter-2/remarks into ONE trailing string
  # (see `@tournoi_layout`) - `SwarImport.parse_tournoi/3` reads a
  # single-element list back as `{"", "", remarks}`. That string is SWAR's
  # "FIDE remarks", written back from the imported file; SWAR's two FIDE
  # arbiter fields have no place in this layout.
  defp reverse_tournoi_tail_strings(settings, 1), do: [Map.get(settings, "fide_remarks") || ""]

  defp reverse_tournoi_tail_strings(settings, 4),
    do: [
      Map.get(settings, "fide_arb1") || "",
      Map.get(settings, "fide_arb2") || "",
      "",
      Map.get(settings, "fide_remarks") || ""
    ]

  # SWAR's per-round FIDE tournament ids (`FideIdDe`/`FideIdAA`/`FideIdId`,
  # sixteen of them) - `fide_id_ranges` here. The imported block goes back
  # as it was while the tournament still derives the same ranges and event
  # code from it (an id with no usable round range is kept in `event_code`
  # only, and would otherwise be lost); anything else is rebuilt from
  # `fide_id_ranges`, then any id `event_code` names that no range carries,
  # with no rounds.
  defp reverse_fide_ids(t, settings, n) do
    raw = Map.get(settings, "fide_ids")

    entries =
      if is_list(raw) and raw != [] and raw_fide_ids_current?(t, raw) do
        raw
      else
        ranges =
          Enum.flat_map(t.fide_id_ranges || [], fn r ->
            case Integer.parse(to_string(r["fide_tournament_id"])) do
              {id, ""} -> [[r["from_round"], r["to_round"], id]]
              _ -> []
            end
          end)

        in_ranges = MapSet.new(ranges, fn [_, _, id] -> id end)

        extra =
          (t.event_code || "")
          |> String.split(",")
          |> Enum.flat_map(fn part ->
            case Integer.parse(String.trim(part)) do
              {id, ""} when id > 0 -> [id]
              _ -> []
            end
          end)
          |> Enum.reject(&MapSet.member?(in_ranges, &1))
          |> Enum.uniq()
          |> Enum.map(&[0, 0, &1])

        ranges ++ extra
      end

    entries
    |> Enum.filter(
      &match?([de, aa, id] when is_integer(de) and is_integer(aa) and is_integer(id), &1)
    )
    |> Enum.take(n)
    |> then(&(&1 ++ List.duplicate([0, 0, 0], n - length(&1))))
  end

  defp raw_fide_ids_current?(t, raw) do
    ids =
      raw |> Enum.map(fn [_, _, id] -> id end) |> Enum.reject(&(&1 in [0, nil])) |> Enum.uniq()

    event_code = Enum.map_join(ids, ", ", &to_string/1)

    ranges =
      raw
      |> Enum.filter(fn [de, aa, id] -> id > 0 and de >= 1 and aa >= de end)
      |> Enum.sort_by(fn [de, _, _] -> de end)
      |> Enum.reduce([], fn [de, aa, id], acc ->
        case acc do
          [%{"to_round" => prev_aa} | _] when de <= prev_aa ->
            acc

          _ ->
            [%{"fide_tournament_id" => to_string(id), "from_round" => de, "to_round" => aa} | acc]
        end
      end)
      |> Enum.reverse()

    event_code == (t.event_code || "") and ranges == (t.fide_id_ranges || [])
  end

  # SWAR's `TOURNOI_TYPE`: SWISS 0, SWISS_DBL 1, SWISS_ACC 2, SWISS_321 3,
  # ROBIN 4, ROBIN_DBL 5, ROBIN_AR 6, SW_AMERICAIN 7, SW_AMERICAIN_DBL 8.
  #
  # From the tournament: a round robin is 4, 5 in match format (each
  # pairing twice in a row), 6 as a double round robin; a Swiss is 1 in
  # match format and 3 - SWAR's "3-2-1", the one type with its own point
  # values - when it scores other than 1/½/0 with a full-point bye (SWAR
  # scores every other type that way). A team tournament has no SWAR type
  # and goes as the individual one; Keizer as a Swiss. A tournament that
  # came from SWAR keeps the file's own type while it still reads the same
  # here: an accelerated Swiss (2) is an ordinary Swiss in this app.
  defp reverse_tournament_type(t, settings) do
    derived = derived_tournament_type(t)
    raw = Map.get(settings, "type")

    if raw in 0..8 and imported_type(raw, t) == derived, do: raw, else: derived
  end

  defp derived_tournament_type(t) do
    cond do
      round_robin?(t) and t.rr_match_format -> 5
      round_robin?(t) and t.rr_cycles == 2 -> 6
      round_robin?(t) -> 4
      t.swiss_match_format -> 1
      custom_points?(t) -> 3
      true -> 0
    end
  end

  # The type `SwarImport` turns `raw` into, in this function's terms: an
  # accelerated Swiss is a plain one, and an American one (which this app
  # does not have) too.
  defp imported_type(2, _t), do: 0
  defp imported_type(raw, _t) when raw in [7, 8], do: 0
  defp imported_type(1, t), do: if(t.swiss_match_format, do: 1, else: 0)
  defp imported_type(raw, _t), do: raw

  defp round_robin?(t),
    do: t.pairing_system == "round_robin" or t.type in ["roundrobin", "team-roundrobin"]

  # Anything but SWAR's fixed scoring: 1 / ½ / 0, and a pairing-allocated
  # bye worth a point (a round robin's forced one included).
  defp custom_points?(t) do
    t.points_win != 1.0 or t.points_draw != 0.5 or t.points_loss != 0.0 or
      (t.presence_value || 0.0) != 0.0
  end

  # `SW321_Win/Nul/Los/Bye/Pre/PreBye`, SWAR's own point values - which it
  # reads only for its 3-2-1 type. For that type they are the tournament's;
  # for any other, the imported file's own (whatever SWAR had there),
  # else the fixed scoring they would stand for.
  defp reverse_sw321(t, settings, type) do
    case Map.get(settings, "sw321") do
      [_, _, _, _, _, _] = raw when type != 3 ->
        Enum.map(raw, &(&1 || 0))

      _ ->
        [
          round(t.points_win * 4),
          round(t.points_draw * 4),
          round(t.points_loss * 4),
          round((t.bye_value || 0.0) * 4),
          round((t.presence_value || 0.0) * 4),
          if(t.presence_on_allocated_bye, do: 1, else: 0)
        ]
    end
  end

  # `ApparOrder` - "Couleur du Nr.1 à la première ronde" (`TOptions.cpp`):
  # the colour the top seed has in round 1, 0 white, 1 black, 2 drawn at
  # random. That is the initial colour here (C.04.3 Article 5.1). A drawn
  # lot goes as the colour it drew; one not drawn yet as SWAR's own random.
  # A round robin's `ApparOrder` means something else in SWAR (how the
  # table is seeded) and goes back as the file had it.
  defp reverse_appar_order(t, settings) do
    if round_robin?(t) do
      setting(settings, "appar_order", 0)
    else
      case Tournament.effective_initial_colour(t) do
        "white" -> 0
        "black" -> 1
        nil -> 2
      end
    end
  end

  defp reverse_standard("standard"), do: 0
  defp reverse_standard("rapid"), do: 1
  defp reverse_standard("blitz"), do: 2
  defp reverse_standard(_), do: 0

  # SWAR's `CatSepares`. Without categories it means nothing either way, and
  # the imported file's own value goes back; with them, it is on when this
  # tournament pairs or ranks its categories separately.
  defp cat_separes(t, settings) do
    cond do
      t.categories_enabled and (t.categories || []) != [] ->
        if separate_categories?(t), do: 1, else: 0

      Map.get(settings, "cat_separes") in [0, 1] ->
        Map.get(settings, "cat_separes")

      true ->
        0
    end
  end

  defp separate_categories?(t) do
    Standings.ranked_separately?(t) or
      (t.pair_by_category and t.categories_enabled and (t.categories || []) != [])
  end

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

  # SWAR's `ByeValue`: 0 a full point, 1 half, 2 nothing (`USE_POINTS`).
  # A round robin's is forced to a full point on load in SWAR and on import
  # here (`SwarImport.scoring_attrs/1`), so its file's own byte goes back
  # as it was; so does a 3-2-1 event's, whose bye is `SW321_Bye` instead.
  # Anything else is the tournament's.
  defp reverse_bye_value(t, settings, type) do
    raw = Map.get(settings, "bye_value")

    cond do
      raw in [0, 1, 2] and type == 3 -> raw
      raw in [0, 1, 2] and round_robin?(t) and t.bye_value == 1.0 -> raw
      raw in [0, 1, 2] and bye_points(raw) == t.bye_value -> raw
      true -> bye_value_code(t.bye_value)
    end
  end

  defp bye_points(0), do: 1.0
  defp bye_points(1), do: 0.5
  defp bye_points(2), do: 0.0

  defp bye_value_code(1.0), do: 0
  defp bye_value_code(0.5), do: 1
  defp bye_value_code(v) when v == 0.0, do: 2
  defp bye_value_code(_), do: 0

  # Belgian sub-federation codes 1-6 all collapse to the single FIDE
  # country code "BEL" on import (`normalize_federation/1`) - which ONE
  # organized the tournament is kept in `swar_settings` and goes back while
  # the tournament is still Belgian. Otherwise 2 (KBSB, the national
  # federation itself) is the documented choice for "BEL"; any other value
  # (a real FIDE country code, or "") has no SWAR federation-code equivalent
  # at all - that field means "which Belgian entity", not "which country" -
  # so it becomes 0 ("none selected").
  defp reverse_federation(federation, settings) do
    case {federation, Map.get(settings, "federation")} do
      {"BEL", raw} when raw in 1..6 -> raw
      {"BEL", _} -> 2
      _ -> 0
    end
  end

  ## ---------- [DATES] ----------

  defp reverse_dates(t) do
    dates = t.round_dates || []
    padded = dates ++ List.duplicate("", max(t.rounds_count - length(dates), 0))
    w_str("[DATES]") <> w_n(Enum.take(padded, t.rounds_count), &w_str(swar_date(&1)))
  end

  ## ---------- [TIE_BREAK] ----------

  # SWAR's `DEPARTAGES` for each of this app's codes it has - the inverse of
  # `SwarImport`'s `@tiebreak_codes`. SWAR has five slots.
  @tiebreak_reverse %{
    "BH" => 1,
    "MBH" => 2,
    "BHC1" => 4,
    "BHC2" => 5,
    "SB" => 6,
    "PS" => 7,
    "DE" => 8,
    "KS" => 9,
    "WIN" => 10,
    "ARO" => 12,
    "AROC1" => 13,
    "BPG" => 14
  }

  @doc false
  def tiebreak_reverse, do: @tiebreak_reverse

  # The imported file's own list goes back while the tournament still ranks
  # by what the import made of it - which keeps SWAR's median-2, performance
  # and black-wins criteria (no counterpart here, left out on import) in
  # their places. Otherwise the tournament's list, each code SWAR has, in
  # order, up to five.
  defp reverse_tie_break(t, settings) do
    raw = Map.get(settings, "tiebreaks")

    codes =
      if is_list(raw) and length(raw) == 5 and Enum.all?(raw, &is_integer/1) and
           SwarImport.map_tiebreaks(raw) == (t.tiebreaks || []) do
        raw
      else
        (t.tiebreaks || [])
        |> Enum.map(&Map.get(@tiebreak_reverse, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.take(5)
      end

    padded = codes ++ List.duplicate(0, max(5 - length(codes), 0))
    w_str("[TIE_BREAK]") <> w_n(Enum.take(padded, 5), &w_i32/1)
  end

  ## ---------- [EXCLUSION] ----------

  defp reverse_exclusion({type, values, _notes}),
    do: w_str("[EXCLUSION]") <> w_i32(type) <> w_str(values)

  # SWAR's `USE_EXCLUSION` holds ONE rule (`Swar.h`; what each means is in
  # `SwarImport`'s `[EXCLUSION]` section): -1 none, 0 groups of player
  # numbers whose members never meet ("1,4:12,15,21"), 1 listed club
  # numbers ("618:621"), 2 listed nationalities ("BEL:FRA"), 3 every club,
  # 4 every nationality. This app holds a club rule, a federation rule and
  # forbidden pairs, any of them at once. Returns `{type, values, notes}`,
  # `notes` being what the export screen tells the organiser
  # (`export_notes/1`):
  #
  #   * one rule alone goes as SWAR's own rule - the club rule only where
  #     SWAR's club NUMBERS keep exactly the players apart that this app's
  #     club NAMES do (SWAR groups by number, `BuildAllClub`);
  #   * forbidden pairs alone go as groups of two;
  #   * anything else - two rules, a rule and pairs, or a club rule the
  #     numbers cannot express - goes as groups of player numbers (0) that
  #     keep exactly the same players apart as the rules do now. A player
  #     added in SWAR afterwards is in no group.
  #
  # Soft pairs and the soft club rule have no place in SWAR at all.
  defp exclusion_for_export(t, players, ni_by_player_id) do
    forbidden = Tournaments.list_forbidden_pairings(t.id)
    {soft, hard} = Enum.split_with(forbidden, & &1.soft)
    by_id = Map.new(players, &{&1.id, &1})

    hard_pairs =
      hard
      |> Enum.flat_map(fn f ->
        case {by_id[f.player_a_id], by_id[f.player_b_id]} do
          {%{} = a, %{} = b} -> [{a, b}]
          _ -> []
        end
      end)

    club = if t.club_exclusion in ["all", "listed"], do: [:club], else: []
    fed = if t.fed_exclusion in ["all", "listed"], do: [:fed], else: []

    soft_notes =
      if soft != [] or (t.soft_club_rounds || 0) > 0 do
        [
          gettext(
            "SWAR has no soft pairing wishes: the pairs to avoid if possible, and the wish to keep clubmates apart in the first rounds, are not in the file."
          )
        ]
      else
        []
      end

    {type, values, notes} =
      case {club ++ fed, hard_pairs} do
        {[], []} ->
          {-1, "", []}

        {[], pairs} ->
          {0, pairs_value(pairs, ni_by_player_id), []}

        {[:club], []} ->
          club_rule(t, players, ni_by_player_id)

        {[:fed], []} ->
          fed_rule(t)

        {_rules, pairs} ->
          groups =
            rule_groups(t, players) ++ Enum.map(pairs, fn {a, b} -> [a, b] end)

          {0, groups_value(groups, ni_by_player_id),
           [
             gettext(
               "SWAR keeps one exclusion rule, and this tournament has more than one (club, federation or forbidden pairs). They are written as groups of player numbers whose members never meet, which keep exactly the same players apart - but a player added in SWAR later is in no group, and re-importing the file brings them back as forbidden pairs, not as club or federation rules."
             )
           ]}
      end

    {type, values, notes ++ soft_notes}
  end

  # The club rule on its own: SWAR's 3 (every club) or 1 (these club
  # numbers) when its grouping by club NUMBER keeps apart the same players as
  # this app's grouping by club NAME; groups of player numbers otherwise.
  defp club_rule(t, players, ni_by_player_id) do
    ours = club_name_groups(t, players)

    {type, numbers} =
      case t.club_exclusion do
        "all" ->
          {3, nil}

        "listed" ->
          {1,
           ours
           |> List.flatten()
           |> Enum.map(& &1.club_number)
           |> Enum.reject(&is_nil/1)
           |> Enum.uniq()
           |> Enum.sort()}
      end

    swar =
      players
      |> Enum.filter(&(is_nil(numbers) or &1.club_number in numbers))
      |> Enum.group_by(&(&1.club_number || 0))
      |> Map.values()
      |> Enum.filter(&(length(&1) >= 2))

    if as_sets(swar) == as_sets(ours) do
      {type, if(numbers, do: Enum.join(numbers, ":"), else: ""), []}
    else
      {0, groups_value(ours, ni_by_player_id),
       [
         gettext(
           "SWAR keeps clubmates apart by club number, and here the club numbers do not match the club names for every player (a club without a number, or one number for two names). The club rule is written as groups of player numbers whose members never meet, which keep exactly the same players apart - but a player added in SWAR later is in no group, and re-importing the file brings them back as forbidden pairs."
         )
       ]}
    end
  end

  # The federation rule on its own: SWAR's 4 (every nationality) or 2 (these
  # nationalities). SWAR v6.65 does not apply 4 at all (`BuildAllNat` is
  # empty - docs/swar-source-audit-2026-09-09.md, F2): the file says what
  # the tournament wants, and the note says SWAR will not do it.
  defp fed_rule(%{fed_exclusion: "all"}) do
    {4, "",
     [
       gettext(
         "The rule keeping players of the same federation apart is written as SWAR's own \"every nationality\" rule - which SWAR 6.65 does not apply (a known SWAR defect). If the tournament is continued in SWAR, check its pairings for compatriots."
       )
     ]}
  end

  defp fed_rule(t) do
    codes = t.fed_exclusion_list |> Exclusions.normalize_list() |> Enum.map(&String.upcase/1)
    {2, Enum.join(codes, ":"), []}
  end

  # The groups the club and federation rules keep apart now, as lists of
  # players.
  defp rule_groups(t, players) do
    club = if t.club_exclusion in ["all", "listed"], do: club_name_groups(t, players), else: []

    fed =
      if t.fed_exclusion in ["all", "listed"],
        do: value_groups(players, & &1.federation, t.fed_exclusion, t.fed_exclusion_list),
        else: []

    club ++ fed
  end

  defp club_name_groups(t, players),
    do: value_groups(players, & &1.club, t.club_exclusion, t.club_exclusion_list)

  # `PairingsEngine.Exclusions`' own grouping: trimmed, case-insensitive,
  # blank never a group; "listed" keeps the listed values only.
  defp value_groups(players, field, mode, list) do
    allowed = list |> Exclusions.normalize_list() |> MapSet.new(&String.downcase/1)

    players
    |> Enum.group_by(&(&1 |> field.() |> to_string() |> String.trim() |> String.downcase()))
    |> Enum.reject(fn {value, _} -> value == "" end)
    |> Enum.filter(fn {value, _} -> mode == "all" or MapSet.member?(allowed, value) end)
    |> Enum.map(fn {_value, group} -> group end)
    |> Enum.filter(&(length(&1) >= 2))
  end

  defp as_sets(groups), do: MapSet.new(groups, fn g -> MapSet.new(g, & &1.id) end)

  # "1,4:12,15,21" - `ImplodeValues1`'s shape, player numbers (NI), in a
  # fixed order so the same rules always write the same file.
  defp groups_value(groups, ni_by_player_id) do
    groups
    |> Enum.map(fn group ->
      group |> Enum.map(&Map.fetch!(ni_by_player_id, &1.id)) |> Enum.uniq() |> Enum.sort()
    end)
    |> Enum.filter(&(length(&1) >= 2))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map_join(":", &Enum.join(&1, ","))
  end

  # Forbidden pairs as SWAR's groups: every pair within a group never meets,
  # so pairs that form a group ("1,2,3" imported as 1-2, 1-3, 2-3) go back
  # as that group - each group grown from its first pair by every player
  # forbidden against all of it, so no group forbids a pair that was not.
  defp pairs_value(pairs, ni_by_player_id) do
    edges =
      pairs
      |> Enum.map(fn {a, b} ->
        [x, y] = Enum.sort([Map.fetch!(ni_by_player_id, a.id), Map.fetch!(ni_by_player_id, b.id)])
        {x, y}
      end)
      |> MapSet.new()

    adjacent? = fn x, y -> MapSet.member?(edges, {min(x, y), max(x, y)}) end
    vertices = edges |> Enum.flat_map(&Tuple.to_list/1) |> Enum.uniq() |> Enum.sort()

    {groups, _covered} =
      edges
      |> Enum.sort()
      |> Enum.reduce({[], MapSet.new()}, fn {x, y} = edge, {groups, covered} ->
        if MapSet.member?(covered, edge) do
          {groups, covered}
        else
          group =
            Enum.reduce(vertices, [x, y], fn v, group ->
              if v in group or not Enum.all?(group, &adjacent?.(&1, v)),
                do: group,
                else: group ++ [v]
            end)
            |> Enum.sort()

          covered =
            for(a <- group, b <- group, a < b, into: covered, do: {a, b})

          {[group | groups], covered}
        end
      end)

    groups
    |> Enum.reverse()
    |> Enum.map_join(":", &Enum.join(&1, ","))
  end

  ## ---------- [CATEGORIES] ----------

  # `axis1`/`axis2` line up 0-based against `reverse_cat_index/4`'s
  # `(idx + 1) * 100` (axis 1) and `idx + 1` (axis 2) encoding, and against
  # `SwarImport.category_axes/2`'s decode of the same - no leading blank
  # slot on either list. An earlier version prepended `""` to `value1` to
  # mimic SWAR's own implicit slot-0 "+bound" bucket, which looked plausible
  # on its own but never agreed with how a `CatIndex` this module writes
  # actually decodes: encoding `categories[0]` as `100` and then decoding
  # `100` against `["", categories[0], ...]` resolves to the blank, not
  # `categories[0]` - an export/reimport round trip silently lost every
  # player's category. There was no test that reimported an export and
  # resolved the name, only one that checked the raw `value1` shape, which
  # is how it survived. Fixed alongside two-axis import/export; see
  # docs/swar-import.md.
  defp reverse_categories(axis1, axis2, type) do
    value1 = axis1 |> pad_strings(17)
    value2 = axis2 |> pad_strings(17)

    w_str("[CATEGORIES]") <>
      w_i32(type) <>
      w_n(value1, &w_str/1) <>
      w_n(value2, &w_str/1)
  end

  # SWAR's `Categorie` type: the two-axis type a two-axis import kept, 0 for
  # no categories, and otherwise the single-axis type the imported file had
  # (1 rating, 2 age, 5 names) - or 5, names, for categories made here: they
  # are names a player is given, which is what SWAR's type 5 is.
  defp category_type(two_axis, _axis1, _settings) when two_axis in [3, 4], do: two_axis

  # No categories: the imported file's type still goes back (a SWAR file can
  # name a type and leave its lists empty), else SWAR's "none".
  defp category_type(_two_axis, [], settings) do
    case Map.get(settings, "category_type") do
      raw when raw in 0..5 -> raw
      _ -> 0
    end
  end

  defp category_type(_two_axis, _axis1, settings) do
    case Map.get(settings, "category_type") do
      raw when raw in [1, 2, 5] -> raw
      _ -> 5
    end
  end

  defp pad_strings(list, n) when length(list) >= n, do: Enum.take(list, n)
  defp pad_strings(list, n), do: list ++ List.duplicate("", n - length(list))

  ## ---------- [XTRA_POINTS] ----------

  # SWAR's own Elo-band extra-points table: four `(points x 4, Elo)` bands,
  # a player at or above a band's Elo getting its points (`XtraPoints.cpp`,
  # `AssignExtraPoints`). Acceleration mode's bands are the same rule
  # (`Tournament.band_extra_points/3`), so they are written from
  # `extra_points_bands`: highest Elo first, as SWAR sorts them
  # (`SortXtraPoints`), at most four. A handicap's bands pay players BELOW a
  # rating and do not convert; there, and in acceleration mode with no bands
  # of its own, the imported file's table goes back as it was, and a
  # tournament that never came from SWAR has four empty bands. The players'
  # own extra points are in `[JOUEURS]` either way.
  defp reverse_xtra_points(tournament, settings) do
    bands =
      case acceleration_bands(tournament) do
        [] -> imported_xtra_points(settings)
        bands -> bands
      end

    bands = bands ++ List.duplicate([0, 0], 4 - length(bands))
    w_str("[XTRA_POINTS]") <> w_n(bands, fn [pts, elo] -> w_i32(pts) <> w_i32(elo) end)
  end

  defp acceleration_bands(tournament) do
    with true <- Tournament.extra_points_acceleration?(tournament),
         {:ok, bands} <- Tournament.parse_extra_points_bands(tournament.extra_points_bands) do
      bands
      |> Enum.sort_by(fn {threshold, _bonus} -> -threshold end)
      |> Enum.take(4)
      |> Enum.map(fn {threshold, bonus} -> [round(bonus * 4), threshold] end)
    else
      _ -> []
    end
  end

  defp imported_xtra_points(settings) do
    case Map.get(settings, "xtra_points") do
      list when is_list(list) ->
        list
        |> Enum.filter(&match?([p, e] when is_integer(p) and is_integer(e), &1))
        |> Enum.take(4)

      _ ->
        []
    end
  end

  ## ---------- [JOUEURS] ----------

  # SWAR's own internal player number (`NI`) is written as `pairing_number`.
  # `NI` means nothing in a file but "the player a [RONDE] record's opponent
  # number points at", and the import reads it only for that - it numbers
  # players by SWAR's seed order (`SwarImport.prepare_players/1`) - so a
  # file that went through here comes back to SWAR with the same players
  # under their seed numbers.
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
  # Unlike `Class` (see `reverse_player/6`'s own comment), `Rank` is NOT
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
  #
  # That sort is for players this tournament has not numbered yet. Once
  # pairing numbers exist they ARE the seed - this app's starting ranks,
  # handed out by rating when round 1 was paired and frozen since (C.04.2.B),
  # late entrants after them; for a SWAR import, SWAR's own seed order
  # (`SwarImport.prepare_players/1`) - so Rank follows them, and a
  # tournament continued in SWAR orders its players, and numbers a round
  # robin's Berger table, the way it was being paired here. Players without
  # a number come after the numbered ones.
  defp assign_ranks(players) do
    {numbered, unnumbered} = Enum.split_with(players, & &1.pairing_number)

    (Enum.sort_by(numbered, & &1.pairing_number) ++
       Enum.sort_by(unnumbered, &{-(&1.fide_rating || 0), -reverse_title(&1.title), &1.name}))
    |> Enum.with_index(1)
    |> Map.new(fn {p, i} -> {p.id, i} end)
  end

  defp reverse_joueurs(
         tournament,
         players,
         cat_index_by_player_id,
         ni_by_player_id,
         round_records
       ) do
    rank_by_player_id = assign_ranks(players)
    # In player-number order, as SWAR lists them - and so the same tournament
    # always writes the same file, whatever order the roster query returns.
    players = Enum.sort_by(players, &Map.fetch!(ni_by_player_id, &1.id))

    w_str("[JOUEURS]") <>
      w_i32(length(players)) <>
      w_n(
        players,
        &reverse_player(
          tournament,
          &1,
          cat_index_by_player_id,
          ni_by_player_id,
          rank_by_player_id,
          round_records
        )
      )
  end

  defp reverse_player(
         tournament,
         p,
         cat_index_by_player_id,
         ni_by_player_id,
         rank_by_player_id,
         round_records
       ) do
    ni = Map.fetch!(ni_by_player_id, p.id)
    rank = Map.fetch!(rank_by_player_id, p.id)
    rounds = Map.get(round_records, p.id, [])
    nb_parties = Enum.count(rounds, & &1.played?)
    # SWAR's `Points` are quarter points (the import divides by 4 - see
    # docs/swar-import.md on the c-reeks anchor). This wrote half points.
    # SWAR recomputes them before it shows or pairs anything, so only a
    # reader of the raw file ever saw the difference.
    points_x4 = round(Enum.sum(Enum.map(rounds, & &1.points)) * 4)

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
      w_i32(Map.fetch!(cat_index_by_player_id, p.id)) <>
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
      w_i32(points_x4) <>
      w_i32(0) <>
      w_n(1..5, fn _ -> w_i32(0) end) <>
      w_i32(0) <>
      w_i32(reverse_paid(p.paid)) <>
      w_i32(reverse_absent_code(p)) <>
      w_str(p.absent_rounds || "") <>
      w_i32(reverse_extra_points(tournament, p)) <>
      w_i32(0) <>
      w_i16(length(rounds)) <>
      w_i16(reverse_handy_table(p)) <>
      w_str("[RONDE]") <>
      w_n(rounds, &reverse_round/1)
  end

  # SWAR counts `ExtraPts` in every Swiss standings, always
  # (`CalculLeClassement`), and pairs with them (`EcrireXXA_AccelereManuel`).
  # A handicap's points go into the file only while the tournament counts
  # them - otherwise SWAR would rank and pair on points this tournament does
  # not. Acceleration points always go: they are what the pairing is built
  # on, which is what SWAR uses them for, and `export_notes/1` says so when
  # this tournament keeps them out of its standings. Never for a round robin
  # or a 3-2-1 event, whose extra points SWAR throws away on load. Quarter
  # points, as SWAR stores them.
  defp reverse_extra_points(tournament, p) do
    if extra_points_exported?(tournament),
      do: round((p.extra_points || 0.0) * 4),
      else: 0
  end

  defp extra_points_exported?(t),
    do:
      (t.count_extra_points or Tournament.extra_points_acceleration?(t)) and
        extra_points_type?(t)

  defp extra_points_type?(t), do: not round_robin?(t) and derived_tournament_type(t) != 3

  # Each round's `XtraPts`: the extra points the player was paired with in
  # that round (`rounds.virtual_points`), which SWAR's next `XXA` history
  # reads back. Zero where the round recorded none, and for the types SWAR
  # discards extra points for. Done over the finished records rather than
  # inside `round_record_for/5`, so the round records themselves stay what
  # they were.
  defp attach_round_xtra_points(round_records, tournament, virtual_by_round) do
    if extra_points_type?(tournament) do
      Map.new(round_records, fn {player_id, records} ->
        key = to_string(player_id)

        {player_id,
         Enum.map(records, fn record ->
           points = virtual_by_round |> Map.get(record.round_nr) |> Kernel.||(%{}) |> Map.get(key)
           Map.put(record, :xtra, round((points || 0.0) * 4))
         end)}
      end)
    else
      round_records
    end
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

  # SWAR carries ONE signed 32-bit category index per player and has no
  # second slot, so what goes here is the pairing category - never a tag
  # list. The caller resolves that (`Categories.pairing_category/2`), and
  # this guard is here because getting it wrong would have been silent: the
  # fallthrough below is `Enum.find_index/2`, a list argument matches no
  # name, `nil -> 0`, and every player in the file exports as uncategorised
  # with no crash and no warning. A tournament's whole category assignment
  # gone, and nothing on screen to say so. Raising is the correct failure for
  # a caller that hands this the wrong shape.
  @doc false
  # Public only so the guard can be tested directly. It is the one failure in
  # this module that would have been completely silent, so a raise nobody has
  # ever watched fire is not enough.
  def reverse_cat_index(category, _categories) when not is_binary(category) and category != nil do
    raise ArgumentError,
          "SWAR carries one category per player - reverse_cat_index/2 needs the pairing " <>
            "category (a string), got: #{inspect(category)}. Resolve it with " <>
            "PairingsEngine.Categories.pairing_category/2 before calling."
  end

  def reverse_cat_index("", _categories), do: 0
  def reverse_cat_index(nil, _categories), do: 0

  def reverse_cat_index(category, categories) do
    case Enum.find_index(categories, &(&1 == category)) do
      nil -> 0
      index -> (index + 1) * 100
    end
  end

  # Two-axis form, called only when the tournament's categories came from a
  # two-axis SWAR import (`category_axes_for_export/1` above). Mirrors
  # `SwarImport.category_axes/2`'s decode exactly: axis 1 packed
  # `(idx + 1) * 100`, axis 2 packed `idx + 1`, both a 0-based index into
  # their own list, no leading blank slot on either (see `reverse_categories/3`).
  # `axis1_category` is always the pairing category
  # (`Categories.pairing_category/2`, axis 1 by convention - docs/swar-import.md);
  # `axis2_category` is whichever of the player's tags is in `axis2`, or
  # `nil` if none is - same "not found" -> 0 convention as `reverse_cat_index/2`.
  def reverse_cat_index(axis1_category, axis1, axis2_category, axis2) do
    reverse_cat_index(axis1_category, axis1) + axis2_component(axis2_category, axis2)
  end

  defp axis2_component(nil, _axis2), do: 0
  defp axis2_component("", _axis2), do: 0

  defp axis2_component(category, axis2) do
    case Enum.find_index(axis2, &(&1 == category)) do
      nil -> 0
      index -> index + 1
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

  defp reverse_round(
         %{round_nr: n, table: table, advers: advers, result: result, colour: colour} = record
       ) do
    w_i32(n) <>
      w_i32(table) <>
      w_i32(advers) <>
      w_i32(result) <> w_i32(colour) <> w_i32(0) <> w_i32(Map.get(record, :xtra, 0))
  end

  # One preloaded round's pairings, keyed the way `reverse_player/6` wants
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
  # tournament, keyed by player id: one per round, always. A round with no
  # pairing and no byes row (globally `absent: true` with no per-round bye
  # recorded, or a round before the player's `start_round` that does not
  # count as an absence) gets an explicit zero-point record instead of
  # being skipped.
  #
  # A round before `start_round` used to be omitted. SWAR has no such
  # thing: a player added after rounds were paired gets a record for every
  # one of them (`JoueurInit`, Joueur.cpp), and SWAR finds a round by its
  # POSITION in the player's array (`jou.pRound + RoundIndex`, e.g.
  # `GetNbAbsence` in Utils.cpp) - so a missing round 1 made SWAR read the
  # player's round 2 as round 1, and every later round one early.
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
  #
  # An absence carries the points it scores - `abs_value` under the
  # tournament's two caps, the running count kept here in round order the
  # way `Standings` keeps it - so the file's `Points` add up to the
  # standings rather than to a zero per absence.
  defp build_round_records(tournament, players, rounds, ni_by_player_id) do
    for player <- players, into: %{} do
      {records, _absences} =
        Enum.map_reduce(rounds, 0, fn {number, pairings, byes}, absences ->
          case round_record_for(player, number, pairings, byes, ni_by_player_id) do
            :absent ->
              absences = absences + 1
              points = Standings.bye_points("absent", tournament, number, absences)
              {absent_record(number, points), absences}

            record ->
              {record, absences}
          end
        end)

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
          #
          # A postponed game (`"*"`) is the exception: `result_bits/2` writes
          # it as bitmask 0 - SWAR's own "not played yet", which is the state
          # it is in - so it must not be counted as played beside that.
          played?:
            Standings.played_result?(pairing.result) and
              not PairingsEngine.Results.postponed?(pairing.result)
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

      # A declared absence - a real "absent" row, or a round before the
      # player joined that counts as one (`LateEntry`, merged into `byes`
      # by `export/1`). Scored by `build_round_records/4`, which keeps the
      # running count the `abs_nbfois` cap is measured with.
      bye && bye.type == "absent" ->
        :absent

      # No pairing, no byes row - the round the player wasn't there for
      # and nobody logged a bye/absence type for, or a round before they
      # joined that is worth nothing. Before, this was a `nil` (round
      # omitted from the array); see `build_round_records/4`'s comment for
      # why that produced garbled real-SWAR reads.
      true ->
        not_played_record(number)
    end
  end

  # A declared absence, the way SWAR itself keeps one (every real file:
  # `TABLE_ABSENT`, Advers -1, no result, no colour) - the only shape SWAR
  # pays `AbsValue` for and counts towards `AbsNbFois`. It used to be the
  # zero-table shape below, which SWAR scores as nothing and does not count,
  # so an event paying half a point per absence lost it on the way to SWAR.
  defp absent_record(round_nr, points) do
    %{
      round_nr: round_nr,
      table: @table_absent,
      advers: -1,
      colour: 0,
      result: 0,
      points: points,
      played?: false
    }
  end

  # A round with nothing in it for the player: no table, no result - worth
  # nothing in SWAR as here, and not an absence SWAR counts.
  defp not_played_record(round_nr) do
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
  # A postponed game (`"*"`), and "" (not entered), fall here: bitmask 0,
  # SWAR's "not played yet". SWAR has no code for a game counted as a draw
  # until it is played, so the file says the plain truth - no result yet.
  defp result_bits(_other, _white?), do: {0, 0.0}

  ## ---------- What the export screen says the file cannot carry ----------

  # Every result code in the tournament, for `result_notes/1`.
  defp tournament_results(tournament_id) do
    from(p in PairingsEngine.Tournaments.Pairing,
      join: r in PairingsEngine.Tournaments.Round,
      on: r.id == p.round_id,
      where: r.tournament_id == ^tournament_id,
      select: p.result
    )
    |> Repo.all()
  end

  defp system_notes(t) do
    [
      t.pairing_system == "keizer" &&
        gettext(
          "SWAR has no Keizer system: the tournament is written as a Swiss, with its games and results. Its Keizer standings are not in the file."
        ),
      t.type in ["team-swiss", "team-roundrobin"] &&
        gettext(
          "SWAR has no team tournaments: the individual games are written, but the teams, the matches and the match points are not in the file."
        ),
      t.acceleration == "baku" &&
        gettext(
          "Baku acceleration is not written: SWAR's own accelerated Swiss groups and scores players differently. The rounds already played are in the file as they are."
        ),
      t.manual_ranking &&
        gettext(
          "The standings order set by hand is not written: SWAR ranks by its own tie-breaks."
        ),
      Standings.ranked_separately?(t) !=
        (t.pair_by_category and t.categories_enabled and (t.categories || []) != []) &&
        gettext(
          "SWAR has one setting for pairing and ranking each category on its own, and this tournament does only one of the two. The file switches it on, so SWAR will both pair and rank each category separately."
        ),
      (t.pair_by_category and t.categories_enabled and (t.categories || []) != [] and
         t.swiss_match_format) &&
        gettext(
          "Match format with categories paired separately goes to SWAR as its \"double rounds\" Swiss with separate categories."
        )
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp scoring_notes(t, players) do
    acceleration? = Tournament.extra_points_acceleration?(t)
    any_extra? = Enum.any?(players, &((&1.extra_points || 0.0) != 0.0))

    [
      (round_robin?(t) and custom_points?(t)) &&
        gettext(
          "SWAR scores a round robin 1, ½ and 0 only: this tournament's own point values are not in the file, and SWAR will score its games the usual way."
        ),
      (not round_robin?(t) and custom_points?(t)) &&
        gettext(
          "SWAR keeps its own point values only for its \"3-2-1\" type, so the file is a 3-2-1 tournament with this tournament's values. OpenPairings cannot import a 3-2-1 file back yet."
        ),
      (not acceleration? and not t.count_extra_points and any_extra?) &&
        gettext(
          "Players' extra points are not written, because this tournament does not count them and SWAR always would."
        ),
      (acceleration? and not t.count_extra_points and any_extra? and not round_robin?(t)) &&
        gettext(
          "The acceleration points are written as SWAR's XtraPoints, which SWAR pairs with as this tournament does - but SWAR also counts them in its standings, which this tournament does not."
        ),
      ((t.count_extra_points or (acceleration? and any_extra?)) and round_robin?(t)) &&
        gettext(
          "Extra points are not written for a round robin: SWAR discards them when it opens one."
        ),
      (not acceleration? and (t.extra_points_bands || "") != "") &&
        gettext(
          "The extra-point bands are not written: SWAR's band table gives points to players at or above a rating, these to players below one. The points already given to players are."
        ),
      (acceleration? and band_count(t) > 4) &&
        gettext(
          "SWAR holds four extra-point bands: the four with the highest ratings are written, the others are not. The points already given to players are."
        )
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp band_count(t) do
    case Tournament.parse_extra_points_bands(t.extra_points_bands) do
      {:ok, bands} -> length(bands)
      :error -> 0
    end
  end

  defp category_notes(t) do
    categories = t.categories || []

    [
      length(categories) > 16 &&
        gettext(
          "SWAR holds 16 categories; the ones after the 16th, and the players' places in them, are not in the file."
        ),
      (categories != [] and map_size(t.category_rules || %{}) > 0) &&
        gettext(
          "The conditions that fill a category automatically are not written: SWAR's categories are names, and every player goes with the category they are in now."
        )
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp tiebreak_notes(t) do
    case Enum.reject(t.tiebreaks || [], &Map.has_key?(@tiebreak_reverse, &1)) do
      [] ->
        if length(t.tiebreaks || []) > 5 do
          [
            gettext("SWAR keeps five tie-breaks; the ones after the fifth are not in the file.")
          ]
        else
          []
        end

      missing ->
        [
          gettext(
            "SWAR has no tie-break for %{codes}: it is left out of the file's tie-break list, and SWAR will rank without it.",
            codes: Enum.join(missing, ", ")
          )
        ]
    end
  end

  defp player_notes(t, players) do
    [
      Enum.any?(
        players,
        &((&1.national_rating || 0) > 0 and &1.national_rating != &1.fide_rating)
      ) &&
        gettext(
          "A SWAR 7 file has one rating per player: the FIDE rating is written, and a national rating that differs from it is not."
        ),
      # SWAR has no "joined in round N": it keeps every round before it,
      # as an absence (which is what they are here when the tournament
      # counts them as one) or as not played.
      (not LateEntry.applies?(t) and LateEntry.effective_start_rounds(t) != %{}) &&
        gettext(
          "Players who joined after round 1 are written as not having played the rounds before it: SWAR has no \"joined in round\"."
        )
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp result_notes(results) do
    [
      Enum.any?(results, &(&1 in ["1-0U", "0-1U", "1/2-1/2U"])) &&
        gettext(
          "SWAR has no \"played but not rated\" result: those games are written as ordinary rated results."
        ),
      Enum.any?(results, &PairingsEngine.Results.postponed?/1) &&
        gettext(
          "Postponed games are written as not played yet, which is what SWAR has for them; what they count as until then is not in the file."
        )
    ]
    |> Enum.filter(&is_binary/1)
  end
end
