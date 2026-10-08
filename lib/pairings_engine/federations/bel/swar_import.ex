defmodule PairingsEngine.Federations.BEL.SwarImport do
  @moduledoc """
  Importer for `.swar` files - the native save format of the SWAR chess
  tournament pairing program (by Georges Marchal / FRBE).

  `parse/1` is a pure binary parser that mirrors the on-disk structure as a
  plain data map. `import_file/1` builds on top of it to create a
  `PairingsEngine.Tournaments.Tournament`, its players, rounds and pairings.

  The format is a sequential binary serialization with no index and no
  recovery from misparses - every field must be read in exact order. See
  the SWAR format manual for the full field-by-field layout; the section
  order implemented here is: header, [TOURNOI], [DATES], [TIE_BREAK],
  [EXCLUSION], [CATEGORIES], [XTRA_POINTS], [JOUEURS] (with per-player
  [RONDE] round data).
  """

  import Ecto.Query
  # The refusals and notices added for team competitions (`check_importable/1`,
  # `team_marked_message/0`, `exclusion_warnings/1`) reach the organiser as
  # they are, so they are translated here, the way `SwarPublish` does.
  use Gettext, backend: PairingsEngineWeb.Gettext

  alias PairingsEngine.Repo
  alias PairingsEngine.{Encoding, Federation, SafeError, Tournaments, Standings}
  alias PairingsEngine.Tournaments.{Tournament, Player, Round, Pairing}
  alias PairingsEngine.Fide.FidePlayer

  ## ---------- Primitives ----------

  defp read_i32(<<v::little-signed-32, rest::binary>>), do: {v, rest}
  defp read_i16(<<v::little-signed-16, rest::binary>>), do: {v, rest}
  defp read_u8(<<v::8, rest::binary>>), do: {v, rest}

  defp read_str(<<len::little-signed-32, rest::binary>>) when len >= 0 do
    <<bytes::binary-size(^len), rest2::binary>> = rest
    {Encoding.cp1252_decode(bytes), rest2}
  end

  defp read_n(bin, 0, _fun), do: {[], bin}

  defp read_n(bin, n, fun) when n > 0 do
    {v, bin} = fun.(bin)
    {rest, bin} = read_n(bin, n - 1, fun)
    {[v | rest], bin}
  end

  defp version_gte?(version, target), do: version >= target

  # `points_adjusted` (SWAR's arbiter-entered correction) arrived in v6.49
  # and is gone again in v7, whose [JOUEURS] record is exactly one int
  # shorter across the `NbParties`..`Perf` run. Every int in that run is zero
  # in the only v7 file available to reverse engineer against (its tournament
  # hadn't started), so which one was dropped isn't provable from it -
  # `points_adjusted` is the choice that fails safe, being the run's only
  # field this importer reads at all. Guessing it wrong therefore can't shift
  # anything we persist; at worst it silences an advisory warning (see
  # `points_adjusted_warnings/3`).
  defp has_points_adjusted?(version),
    do: version_gte?(version, "v6.49") and not version_gte?(version, "v7.00")

  ## ---------- Public API ----------

  @doc """
  Parses a raw `.swar` binary into a plain map mirroring the SWAR structure.
  Returns `{:ok, map}` or `{:error, reason}`.
  """
  def parse(binary) when is_binary(binary) do
    {version, rest} = read_str(binary)
    {guid, rest} = read_str(rest)
    {mac, rest} = read_str(rest)

    {tournoi, rest} = parse_tournoi_section(rest, version)
    {dates, rest} = parse_dates(rest, tournoi.nb_rounds)
    {tiebreaks, rest} = parse_tie_break(rest)
    {exclusion, rest} = parse_exclusion(rest)
    {categories, rest} = parse_categories(rest, version)
    {xtra_points, rest} = parse_xtra_points(rest)
    {players, rest} = parse_joueurs(rest, version)

    {players, round_zero} = strip_round_zero(players)

    with :ok <- validate_unique_nis(players),
         :ok <- validate_round_numbers(players) do
      {:ok,
       %{
         version: version,
         guid: guid,
         mac: mac,
         tournament: tournoi,
         dates: dates,
         tiebreaks: tiebreaks,
         exclusion: exclusion,
         categories: categories,
         xtra_points: xtra_points,
         players: players,
         # Empty round-0 records taken off the players (`strip_round_zero/1`):
         # SWAR's own "base" files - a player list kept to start every new
         # tournament from - carry one per player. Imported as a tournament
         # with its players and no rounds; `round_zero_warnings/1` says so.
         round_zero_records: round_zero,
         # Bytes left over once the last [JOUEURS] record is read. SWAR's
         # own writer (`TournoiReadWrite.cpp`, `TournoiWrite`) closes the
         # file straight after the last player's [RONDE] records, so a real
         # file leaves none; see `check_importable/1` for what is done with
         # a leftover.
         trailing_bytes: byte_size(rest)
       }}
    end
  rescue
    # The one deliberate `raise` in this module (`parse_tournoi_section/2`,
    # on no [TOURNOI] layout matching) - its message is static text plus
    # the file's declared version string, never row data, so it is safe to
    # show as written.
    e in RuntimeError ->
      {:error, {:parse_failed, Exception.message(e)}}

    # Every other exception's own `Exception.message/1` quotes the value
    # that failed to match - here, a slice of the file itself, which can
    # hold a player's name or other row data straight out of the binary
    # being parsed. Only the exception's type is kept - see
    # PairingsEngine.SafeError.
    e ->
      kind = SafeError.log_crash("SWAR import", e, __STACKTRACE__)
      {:error, {:parse_failed, "the file could not be read (#{kind})"}}
  end

  # Every downstream step keys players by their SWAR `NI` (the internal
  # number): `create_players/3` builds `players_by_ni` and `build_round/1`
  # builds `by_ni`, both with `Map.new/2`, which silently keeps only the
  # *last* entry for a repeated key. A corrupt file with two `[JOUEURS]`
  # records sharing an `NI` would otherwise import both as DB rows but hand
  # the first one's games over to the second, orphaning a player nobody's
  # pairings reference. Caught here, before any row is written - the same
  # pre-flight `PairingsEngine.TrfImport.validate_unique_ranks/1` runs for
  # the TRF importer's starting ranks, and for the same reason.
  defp validate_unique_nis(players) do
    dupes =
      players
      |> Enum.map(& &1.ni)
      |> Enum.frequencies()
      |> Enum.filter(fn {_ni, count} -> count > 1 end)
      |> Enum.map(fn {ni, _count} -> ni end)
      |> Enum.sort()

    case dupes do
      [] ->
        :ok

      _ ->
        {:error,
         {:parse_failed, "duplicate player number(s) in [JOUEURS]: #{Enum.join(dupes, ", ")}"}}
    end
  end

  # Round 0 is not a round. SWAR's own "base" files - "TOURNOI ZERO", a
  # club's player list saved once and opened to start every new event from
  # (one in SWAR's own archive) - carry one [RONDE] record per player
  # numbered 0, with no opponent, no result and no table: the slot SWAR's
  # `InitNextRonde` prepares before round 1 exists. Such a record is taken
  # off here, so the file imports as a tournament with its players and no
  # rounds. A round-0 record that does carry an opponent or a result is left
  # in place, and `validate_round_numbers/1` refuses the file: that is not a
  # template but a record this reader does not understand.
  @doc false
  def strip_round_zero(players) do
    Enum.map_reduce(players, 0, fn p, count ->
      {zero, rest} = Enum.split_with(p.rounds, &empty_round_zero?/1)

      case zero do
        [] -> {p, count}
        _ -> {%{p | rounds: rest, nb_round: length(rest)}, count + length(zero)}
      end
    end)
  end

  defp empty_round_zero?(%{round_nr: 0} = r),
    do: r.advers in [0, -1] and r.result == 0 and r.table in [-1, 0, 0x4000]

  defp empty_round_zero?(_r), do: false

  # A [RONDE] record's round number is a raw signed 32-bit integer straight
  # off the disk, and `create_rounds/3` turns the highest one it finds into
  # the range `1..max_round` - inside the import transaction, holding
  # SQLite's write lock. One player record carrying 2,000,000,000 therefore
  # stops the whole application, not just the import: two billion iterations
  # of a comprehension over every player's rounds, with every other writer
  # queued behind it. The tournament's own round count is checked (it lands
  # in `rounds_count`, which `Tournament.changeset/2` caps), but that is a
  # different field and a file can hold nine in one and two billion in the
  # other.
  #
  # `Tournament.max_rounds/0` is the right ceiling rather than an invented
  # one: it is this application's single statement of how long a tournament
  # may be, it is already enforced on this very import path, and a file
  # whose rounds run past it describes a tournament that could not be
  # created here even if the loop were free. Coupling to it means the two
  # cannot drift.
  #
  # Zero and negative are refused by the same check, and not only for
  # speed. `1..max(max_round, 0)` on an all-zero file is the descending
  # range `1..0`, which fed round 0 to `insert_round/4` and wrote a Round
  # row numbered 0 - a tournament with a round before its first.
  defp validate_round_numbers(players) do
    max_rounds = Tournament.max_rounds()

    players
    |> Enum.flat_map(& &1.rounds)
    |> Enum.map(& &1.round_nr)
    |> Enum.reject(&(&1 in 1..max_rounds))
    |> Enum.uniq()
    |> Enum.sort()
    |> case do
      [] ->
        :ok

      bad ->
        # Named, but only the first few: a corrupt file can hold a distinct
        # bad number per round record, and a refusal that lists eighty
        # thousand of them is its own denial of service.
        shown = Enum.take(bad, 5)
        more = if length(bad) > 5, do: " and #{length(bad) - 5} more", else: ""

        {:error,
         {:parse_failed,
          "round number(s) outside 1-#{max_rounds} in [JOUEURS]: " <>
            Enum.join(shown, ", ") <> more}}
    end
  end

  ## ---------- [TOURNOI] ----------

  # [TOURNOI]'s tail lost 12 bytes somewhere between the FIDE-id block and
  # `Type` in v7, but *which* fields went can't be read off the only v7 file
  # available to reverse engineer against: that whole region is zeroed in it,
  # which makes "three of the four trailing strings are gone" and "the
  # FIDE-id block is one 3-int entry shorter" byte-for-byte identical. The
  # two only diverge once a v7 file turns up with a non-empty FIDE arbiter
  # id or remark, so rather than bet on one now, try the likely layout for
  # the file's version and fall back on the others, keeping whichever leaves
  # the parser looking at the [DATES] marker that must follow. A wrong guess
  # costs a re-parse of ~600 bytes; a wrong *silent* guess would corrupt
  # every field after it.
  #
  # `{FIDE-id entries, trailing strings}`:
  @tournoi_layouts %{v6: {16, 4}, v7_strings: {16, 1}, v7_fide_ids: {15, 4}}

  defp parse_tournoi_section(bin, version) do
    order =
      if version_gte?(version, "v7.00"),
        do: [:v7_strings, :v7_fide_ids, :v6],
        else: [:v6, :v7_strings, :v7_fide_ids]

    Enum.find_value(order, fn layout ->
      try do
        {tournoi, rest} = parse_tournoi(bin, version, @tournoi_layouts[layout])
        {"[DATES]", _} = read_str(rest)
        {tournoi, rest}
      rescue
        _ -> nil
      end
    end) ||
      raise "no known [TOURNOI] layout leaves the parser at [DATES] (file version #{version})"
  end

  defp parse_tournoi(bin, version, {n_fide_ids, n_strings}) do
    {_marker, bin} = read_str(bin)
    {name, bin} = read_str(bin)
    {organizer, bin} = read_str(bin)
    {club_or_logo, bin} = read_str(bin)
    {city, bin} = read_str(bin)
    {arbiter1, bin} = read_str(bin)
    {arbiter2, bin} = read_str(bin)
    {start_date, bin} = read_str(bin)
    {end_date, bin} = read_str(bin)
    {cadence, bin} = read_i32(bin)
    {cadence_other, bin} = read_str(bin)
    {nb_rounds, bin} = read_i32(bin)
    {frbe_from, bin} = read_i32(bin)
    {frbe_to, bin} = read_i32(bin)
    {fide_from, bin} = read_i32(bin)
    {fide_to, bin} = read_i32(bin)
    {cat_separes, bin} = read_i32(bin)
    {elo_ou_pays, bin} = read_i32(bin)
    {fide_homolog, bin} = read_i32(bin)

    {fide_ids, bin} =
      if version_gte?(version, "v5.24") do
        read_n(bin, n_fide_ids, fn bin ->
          {de, bin} = read_i32(bin)
          {aa, bin} = read_i32(bin)
          {id, bin} = read_i32(bin)
          {%{de: de, aa: aa, id: id}, bin}
        end)
      else
        {_old_fide_id, bin} = read_str(bin)
        {[], bin}
      end

    {strings, bin} = read_n(bin, n_strings, &read_str/1)

    {fide_arb1, fide_arb2, fide_remarks} =
      case strings do
        [arb1, arb2, _dummy1, remarks] -> {arb1, arb2, remarks}
        [remarks] -> {"", "", remarks}
      end

    {type, bin} = read_i32(bin)

    bin =
      if version_gte?(version, "v6.03") do
        bin
      else
        {_dummy, bin} = read_i32(bin)
        bin
      end

    {sw_elo_r1, bin} = read_i32(bin)
    {sw_amer_presence, bin} = read_i32(bin)
    {plusieurs, bin} = read_i32(bin)
    {first_table, bin} = read_i32(bin)
    {sw321_win, bin} = read_i32(bin)
    {sw321_nul, bin} = read_i32(bin)
    {sw321_los, bin} = read_i32(bin)
    {sw321_bye, bin} = read_i32(bin)
    {sw321_pre, bin} = read_i32(bin)

    {sw321_prebye, bin} =
      if version_gte?(version, "v6.03") do
        read_i32(bin)
      else
        {nil, bin}
      end

    {elo_used, bin} = read_i32(bin)
    {tournoi_std, bin} = read_i32(bin)
    {tb_personel, bin} = read_i32(bin)
    {appar_order, bin} = read_i32(bin)
    {elo_equal, bin} = read_i32(bin)
    {bye_value, bin} = read_i32(bin)
    {abs_value, bin} = read_u8(bin)
    {abs_nbfois, bin} = read_u8(bin)
    {abs_jusque, bin} = read_u8(bin)
    {_dummy3, bin} = read_u8(bin)
    {ff_value, bin} = read_i32(bin)
    {federation, bin} = read_i32(bin)

    map = %{
      name: name,
      organizer: organizer,
      club_or_logo: club_or_logo,
      city: city,
      arbiter1: arbiter1,
      arbiter2: arbiter2,
      start_date: start_date,
      end_date: end_date,
      cadence: cadence,
      cadence_other: cadence_other,
      nb_rounds: nb_rounds,
      frbe_from: frbe_from,
      frbe_to: frbe_to,
      fide_from: fide_from,
      fide_to: fide_to,
      cat_separes: cat_separes,
      elo_ou_pays: elo_ou_pays,
      fide_homolog: fide_homolog,
      fide_ids: fide_ids,
      fide_arb1: fide_arb1,
      fide_arb2: fide_arb2,
      fide_remarks: fide_remarks,
      type: type,
      sw_elo_r1: sw_elo_r1,
      sw_amer_presence: sw_amer_presence,
      plusieurs: plusieurs,
      first_table: first_table,
      sw321_win: sw321_win,
      sw321_nul: sw321_nul,
      sw321_los: sw321_los,
      sw321_bye: sw321_bye,
      sw321_pre: sw321_pre,
      sw321_prebye: sw321_prebye,
      elo_used: elo_used,
      tournoi_std: tournoi_std,
      tb_personel: tb_personel,
      appar_order: appar_order,
      elo_equal: elo_equal,
      bye_value: bye_value,
      abs_value: abs_value,
      abs_nbfois: abs_nbfois,
      abs_jusque: abs_jusque,
      ff_value: ff_value,
      federation: federation
    }

    {map, bin}
  end

  ## ---------- [DATES] ----------

  defp parse_dates(bin, nb_rounds) do
    {_marker, bin} = read_str(bin)
    read_n(bin, max(nb_rounds, 0), &read_str/1)
  end

  ## ---------- [TIE_BREAK] ----------

  defp parse_tie_break(bin) do
    {_marker, bin} = read_str(bin)
    read_n(bin, 5, &read_i32/1)
  end

  ## ---------- [EXCLUSION] ----------

  defp parse_exclusion(bin) do
    {_marker, bin} = read_str(bin)
    {type, bin} = read_i32(bin)
    {values, bin} = read_str(bin)
    {%{type: type, values: values}, bin}
  end

  ## ---------- [CATEGORIES] ----------

  # SWAR raised `MAX_CATEGO` from 12 to 16 in v6.50, and its reader gates the
  # longer list on the file saying "v6.50" or later (`TournoiReadWrite.cpp`,
  # `MaxCatego`, commented "v6.50 v6.57"). Not every file that says v6.50 was
  # written with it: SWAR's own sample `RR_Nor.swar` is a v6.50 file with 12,
  # and read as 16 its first player's name length lands in the category
  # strings and the whole file fails to import. So from v6.50 on both lengths
  # are tried, the documented one first, and the one kept is the one that
  # leaves the parser on the `[XTRA_POINTS]` marker that must follow - the
  # same technique as `parse_tournoi_section/2`'s layouts. An older file only
  # ever had 12.
  defp parse_categories(bin, version) do
    {_marker, bin} = read_str(bin)
    {type, bin} = read_i32(bin)
    lengths = if version_gte?(version, "v6.50"), do: [16, 12], else: [12]

    Enum.find_value(lengths, fn max_categ -> try_categories(bin, type, max_categ) end) ||
      raise "no known [CATEGORIES] length leaves the parser at [XTRA_POINTS] (file version #{version})"
  end

  defp try_categories(bin, type, max_categ) do
    {value1, rest} = read_n(bin, max_categ + 1, &read_str/1)
    {value2, rest} = read_n(rest, max_categ + 1, &read_str/1)
    {marker, _} = read_str(rest)

    if String.contains?(marker, "XTRA_POINTS"),
      do: {%{type: type, value1: value1, value2: value2}, rest},
      else: nil
  rescue
    # A wrong length reads string lengths out of the middle of other fields;
    # the binary match fails, which is exactly the "not this layout" answer.
    MatchError -> nil
    FunctionClauseError -> nil
  end

  ## ---------- [XTRA_POINTS] ----------

  defp parse_xtra_points(bin) do
    {_marker, bin} = read_str(bin)

    read_n(bin, 4, fn bin ->
      {pts, bin} = read_i32(bin)
      {elo, bin} = read_i32(bin)
      {{pts, elo}, bin}
    end)
  end

  ## ---------- [JOUEURS] ----------

  defp parse_joueurs(bin, version) do
    {_marker, bin} = read_str(bin)
    {n_players, bin} = read_i32(bin)
    read_n(bin, n_players, &parse_player(&1, version))
  end

  defp parse_player(bin, version) do
    {class, bin} = read_i32(bin)
    {name, bin} = read_str(bin)
    {ni, bin} = read_i32(bin)
    {rank, bin} = read_i32(bin)
    {cat_index, bin} = read_i32(bin)
    {birth, bin} = read_str(bin)
    {sex, bin} = read_i32(bin)
    {country, bin} = read_str(bin)
    {mat_nat, bin} = read_i32(bin)
    {mat_fide, bin} = read_i32(bin)
    {affilie, bin} = read_i32(bin)
    {elo, bin} = read_i32(bin)

    # v7 dropped `EloFide`: Belgium retired its own rating list (the KBSB
    # export's `Elo` column is zero for everyone now), so the single Elo a v7
    # record still carries *is* the FIDE rating - checked against the local
    # FIDE database, where it tracks `standard_rating` and differs only by
    # the month between SWAR's list and ours. Mirror it so `fide_rating_or/1`
    # keeps working instead of filing every v7 player as unrated.
    {elo_fide, bin} =
      if version_gte?(version, "v7.00"), do: {elo, bin}, else: read_i32(bin)

    {title, bin} = read_i32(bin)
    {club_nr, bin} = read_i32(bin)
    {club, bin} = read_str(bin)
    {nb_parties, bin} = read_i32(bin)
    {points, bin} = read_i32(bin)

    {points_adjusted, bin} =
      if has_points_adjusted?(version) do
        read_i32(bin)
      else
        {0, bin}
      end

    {amer_pts, bin} = read_i32(bin)
    {tiebreak, bin} = read_n(bin, 5, &read_i32/1)
    {perf, bin} = read_i32(bin)

    {paye, bin} =
      if version_gte?(version, "v5.52") do
        read_i32(bin)
      else
        {1, bin}
      end

    {absent, bin} = read_i32(bin)
    {absent_rondes, bin} = read_str(bin)
    {extra_pts, bin} = read_i32(bin)
    {special_pts, bin} = read_i32(bin)
    {nb_round, bin} = read_i16(bin)
    {handy_table, bin} = read_i16(bin)

    {_ronde_marker, bin} = read_str(bin)
    {rounds, bin} = read_n(bin, max(nb_round, 0), &parse_round/1)

    player = %{
      class: class,
      name: name,
      ni: ni,
      rank: rank,
      cat_index: cat_index,
      birth: birth,
      sex: sex,
      country: country,
      mat_nat: mat_nat,
      mat_fide: mat_fide,
      affilie: affilie,
      elo: elo,
      elo_fide: elo_fide,
      title: title,
      club_nr: club_nr,
      club: club,
      nb_parties: nb_parties,
      points: points,
      points_adjusted: points_adjusted,
      amer_pts: amer_pts,
      tiebreak: tiebreak,
      perf: perf,
      paye: paye,
      absent: absent,
      absent_rondes: absent_rondes,
      extra_pts: extra_pts,
      special_pts: special_pts,
      nb_round: nb_round,
      handy_table: handy_table,
      rounds: rounds
    }

    {player, bin}
  end

  defp parse_round(bin) do
    {round_nr, bin} = read_i32(bin)
    {table, bin} = read_i32(bin)
    {advers, bin} = read_i32(bin)
    {result, bin} = read_i32(bin)
    {color, bin} = read_i32(bin)
    {float, bin} = read_i32(bin)
    {xtra_pts, bin} = read_i32(bin)

    round = %{
      round_nr: round_nr,
      table: table,
      advers: advers,
      result: result,
      color: color,
      float: float,
      xtra_pts: xtra_pts
    }

    {round, bin}
  end

  ## ================================================================
  ## Import: parse + persist as Tournament / Player / Round / Pairing
  ## ================================================================

  # Table number special value for a pairing-allocated bye (see manual §5.7).
  @table_bye 0x1000

  # SWAR's absence table (`TABLE_ABSENT`, Swar.h): the only single-sided
  # record without a result that is an absence - paid `AbsValue` and counted
  # towards `AbsNbFois`. Any other table with no result (0, -1, SWAR's
  # `TABLE_FORFAIT` 0x2000) is a round the player was not in, and scores
  # nothing (`single_sided/2`).
  @table_absent 0x4000

  # SWAR's "HandyTable" accessible-table numbering (Swar.h TABLE_HANDICAP):
  # 1000 is the sentinel meaning "no fixed table"; a real handicap board is
  # TABLE_HANDICAP + N (1001, 1002, ...), assigned fresh each round by SWAR's
  # own pairing code - not a globally meaningful board number, any more than
  # TABLE_BYE is. Imported verbatim, a 1001+ "board" sorted way past every
  # real one distorts anything ordered by board number (notably the pairing-
  # rationale bracket map, where it renders the player far to the right of
  # where their actual score puts them) - `finalize_boards/1` renormalizes it
  # the same way it already does for byes.
  @table_handicap 1000

  @doc """
  Reads a `.swar` file from `path`, parses it, and creates the tournament
  (with its players, rounds and pairings) inside a single transaction - the
  original one-step API, kept for any non-interactive caller (tests, a
  future CLI/API import, ...) that has no way to ask a human to resolve a
  missing FIDE id. Players SWAR has no `mat_fide` for are matched against
  the local FIDE database same as `prepare_import/1` (see there); anyone
  left ambiguous or unmatched is simply imported without a `fide_id`,
  exactly like before this module could match FIDE ids at all.
  Pass a `%PairingsEngine.Accounts.Scope{}` as `scope` to make the logged-in
  user the owner; `nil` creates it unowned (visible to nobody in the web UI).
  Returns `{:ok, %Tournament{}, warnings}` or `{:error, reason}` - `warnings`
  is a (possibly empty) list, one entry per thing the import read correctly
  but cannot fully carry over: `points_adjusted_warnings/3` (SWAR's own
  arbiter-entered `points_adjusted` correction, file version >= v6.49, which
  can't be reconstructed from replayed pairings/byes the way ordinary
  standings always are), `category_warnings/1`, `tiebreak_warnings/1`,
  `round_robin_bye_warnings/1` and `xtra_points_warnings/1`, and
  `trailing_data_warnings/1`, `round_zero_warnings/1`,
  `category_mode_warnings/1`, `type_warnings/1`, `unpaired_round_warnings/1`
  and `exclusion_warnings/1` - see each for what it flags. `PairingsEngineWeb.TournamentsLive.maybe_flash_swar_warnings/2`
  is what turns them into what the arbiter actually sees.
  """
  #
  # `opts` also takes `as_individual: true`: a file in SWAR's team mode (see
  # `team_marked?/2`) is refused without it, and imported as the individual
  # tournament SWAR itself stores with it.
  def import_file(path, scope \\ nil, opts \\ []) do
    with {:ok, binary} <- File.read(path),
         {:ok, data} <- parse(binary),
         :ok <- check_importable(data),
         :ok <- check_team_mode(data, Path.basename(path), opts) do
      cache = build_fide_candidates_cache(data.players)
      players = Enum.map(data.players, &best_effort_fide_match(&1, cache))
      run_import(%{data | players: players}, scope)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_team_mode(data, filename, opts) do
    if team_marked?(data, filename) and not Keyword.get(opts, :as_individual, false),
      do: {:error, team_marked_message()},
      else: :ok
  end

  ## ---------- Team competitions: what a .swar file can and cannot say ----------
  #
  # A `.swar` file has no teams in it. SWAR's writer (`TournoiReadWrite.cpp`,
  # `TournoiWrite`, v6.65 FRBE source) writes exactly eight sections -
  # [TOURNOI], [DATES], [TIE_BREAK], [EXCLUSION], [CATEGORIES],
  # [XTRA_POINTS], [JOUEURS] and each player's [RONDE] - and none of them
  # has a team, a roster, a board order, a match, a match point or a team
  # tie-break (`Swar.h`'s `DEPARTAGES` is individual criteria only). Its
  # `TOURNOI_TYPE` enum has nine values, all individual: Swiss, double,
  # accelerated, 3-2-1, three round robins, two American. Every one of the
  # 48 real files checked (v5.34 to v7.05) is one of those nine.
  #
  # What SWAR does have for team competitions is two ways of running one as
  # an individual event:
  #
  #   * "team" mode (v4.45, `PairingManual.cpp`, asked for by Luc Cornet): an
  #     ordinary Swiss whose name contains " - team", or whose file is named
  #     "... - team.swar". SWAR then stops pairing it and reads each round's
  #     boards from a text file of player-number pairs made elsewhere. The
  #     .swar keeps the individual games; the teams, the matches and the
  #     team scores live outside it. `team_marked?/2`.
  #   * club or nationality exclusion (`[EXCLUSION]`, "ICN style" in SWAR's
  #     own manual - schools, NATO teams): an individual Swiss in which two
  #     players of the same club, or nationality, never meet. It is carried
  #     over (`exclusion_rule/1`), because this app has the same rules.
  #
  # So nothing in a .swar file can be mapped onto teams here, and nothing is
  # guessed: a team-mode file is refused as a team event (the organiser may
  # import its games as an individual tournament instead), a file of a type
  # SWAR's nine do not include is refused outright, and data after the
  # player list - where a newer SWAR would have to put teams - is left out
  # with a warning. See docs/swar-import.md, "Team competitions".

  # SWAR's `TOURNOI_TYPE` (`Swar.h`): SWISS 0, SWISS_DBL 1, SWISS_ACC 2,
  # SWISS_321 3, ROBIN 4, ROBIN_DBL 5, ROBIN_AR 6, SW_AMERICAIN 7,
  # SW_AMERICAIN_DBL 8.
  @known_types 0..8

  @doc """
  The refusal every import makes once a file has parsed, before anything is
  written: `:ok`, or `{:error, message}` with a sentence for the organiser.

  **A tournament type outside SWAR's nine** (`@known_types`) is refused. It
  used to import as a Swiss; a type this reader has never seen may be scored
  or paired differently (a team competition, for instance), so it is not
  guessed.

  **Data after the player list** is not refused, though it was for a while.
  SWAR's writer ends the file with the last player's rounds, and every real
  file checked does, so anything after it is a part this reader does not
  know - the one place a newer SWAR could keep teams. Everything before it
  reads exactly as always, so the tournament imports without that part and
  `trailing_data_warnings/1` says so, with its size and the SWAR version, and
  asks for the file.

  `build_structs/1` (the public norms tool) does not run this: it reads only
  the players, which parse the same either way.
  """
  def check_importable(%{tournament: %{type: type}, version: version})
      when type not in @known_types do
    {:error,
     gettext(
       "This SWAR file is a kind of tournament OpenPairings does not know (type %{type}, saved by SWAR %{version}). It may be something a newer SWAR added - a team competition, for instance - so it has not been imported: read as an ordinary Swiss, its pairings and scores could come out wrong. Please report it and include the file, so that support can be added.",
       type: type,
       version: version
     )}
  end

  def check_importable(_data), do: :ok

  @doc """
  True when SWAR itself would treat the file as a team competition in its
  "team" mode: an ordinary Swiss (type 0) whose name contains `" - team"`,
  or whose file name contains `" - team.swar"`. The test is SWAR's own
  (`SwarView.cpp`, `OnPairing`: `Tournoi.Find(" - team") > 0 ||
  CeFichier.Find(" - team.swar") > 0`, only under `case SWISS`), including
  its case: `CString::Find` is case-sensitive, so `" - Team"` is an
  ordinary tournament to SWAR and to this function.

  `filename` is the name the organiser's file had - for an upload, the
  browser's file name, not the temporary path it was saved under.
  """
  def team_marked?(%{tournament: %{type: 0, name: name}}, filename) do
    found_after_start?(name, " - team") or found_after_start?(filename, " - team.swar")
  end

  def team_marked?(_data, _filename), do: false

  defp found_after_start?(text, pattern) when is_binary(text) do
    case :binary.match(text, pattern) do
      {pos, _len} -> pos > 0
      :nomatch -> false
    end
  end

  defp found_after_start?(_text, _pattern), do: false

  @doc """
  Why a team-mode file (`team_marked?/2`) is not imported as a team event.
  """
  def team_marked_message do
    gettext(
      "This SWAR file is a team competition in SWAR's team mode. SWAR keeps only the individual games in the file: which team each player plays for, the board order, the matches and the match points are kept outside it, so OpenPairings cannot rebuild the team event from it. You can import the games as an individual tournament, or set up the team tournament here: create it with Team tournament ticked and enter the teams on its Teams page."
    )
  end

  @doc """
  Formats any error `parse/2`, `prepare_import/1` or `commit_import/3` can
  return as a single flash-ready string - never `inspect/1` of an
  arbitrary reason, which for a `File.read/1` failure is a safe POSIX
  atom but for anything upstream of it is not a shape this function
  should assume.
  """
  def error_message({:parse_failed, message}), do: "Could not read this SWAR file: #{message}"
  def error_message(reason) when is_binary(reason), do: reason
  def error_message(reason) when is_atom(reason), do: "Could not read this SWAR file: #{reason}"
  def error_message(_reason), do: "Could not import this SWAR file."

  @doc """
  Reads and parses `path` (no database writes) and, for every player SWAR
  has no `mat_fide` id for, tries to match them against the local FIDE
  database on exact name (case-insensitive) + federation + birth year (see
  `docs/swar-import.md`). A single exact match is adopted straight away
  (into the returned `data`, same as `import_file/2`'s best-effort
  matching); everyone left ambiguous or with no match at all is collected
  into `unresolved` instead, for the caller to show the user a "resolve
  FIDE matches" step before committing with `commit_import/3`.

  Returns `{:ok, %{data: parsed_data, unresolved: [%{ni:, name:, federation:,
  birth_year:, candidates: [...]}]}}` or `{:error, reason}`. `unresolved ==
  []` means every player is already settled - the caller can go straight to
  `commit_import(prepared, %{}, scope)` without showing anything.

  The result also carries `team_marked:` (`team_marked?/2`, with
  `opts[:filename]` - the organiser's own file name - or else `path`'s). A
  team-mode file is not refused here, because the organiser may choose to
  import its games as an individual tournament; `commit_import/3` refuses it
  until the caller has asked them and set `team_marked: false`. A file
  `check_importable/1` refuses comes back as `{:error, message}`.
  """
  def prepare_import(path, opts \\ []) do
    with {:ok, binary} <- File.read(path),
         {:ok, data} <- parse(binary),
         :ok <- check_importable(data) do
      cache = build_fide_candidates_cache(data.players)

      {players, unresolved} =
        Enum.map_reduce(data.players, [], fn p, unresolved ->
          case resolve_fide_match(p, cache) do
            {:matched, resolved} -> {resolved, unresolved}
            {:unresolved, candidates} -> {p, [unresolved_entry(p, candidates) | unresolved]}
            :not_applicable -> {p, unresolved}
          end
        end)

      filename = Keyword.get(opts, :filename) || Path.basename(path)

      {:ok,
       %{
         data: %{data | players: players},
         unresolved: Enum.reverse(unresolved),
         team_marked: team_marked?(data, filename)
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Commits a tournament from `prepared` (as returned by `prepare_import/2`),
  applying the caller's chosen resolution for each of `prepared.unresolved`
  first. `resolutions` maps a player's `ni` (the SWAR internal number used
  as the key throughout `unresolved`) to either a FIDE id (integer) to
  adopt, or anything else (`nil`, `"skip"`, or simply an absent key) to
  import that player without a `fide_id` - same outcome as if no match had
  ever been attempted. Runs the same single-transaction,
  broadcast-after-commit import as `import_file/2`.
  Returns `{:ok, %Tournament{}, warnings}` or `{:error, reason}` - see
  `import_file/2` for what `warnings` carries. A file still marked
  `team_marked: true` is refused with `team_marked_message/0`: the caller
  sets it to `false` once the organiser has chosen to import the games as
  an individual tournament.
  """
  def commit_import(prepared, resolutions, scope \\ nil)

  def commit_import(%{team_marked: true}, resolutions, _scope) when is_map(resolutions),
    do: {:error, team_marked_message()}

  def commit_import(%{data: data}, resolutions, scope) when is_map(resolutions) do
    players = Enum.map(data.players, &apply_resolution(&1, resolutions))
    run_import(%{data | players: players}, scope)
  end

  @doc """
  Parses `binary` (a raw `.swar` file's bytes - same shape `parse/1` and
  `import_file/2` take) and builds unpersisted `%Tournament{}`/`%Player{}`
  structs, reusing the exact same header/player field mapping (federation
  normalization, birth dates, ratings, ...) `import_file/2` writes to the
  database with - but with NO `Repo` calls whatsoever: nothing is written,
  and no FIDE-database resolve step runs (that needs the DB - see
  `prepare_import/1`), so a player SWAR itself has no `mat_fide` id for
  simply comes back with `fide_id: nil`, exactly as if resolution had found
  no match. Also skips round/pairing/bye building, same reasoning as
  `PairingsEngine.TrfImport.build_structs/1`.

  Returns `{:ok, {tournament, players}}` or `{:error, reason}`; never
  raises.
  """
  def build_structs(binary) when is_binary(binary) do
    with {:ok, data} <- parse(binary) do
      build_structs_from_data(data)
    end
  end

  defp build_structs_from_data(data) do
    data = prepare_players(data)

    with {:ok, tournament} <- build_tournament_struct(data),
         {:ok, players} <- build_player_structs(data.players, data.categories) do
      {:ok, {tournament, players}}
    end
  end

  defp build_tournament_struct(data) do
    %Tournament{swar_settings: swar_settings(data)}
    |> Tournament.changeset(tournament_attrs(data))
    |> case do
      %{valid?: true} = changeset -> {:ok, Ecto.Changeset.apply_changes(changeset)}
      changeset -> {:error, changeset_error_text(changeset)}
    end
  end

  defp build_player_structs(swar_players, categories) do
    swar_players
    |> Enum.reduce_while({:ok, []}, fn p, {:ok, acc} ->
      case %Player{} |> Player.changeset(player_attrs(p, categories)) do
        %{valid?: true} = changeset ->
          {:cont, {:ok, [Ecto.Changeset.apply_changes(changeset) | acc]}}

        changeset ->
          {:halt, {:error, changeset_error_text(changeset)}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp changeset_error_text(changeset) do
    Enum.map_join(changeset.errors, "; ", fn {field, {msg, _}} -> "#{field} #{msg}" end)
  end

  # Individual writes inside the transaction (players, rounds…) don't
  # broadcast - the transaction may still roll back, and even on success a
  # subscriber could otherwise query the database before the writes are
  # committed. Broadcast once, for real, after commit.
  #
  # Status is derived the same way, and for the same reason: `refresh_status!/1`
  # runs *after* the transaction commits (so it sees the imported rounds/
  # results as they actually landed) and outside `with_broadcast_suppressed`
  # (so its own broadcast, if the status actually changed, isn't swallowed).
  # A fully-scored import (every paired round has every result) lands on
  # "finished"; a partial one lands on "running" - see
  # `PairingsEngine.Tournaments.refresh_status!/1`.
  defp run_import(data, scope) do
    result =
      Tournaments.with_broadcast_suppressed(fn ->
        Repo.transaction(fn ->
          case do_import(data, scope) do
            {:ok, tournament, warnings} ->
              # A file of an event that may already have been reported:
              # nothing is sent from this copy until an arbiter confirms
              # it is the one that reports (audit 2026-10-01, F5).
              :ok = Tournaments.require_send_confirmation_if_reported(tournament.id, "swar")
              {tournament, warnings}

            {:error, reason} ->
              Repo.rollback(reason)
          end
        end)
      end)

    case result do
      {:ok, {tournament, warnings}} ->
        Tournaments.broadcast_tournament_change(tournament.id, :tournament)
        Tournaments.broadcast_user_tournaments(tournament.user_id)
        {:ok, Tournaments.refresh_status!(tournament.id), warnings}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_import(data, scope) do
    data = prepare_players(data)

    with {:ok, tournament} <- create_tournament(data, scope) do
      players_by_ni = create_players(tournament, data.players, data.categories)
      {data, unpaired} = drop_unpaired_rounds(data)
      create_rounds(tournament, data.players, players_by_ni)
      create_exclusion_pairs(tournament, data, players_by_ni)
      create_exclusion_rule(tournament, data)

      warnings =
        trailing_data_warnings(data) ++
          round_zero_warnings(data) ++
          unpaired_round_warnings(unpaired) ++
          points_adjusted_warnings(tournament, data, players_by_ni) ++
          category_warnings(data.categories) ++
          category_mode_warnings(data) ++
          tiebreak_warnings(data.tiebreaks || []) ++
          type_warnings(data) ++
          swiss321_warnings(data) ++
          round_robin_bye_warnings(data) ++
          xtra_points_warnings(data) ++
          exclusion_warnings(data)

      {:ok, tournament, warnings}
    end
  end

  # Data after the player list (`check_importable/1`): imported without it,
  # and said so plainly - with the size and the SWAR version, which is what
  # support needs to find out what it is.
  defp trailing_data_warnings(%{trailing_bytes: bytes, version: version}) when bytes > 0 do
    [
      gettext(
        "This SWAR file has a part after the player list that OpenPairings cannot read (%{bytes} bytes, saved by SWAR %{version}). The tournament has been imported without it. Every SWAR file checked so far ends with the player list, so this is probably something a newer SWAR stores - teams, for instance: check the tournament against SWAR before pairing, and please report it with the file so that support can be added.",
        bytes: bytes,
        version: version
      )
    ]
  end

  defp trailing_data_warnings(_data), do: []

  # SWAR's "base" files (`strip_round_zero/1`).
  defp round_zero_warnings(%{round_zero_records: n}) when is_integer(n) and n > 0 do
    [
      gettext(
        "This SWAR file is a player list to start tournaments from - its players have an empty round 0 and no rounds. It has been imported as a tournament with its players and no rounds: check its name, dates and settings before pairing round 1."
      )
    ]
  end

  defp round_zero_warnings(_data), do: []

  # SWAR types that import as something slightly different here.
  #
  #   * `SWISS_ACC` (2): SWAR's own accelerated Swiss, which adds points to
  #     groups of players by field size (`EnvoiJAVAFO.cpp`,
  #     `EcrireXXA_AccelereAuto`). Acceleration here is FIDE's Baku method,
  #     which groups and scores differently, so it is not switched on.
  #   * `SWISS_DBL` (1) with an odd number of rounds: match format needs an
  #     even one (`system_attrs/1`), so it is paired one round at a time.
  defp type_warnings(%{tournament: %{type: 2}}) do
    [
      gettext(
        "This SWAR file is an accelerated Swiss. SWAR's acceleration adds points to groups of players by the size of the field; OpenPairings' acceleration is FIDE's Baku method, which works differently, so the tournament has been imported without acceleration. The rounds already played are unaffected; turn on Baku acceleration in Settings if you want it for the rest."
      )
    ]
  end

  defp type_warnings(%{tournament: %{type: 1, nb_rounds: n}}) when rem(n, 2) != 0 do
    [
      gettext(
        "This SWAR file plays every round twice (SWAR's \"double rounds\") but has an odd number of rounds, which match format cannot hold. It has been imported as an ordinary Swiss: any further round is paired on its own."
      )
    ]
  end

  defp type_warnings(_data), do: []

  # A round in which no player's record has an opponent, a result or a table
  # (table -1, or SWAR's absence table 0x4000) is not a round anybody played:
  # it is how SWAR saves the next round between "prepare" and "pair", with
  # the stored `Class` still the tie-break-free order SWAR computes just
  # before pairing. The importer's single-sided path read every such record
  # as an absence. SWAR's own
  # standings ignore it (`GetLastRoundWithResult` wants a result). Imported,
  # it became a finished round with no games and everybody absent, so every
  # player's Buchholz and Sonneborn-Berger counted one more unplayed round
  # (an Article 16 dummy for their own, an adjusted draw for their
  # opponents') and the standings moved. Four files in SWAR's archive, one
  # of them a live 2026 championship, carry such a round - found by
  # tools/swar_rerank.exs. Only trailing ones are dropped: a round like that
  # followed by played rounds is not SWAR's pairing state, and is imported
  # as it stands.
  #
  # "Unpaired" needs at least one record with SWAR's no-table marker (-1): a
  # round whose every record is an absence is left alone - that is an
  # arbiter's entry, not SWAR's pairing state.
  defp drop_unpaired_rounds(data) do
    by_round = data.players |> Enum.flat_map(& &1.rounds) |> Enum.group_by(& &1.round_nr)

    dropped =
      by_round
      |> Map.keys()
      |> Enum.sort(:desc)
      |> Enum.take_while(&unpaired_round?(by_round[&1]))
      |> Enum.sort()

    players =
      Enum.map(data.players, fn p ->
        %{p | rounds: Enum.reject(p.rounds, &(&1.round_nr in dropped))}
      end)

    {%{data | players: players}, dropped}
  end

  defp unpaired_round?(records) do
    Enum.all?(records, &(&1.table in [-1, 0, 0x4000] and &1.advers in [0, -1] and &1.result == 0)) and
      Enum.any?(records, &(&1.table == -1))
  end

  defp unpaired_round_warnings([]), do: []

  defp unpaired_round_warnings(rounds) do
    [
      gettext(
        "Round %{rounds} was not imported: nobody in it has a game, a bye or a result, which is how SWAR saves a round it has not paired yet. Pair it here.",
        rounds: Enum.join(rounds, ", ")
      )
    ]
  end

  # `scoring_attrs/1`'s round-robin clause always scores a pairing-allocated
  # bye at a full point now, mirroring SWAR's own forcing rather than the
  # file's stored `ByeValue` - see the comment there and
  # docs/swar-source-audit-pass2-2026-09-09.md §3 (F11). Only worth saying
  # when the file actually has one: an even-sized round robin has none, and
  # a warning nobody's tournament ever triggers is a warning nobody reads.
  defp round_robin_bye_warnings(data) do
    if map_tournament_type(data.tournament.type) == "roundrobin" and
         any_pairing_allocated_bye?(data) do
      [
        "This round robin has an odd number of players, so at least one round " <>
          "leaves someone without an opponent. SWAR forces that bye to a full " <>
          "point the instant the file is opened, no matter what its own stored " <>
          "bye value says - this import mirrors SWAR rather than the file, so " <>
          "the imported bye is worth a full point here even though FIDE does " <>
          "not award one for a round-robin bye. Check the standings against " <>
          "SWAR's own crosstable if the tournament's own regulations promised " <>
          "otherwise."
      ]
    else
      []
    end
  end

  # The SWAR 3-2-1 result codes this app has no equivalent for (see the
  # comment on `swiss321?/1`): a WIN_BYE or DRAW_BYE (0 points in SWAR, plus
  # presence - Utils.cpp:1206-1222, Classement.cpp:144-151), a DRAW_FF
  # (the draw value without presence, which reads back as a played draw)
  # and an absence carrying a result. SWAR's own 3-2-1 dialog writes none of
  # them, so a real file rarely does; when one does, the arbiter is told
  # which rounds to check rather than shown a total that silently differs.
  defp swiss321_warnings(%{tournament: t} = data) do
    if swiss321?(t) do
      rounds =
        for p <- data.players,
            r <- p.rounds,
            swiss321_unmatched?(r),
            uniq: true,
            do: r.round_nr

      case Enum.sort(rounds) do
        [] ->
          []

        rounds ->
          [
            gettext(
              "This 3-2-1 file has rounds (%{rounds}) with a bye scored as a win or a draw, a draw by forfeit, or an absence with a result. SWAR scores those in a way OpenPairings has no equivalent for, so check those rounds' points against SWAR's own standings.",
              rounds: Enum.join(rounds, ", ")
            )
          ]
      end
    else
      []
    end
  end

  defp swiss321_unmatched?(r) do
    result_class(r.result) in [:win_bye, :draw_bye, :draw_ff] or
      (r.table == @table_absent and result_class(r.result) not in [:none, :loss_bye])
  end

  defp any_pairing_allocated_bye?(data) do
    Enum.any?(data.players, fn p ->
      Enum.any?(p.rounds, &(result_class(&1.result) == :win_bye))
    end)
  end

  # SWAR's `ExtraPts` are a manual-acceleration input, not only a display
  # number: `AssignExtraPointsNextRound` copies each player's stored
  # `ExtraPts` into every round record (`XtraPoints.cpp:268-288`), and
  # `EcrireXXA_AccelereManuel` (`EnvoiJAVAFO.cpp:601-634`) writes them as
  # `XXA` lines in the `.trn` SWAR hands to JaVaFo - so JaVaFo brackets by
  # score-plus-acceleration for the next round paired inside SWAR.
  # This used to warn that OpenPairings paired without them. It pairs with
  # them now - the import sets acceleration mode (`extra_points_attrs/1`)
  # and each round's `XtraPts` becomes that round's recorded virtual points
  # (`insert_round/4`) - so the notes below say what was carried over rather
  # than what was lost.
  #
  # Only meaningful for an ordinary Swiss: SWAR itself zeroes `ExtraPts` on
  # load for round robin and 3-2-1 (`TournoiReadWrite.cpp:666-667` - see
  # `scoring_attrs/1`'s round-robin clause and §5.3), so warning there too
  # would blame this app for a number SWAR itself already discarded before
  # its own pairing engine ever saw it.
  #
  # The rounds already IN the file import correctly regardless of any of
  # this - what the warning is about is pairing any FURTHER round from
  # here on, which is the only place the acceleration would have mattered.
  # See docs/swar-source-audit-pass2-2026-09-09.md §5.4 (F13).
  defp xtra_points_warnings(data) do
    t = data.tournament

    if map_tournament_type(t.type) == "roundrobin" or swiss321?(t) do
      []
    else
      any_player_extra? = Enum.any?(data.players, &(&1.extra_pts != 0))
      band_populated? = Enum.any?(data.xtra_points, fn {pts, elo} -> pts != 0 or elo != 0 end)

      cond do
        any_player_extra? ->
          [
            gettext(
              "This file carries SWAR XtraPoints. They are imported as acceleration points, which is how SWAR uses them: every round they go to the pairing engine as virtual points, and they count in the standings (Settings, Extra points, where you can also take them off part-way). The rounds already in the file keep the virtual points SWAR paired them with."
            )
          ]

        band_populated? ->
          [
            gettext(
              "This file carries a SWAR XtraPoints table, which SWAR uses to give players extra points for acceleration. No player has any yet, so nothing changes. The table is imported as the acceleration bands under Settings, Extra points: \"Apply bands to players\" there gives players their points, as SWAR's \"Assign\" does."
            )
          ]

        true ->
          []
      end
    end
  end

  # SWAR's own arbiter-entered correction (appeals, deductions - file version
  # >= v6.49's points_adjusted field) can't be reconstructed by replaying
  # pairings/byes the way our own standings always are, so it's silently
  # discarded on import unless we say something. Mirrors
  # TrfImport.points_warnings/3's declared-vs-recomputed cross-check.
  #
  # Gated on the file actually carrying points_adjusted at all (see
  # `has_points_adjusted?/1`) - files from outside that window hardcode it to
  # 0 regardless of a player's real score (see parse_player/2), so comparing
  # that against real computed points would produce a false-positive warning
  # for nearly every player.
  # `version_gte?/2` is a plain private function (not a `defguard`), so this
  # is a single-clause function with an `if` rather than two pattern-matched
  # clauses guarded on it.
  defp points_adjusted_warnings(tournament, data, players_by_ni) do
    if has_points_adjusted?(data.version) do
      # `presence: false` because SWAR's stored `points_adjusted` is
      # `Joueur.Points` - result points ONLY. The 3-2-1 presence point lives
      # in a separate accumulator (`SpecialPts`, Classement.cpp:1390) that is
      # added at display time (`Points + ExtraPts + SpecialPts`,
      # Classement.cpp:1425) and never written to the file.
      #
      # Comparing our full standings total against it would warn for every
      # single player in every 3-2-1 tournament - the totals genuinely
      # differ, by one point per round attended, and neither side is wrong.
      # This reconciles like with like.
      computed_by_id =
        tournament
        |> Standings.standings(presence: false)
        |> Map.new(fn e -> {e.player.id, e.points} end)

      data.players
      |> Enum.map(fn p ->
        with player when not is_nil(player) <- players_by_ni[p.ni],
             computed when not is_nil(computed) <- computed_by_id[player.id] do
          adjusted = p.points_adjusted / 4.0

          if abs(adjusted - computed) > 0.01 do
            %{player_name: player.name, swar_adjusted_points: adjusted, computed_points: computed}
          end
        end
      end)
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  end

  ## ---------- FIDE id matching for players SWAR left blank ----------

  # `import_file/2`'s non-interactive best-effort path: adopt an
  # unambiguous match, otherwise leave the player exactly as SWAR had it
  # (no `fide_id`) - there's nobody to ask.
  defp best_effort_fide_match(p, cache) do
    case resolve_fide_match(p, cache) do
      {:matched, resolved} -> resolved
      _ -> p
    end
  end

  # SQLite refuses a statement past `SQLITE_MAX_VARIABLE_NUMBER` bound
  # parameters, so the `in` below is fed in chunks. Well under the limit any
  # build enforces, and far above the number of federations a real file names.
  @federations_per_query 400

  # Every DISTINCT federation among the players SWAR left with no FIDE id
  # (`mat_fide == 0`) in ONE query, not one query each -
  # `fide_candidates/2` below reads from this instead of re-querying for a
  # federation an earlier player in the same file already covered.
  #
  # It used to issue that query per federation, and `fide_players.federation`
  # had no index, so each one was a sequential scan of the whole 1.9M-row
  # rating list. Nothing bounds how many distinct country strings an uploaded
  # file names - it is free text per player - so a file naming 39,000 of them
  # bought 39,000 full scans before a single row was written. The index
  # (`20260909100000_index_fide_player_federation`) fixes the per-query cost
  # and this fixes the multiplier; the cache's contents are unchanged.
  defp build_fide_candidates_cache(players) do
    federations =
      players
      |> Enum.filter(&(&1.mat_fide == 0))
      |> Enum.map(&Federation.normalize(&1.country))
      |> Enum.uniq()

    found =
      federations
      |> Enum.chunk_every(@federations_per_query)
      |> Enum.reduce(%{}, fn chunk, acc ->
        from(f in FidePlayer, where: f.federation in ^chunk)
        |> Repo.all()
        |> Enum.group_by(& &1.federation)
        |> then(&Map.merge(acc, &1))
      end)

    # Keyed by every federation asked about, including the ones nothing
    # matched, so the map's shape does not depend on what the list holds.
    Map.new(federations, &{&1, Map.get(found, &1, [])})
  end

  # `mat_fide == 0` means SWAR itself has no FIDE id on file for this
  # player - the only case worth searching the local FIDE database for.
  # A player SWAR already gave a FIDE id to is never looked up or
  # second-guessed here, however different their `mat_fide` might be from
  # what the FIDE database currently has on file.
  defp resolve_fide_match(%{mat_fide: 0} = p, cache) do
    candidates = fide_candidates(p, cache)

    exact =
      Enum.filter(
        candidates,
        &(&1.birth_year == birth_year(p.birth) and not is_nil(&1.birth_year))
      )

    case exact do
      [one] ->
        {:matched, Map.put(p, :fide_match, one) |> Map.put(:mat_fide, one.fide_id)}

      _ ->
        {:unresolved, candidates ++ other_federation_candidates(p, candidates)}
    end
  end

  defp resolve_fide_match(_p, _cache), do: :not_applicable

  # Same name (case-insensitive, "Last, First" as both SWAR and the local
  # FIDE database already store it) + same federation, *any* birth year -
  # this is both the pool `resolve_fide_match/1` narrows down to an exact
  # birth-year match, and the candidate list shown to the user when it
  # can't (so "right person, wrong/missing year on one side" still shows up
  # as a one-click choice instead of falling through to "no match").
  defp fide_candidates(p, cache) do
    name = normalize_name_for_match(p.name)
    federation = Federation.normalize(p.country)

    cache
    |> Map.get(federation, [])
    |> Enum.filter(&(normalize_name_for_match(&1.name) == name))
  end

  # Diacritics are folded, not just case: SWAR carries whatever the arbiter
  # typed (CP-1252, so "Müller" round-trips fine) while the FIDE list is
  # inconsistent about them, and a plain downcase makes "Müller"/"Muller" two
  # different people - the player then shows up with no candidates at all,
  # which reads as "not in FIDE" rather than "spelled differently". Same
  # folding the `fide_players_fts` index already uses (`remove_diacritics 2`),
  # so `other_federation_candidates/2` and this agree on what "same name"
  # means.
  defp normalize_name_for_match(name) do
    name
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.replace(~r/\s+/, " ")
  end

  # Same name, ANY federation - for the candidate list only, never for
  # auto-adopt.
  #
  # `fide_candidates/2` scopes to the player's own federation, which is right
  # for adopting a match unattended but leaves a transferred player (or one
  # whose SWAR country simply disagrees with FIDE's) with an empty list and no
  # way to resolve them by hand. Widening only the list keeps the "never
  # silently guessed" rule intact: a cross-federation hit still has to be
  # picked by a human.
  #
  # Goes through the FTS index rather than scanning ~1.9M rows: it already
  # tokenises and folds diacritics the same way `normalize_name_for_match/1`
  # does, so it's a cheap prefilter that the exact comparison below then
  # confirms.
  defp other_federation_candidates(p, already_found) do
    name = normalize_name_for_match(p.name)
    seen = MapSet.new(already_found, & &1.fide_id)

    name
    |> String.replace(",", " ")
    |> String.split(~r/\s+/, trim: true)
    |> fide_players_matching_tokens()
    |> Enum.reject(&MapSet.member?(seen, &1.fide_id))
    |> Enum.filter(&(normalize_name_for_match(&1.name) == name))
  end

  defp unresolved_entry(p, candidates) do
    %{
      ni: p.ni,
      name: p.name,
      federation: Federation.normalize(p.country),
      birth_year: birth_year(p.birth),
      candidates:
        Enum.map(candidates, fn c ->
          %{
            fide_id: c.fide_id,
            name: c.name,
            federation: c.federation,
            birth_year: c.birth_year,
            title: c.title,
            standard_rating: c.standard_rating
          }
        end)
    }
  end

  # Applies the caller's chosen resolution (from `commit_import/3`) for a
  # player that came back from `prepare_import/1` still unresolved. Only
  # ever consulted for players SWAR had no `mat_fide` for in the first
  # place (see `resolve_fide_match/1`) - a player that already had one, or
  # that `prepare_import/1` already auto-matched, was never added to
  # `unresolved`, so there's nothing in `resolutions` to look up for them
  # and this is a no-op.
  defp apply_resolution(%{mat_fide: 0} = p, resolutions) do
    case Map.get(resolutions, p.ni) do
      fide_id when is_integer(fide_id) and fide_id > 0 ->
        case Repo.get(FidePlayer, fide_id) do
          nil -> p
          fp -> p |> Map.put(:fide_match, fp) |> Map.put(:mat_fide, fp.fide_id)
        end

      _ ->
        p
    end
  end

  defp apply_resolution(p, _resolutions), do: p

  ## ---------- Tournament ----------

  defp create_tournament(data, scope) do
    attrs =
      data
      |> tournament_attrs()
      |> resolve_official_fide_ids()

    # `swar_settings` is not cast (no form may write it); set on the struct.
    %Tournament{user_id: scope && scope.user.id, swar_settings: swar_settings(data)}
    |> Tournament.changeset(attrs)
    |> Repo.insert()
  end

  ## ---------- Arbiters / officials ----------

  # Titles SWAR prefixes an official's name with. Arbiter (IA/FA/NA/…) and
  # organizer (IO/NO) grades both show up in these fields, and FIDE's own
  # database stores the name without them, so they have to come off before
  # anything can be matched - or written into an IT3/FA1 name cell.
  @official_titles ~w(IA FA NA IO NO FST FI FT DI SI NI)

  @doc false
  # SWAR writes officials as "TITLE First Last", comma-separating multiple
  # people in one field ("IA Sylvin De Vet, NA Marc Van Dyck"). That's the
  # opposite convention to FIDE's "Last, First", so a comma here is a person
  # boundary, not a name boundary - safe to split on precisely because SWAR
  # never stores the surname-first form in these fields.
  def split_officials(text) do
    text
    |> to_string()
    |> String.split(",")
    |> Enum.map(&strip_arbiter_title/1)
    |> Enum.reject(&(&1 == ""))
  end

  @doc false
  def strip_arbiter_title(name) do
    name
    |> to_string()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.drop_while(&(String.upcase(String.trim_trailing(&1, ".")) in @official_titles))
    |> Enum.join(" ")
  end

  # Deputies parsed out of SWAR's single free-text field into the numbered
  # `deputyN_name` slots the IT3 form (B62-B69) and the norms page expect.
  # Names only - FIDE ids need the database, so they're filled in by
  # `resolve_official_fide_ids/1` on the persisting path.
  defp swar_officials(t) do
    t.arbiter2
    |> split_officials()
    |> Enum.take(4)
    |> Enum.with_index(1)
    |> Map.new(fn {name, n} -> {"deputy#{n}_name", name} end)
  end

  # SWAR's [TOURNOI] FIDE block holds up to 16 homologation entries, each with
  # its own tournament id; a plain event has one, a festival rated in several
  # sections has several. Blank ones are zeroed, so take the distinct non-zero
  # ids in file order. `event_code` is a single free-text field on both our
  # schema and the FIDE forms, so multiples are joined rather than dropped -
  # the arbiter can then delete whichever doesn't apply, which is recoverable,
  # whereas silently keeping only the first is not.
  defp swar_event_code(t) do
    t
    |> Map.get(:fide_ids, [])
    |> Enum.map(& &1.id)
    |> Enum.reject(&(&1 in [0, nil]))
    |> Enum.uniq()
    |> Enum.map_join(", ", &to_string/1)
  end

  # Fills in `chief_arbiter_fide_id` / `deputyN_fide_id` for any official whose
  # name resolves to exactly one FIDE entry - AND rewrites that official's
  # name to FIDE's own "Last, First" form, same as picking that result by
  # hand from the arbiter combobox would (`NormsLive.apply_arbiter_pick/3`).
  # Without the name rewrite, SWAR's own "First Last" spelling stuck around
  # even after a confident match, and `Norms.Forms.fide_display_name/1`
  # (which needs the "Last, First" comma to know where the surname is) had
  # nothing to work with - the auto-matched id was right, but the printed
  # report still didn't put the surname in FIDE house-style capitals.
  #
  # Only ever runs on the persisting path - `tournament_attrs/1` is shared
  # with the pure `build_structs/1` builder, which must not touch the
  # database.
  defp resolve_official_fide_ids(attrs) do
    officials = Map.get(attrs, :officials) || %{}

    officials =
      1..4
      |> Enum.reduce(officials, fn n, acc ->
        put_matched_official(acc, "deputy#{n}_name", "deputy#{n}_fide_id")
      end)

    case match_official_fide_player(Map.get(attrs, :chief_arbiter)) do
      nil ->
        Map.put(attrs, :officials, officials)

      fp ->
        attrs
        |> Map.put(:chief_arbiter, fp.name)
        |> Map.put(:officials, Map.put(officials, "chief_arbiter_fide_id", to_string(fp.fide_id)))
    end
  end

  defp put_matched_official(officials, name_key, id_key) do
    case match_official_fide_player(Map.get(officials, name_key)) do
      nil ->
        officials

      fp ->
        officials
        |> Map.put(name_key, fp.name)
        |> Map.put(id_key, to_string(fp.fide_id))
    end
  end

  @doc false
  # An official's name matched against the FIDE database, or `nil` unless
  # exactly one entry matches - same "never silently guess" rule the player
  # matcher follows.
  #
  # Compares an order-independent token set, because the two sides disagree on
  # word order by convention: SWAR has "Sylvin De Vet", FIDE has "De Vet,
  # Sylvin". Sorting the (diacritic-folded) tokens makes those equal without
  # having to guess which words are the surname.
  #
  # Public (rather than the `defp` this started as) so `ToolsNormsLive` can
  # reuse the exact same matching rules for its own read-only FIDE lookup on
  # SWAR/TRF officials prefill - that page never persists a `Tournament`, so
  # it can't go through `resolve_official_fide_ids/1` below, but wants
  # identical match/no-match behavior rather than a second implementation
  # that could quietly drift from this one.
  def match_official_fide_player(name) do
    case official_name_key(name) do
      [] ->
        nil

      tokens ->
        tokens
        |> fide_players_matching_tokens()
        |> Enum.filter(&(official_name_key(&1.name) == tokens))
        |> case do
          [one] -> one
          _ -> nil
        end
    end
  end

  defp official_name_key(name) do
    name
    |> normalize_name_for_match()
    |> String.replace(",", " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.sort()
  end

  # FTS prefilter shared by the official matcher and
  # `other_federation_candidates/2` - the index folds diacritics the same way
  # `normalize_name_for_match/1` does, so it narrows ~1.9M rows to a handful
  # that the caller then confirms exactly.
  defp fide_players_matching_tokens([]), do: []

  defp fide_players_matching_tokens(tokens) do
    match = Enum.map_join(tokens, " AND ", &"\"#{String.replace(&1, "\"", "")}\"")

    %{rows: rows} =
      Repo.query!(
        "SELECT fide_id FROM fide_players_fts WHERE fide_players_fts MATCH ? LIMIT 50",
        [match]
      )

    ids =
      rows
      |> List.flatten()
      |> Enum.map(fn
        id when is_integer(id) -> id
        id when is_binary(id) -> String.to_integer(id)
      end)

    if ids == [], do: [], else: Repo.all(from(f in FidePlayer, where: f.fide_id in ^ids))
  rescue
    # A checkout without the FTS migration (or a hand-built test DB) must not
    # take the whole import down over an autofill nicety.
    _ -> []
  end

  # Shared by `create_tournament/2` (persisting) and `build_tournament_struct/1`
  # (pure, no Repo) - the one place SWAR's [TOURNOI]/[DATES]/[TIE_BREAK]/
  # [CATEGORIES] header fields map onto `Tournament.changeset/2` attrs.
  defp tournament_attrs(data) do
    t = data.tournament

    %{
      name: t.name,
      type: map_tournament_type(t.type),
      swar_guid: if(data.guid in [nil, ""], do: nil, else: data.guid),
      # SWAR's [TOURNOI] header has exactly one free-text place field (`City`
      # here); there is no separate venue/address field to pull from. Setting
      # `venue` to the same value made `Norms.Forms.place/1` (which joins
      # `[venue, city]`) print the club name twice, e.g. "K.A. Geraardsbergen,
      # K.A. Geraardsbergen" - so `venue` is left unset (its schema default,
      # "") for the arbiter to fill in by hand if the report needs a venue
      # distinct from the city.
      city: t.city,
      federation: map_federation(t.federation),
      start_date: normalize_date(t.start_date),
      end_date: normalize_date(t.end_date),
      organizer: t.organizer,
      chief_arbiter: strip_arbiter_title(t.arbiter1),
      # Kept raw: this is the free-text field shown as-is on reports/exports,
      # and the parsed-out individuals live in `officials` below.
      deputy_arbiter: t.arbiter2,
      event_code: swar_event_code(t),
      officials: swar_officials(t),
      rounds_count: max(t.nb_rounds, 1),
      tiebreaks: map_tiebreaks(data.tiebreaks),
      standard: map_standard(t.tournoi_std),
      # `Cadence` (the standard-cadence dropdown pick) wins when set; falls
      # back to `Cadence_Other`'s free text only for the dropdown's own
      # "autre cadence" pick - see `cadence_label/2`.
      rate_of_play: cadence_label(t.tournoi_std, t.cadence) || t.cadence_other,
      organizer_club_number: t.club_or_logo,
      round_dates: Enum.map(data.dates, &normalize_date/1),
      categories: map_categories(data.categories),
      swar_category_type: two_axis_type(data.categories),
      swar_category_axis2: axis2_names(data.categories),
      # `AbsValue` (manual §4.2 field 92, general [TOURNOI] header, fields
      # 91/96 group alongside `ByeValue`/`FF_Value`) - the points paid for a
      # plain absence (`byes` row `type: "absent"`). Unlike `presence_value`
      # (SW321_Pre, only mapped inside `scoring_attrs/1`'s `type == 3`
      # clause), this applies to EVERY SWAR import regardless of tournament
      # type, so it's mapped here unconditionally rather than in
      # `scoring_attrs/1`.
      #
      # Raw `abs_value` is a plain UI checkbox ("½ point" for absence, per
      # SWAR's own `TOptions.cpp`: `Tournoi.AbsValue =
      # mTO_AbsValue.GetCheck()`), so it's 0 (unchecked) or 1 (checked) -
      # NOT "0 or 5". A PREVIOUS version of this clause checked `== 5`,
      # which happened to "pass" against every synthetic test fixture (they
      # all hardcoded the test input as 5) but silently mapped every real
      # SWAR file with the box actually checked - raw byte 1 - to 0.0
      # instead of 0.5, i.e. exactly backwards from what the tournament was
      # configured to pay. Confirmed against SWAR's own source
      # (`Swar.h`'s `enum USE_POINTS { PTS_1, PTS_5, PTS_0 }` gives PTS_0
      # the ordinal value 2, not 0 or 5 either - the stale `// 0 ou 5`
      # comment on the struct field is describing an unrelated, pre-v4.21
      # `AbsValueOld` encoding this current field replaced) and against a
      # real tournament file with the box checked (raw `abs_value == 1`).
      abs_value: if(t.abs_value != 0, do: 0.5, else: 0.0),
      # `AbsNbFois`/`AbsJusque` - the two caps SWAR's own source
      # (`GetSpecialAbsValue`/`AbsentIsLoss` in Utils.cpp) applies ON TOP
      # of `AbsValue`, easy to miss since they're separate fields
      # immediately after it rather than folded into it. See
      # `PairingsEngine.Tournaments.Tournament`'s field docs for exactly
      # what each caps, and `PairingsEngine.Standings.bye_points/4` for
      # where they're actually enforced. Mapped as plain ints - unlike
      # `abs_value`, 0 is a real, meaningful (if degenerate) SWAR value
      # here (e.g. `abs_jusque: 0` legitimately means "no round qualifies"
      # rather than "uncapped") - SWAR itself forces both to 0 when the
      # checkbox above is unchecked, which is also what makes every round
      # fail the `abs_jusque` cap in that case (see
      # `PairingsEngine.Standings.round_capped?/2`) without needing a
      # separate "is this feature even on" flag.
      abs_jusque: t.abs_jusque,
      abs_nbfois: t.abs_nbfois,
      # SWAR counts every round before a player was added as an absence:
      # `JoueurInit` (Joueur.cpp:581-596) gives the new player a
      # `TABLE_ABSENT` record for each round already paired, which
      # `GetPoints` pays at `AbsValue` under both caps and `GetNbAbsence`
      # counts (Utils.cpp:1254-1257, 1159-1170, 1102-1118). The file already
      # carries those records - they import as "absent" rows - so this
      # decides what a round before a player's start round counts as for
      # players added here afterwards. A 3-2-1 event is the exception:
      # SWAR's `GetPoints` scores it by `ConvertPoint321` and never pays
      # `AbsValue` (Utils.cpp:1232-1234).
      #
      # And a file in which somebody's round 1 is neither a game, a bye nor
      # an absence was not written that way: SWAR itself never leaves a
      # round before a player joined empty. This app's own export does, for
      # a tournament that has the setting off - so that is the answer the
      # file gives, and reading it back on would pay those rounds after all.
      late_entry_absences: t.type != 3 and not empty_round_one?(data.players)
    }
    |> Map.merge(scoring_attrs(t))
    |> Map.merge(system_attrs(t))
    |> Map.merge(category_mode_attrs(data))
    |> Map.merge(extra_points_attrs(data))
    |> Map.merge(fide_attrs(t))
    |> Map.merge(initial_colour_attrs(t))
  end

  # A player whose round 1 imports as nothing at all (`single_sided/2`'s
  # `:nothing`) but who has something - a game, a bye, an absence - in a
  # later round: here that reads as a player who joined late, and the file
  # scored the rounds before it as nothing. A player with nothing anywhere
  # never joined, and scores nothing whatever the setting says.
  defp empty_round_one?(players) do
    Enum.any?(players, fn p ->
      {first, later} = Enum.split_with(p.rounds, &(&1.round_nr == 1))

      match?([_], first) and nothing_record?(hd(first)) and
        Enum.any?(later, &(not nothing_record?(&1)))
    end)
  end

  defp nothing_record?(r),
    do:
      r.advers in [0, -1] and result_class(r.result) == :none and
        r.table not in [@table_absent, @table_bye]

  # `ApparOrder` - "Couleur du Nr.1 à la première ronde" (`TOptions.cpp`,
  # used by `EnvoiJAVAFO.cpp` for round 1): 0 the top seed has White, 1
  # Black, 2 drawn at random. That is the initial colour (C.04.3 Article
  # 5.1), which the engine also reads in later rounds. A random draw SWAR
  # already made is not in the file; left as "lot", the engine reads it off
  # the imported boards, as it does for any tournament paired before the
  # draw was recorded (`Tournament.effective_initial_colour/1`). A round
  # robin's `ApparOrder` means something else (how its table is seeded) and
  # is only kept for the export.
  defp initial_colour_attrs(%{type: type}) when type in [4, 5, 6], do: %{}

  defp initial_colour_attrs(%{appar_order: 0}), do: %{initial_colour: "white"}
  defp initial_colour_attrs(%{appar_order: 1}), do: %{initial_colour: "black"}
  defp initial_colour_attrs(_t), do: %{}

  ## ---------- Categories: on, and SWAR's "separate categories" ----------
  #
  # A file that defines categories imports with them switched on - the
  # Categories page, the standings' category selector and pairing by
  # category all read `categories_enabled`, and an import that left it off
  # showed a tournament with categories on every player and a Categories
  # page saying "Off".
  #
  # SWAR's `CatSepares` ("Appariements séparés", `Swar.h`) makes each
  # category a tournament of its own: a Swiss pairs each category apart
  # (`EnvoiJAVAFO.cpp` writes one JaVaFo file per category), a round robin
  # runs one Berger table per category (`PairingRobin.cpp`), and
  # `CalculLeClassement` ranks each category on its own, direct encounter
  # included (`Classement.cpp`, `CmpCla` and `TieBetween`). Here that is
  # `pair_by_category` and `categories_ranked_separately`. Pairing by
  # category is not combined with match format or Baku here
  # (`Tournament.validate_pair_by_category/1`), so a SWAR "double rounds"
  # Swiss with separate categories keeps its separate ranking and is paired
  # as one field - `category_mode_warnings/1` says so.
  defp category_mode_attrs(%{categories: categories, tournament: t}) do
    case map_categories(categories) do
      [] ->
        %{}

      _names ->
        separate? = t.cat_separes != 0

        %{categories_enabled: true}
        |> Map.merge(
          if separate?,
            do: %{
              categories_ranked_separately: true,
              pair_by_category: t.type != 1
            },
            else: %{}
        )
    end
  end

  defp category_mode_warnings(%{categories: categories, tournament: t}) do
    if t.cat_separes != 0 and t.type == 1 and map_categories(categories) != [] do
      [
        gettext(
          "This SWAR file pairs each category on its own, and plays every round twice (SWAR's \"double rounds\"). OpenPairings does not pair by category together with match format, so its categories are ranked separately but any further round is paired as one field. Check the pairings before publishing them."
        )
      ]
    else
      []
    end
  end

  ## ---------- Extra points ----------
  #
  # SWAR ranks a Swiss on points plus `ExtraPts` (`CalculLeClassement`:
  # `Points + ExtraPts + SpecialPts`), so a file that gives any player extra
  # points imports with `count_extra_points` on and ranks as SWAR ranked it.
  # A round robin or a 3-2-1 event has no extra points in SWAR - its loader
  # zeroes them (`TournoiReadWrite.cpp`: `if (IsRobin(...) ||
  # IsSwiss321(...)) p.ExtraPts = 0`), and so does this import
  # (`player_attrs/2`).
  #
  # And SWAR's extra points are an ACCELERATION - handed to its pairing
  # engine as `XXA` virtual points every round - which is this app's
  # acceleration mode (docs/extra-points.md), so every SWAR file imports in
  # that mode. Its band table converts as well: SWAR's bands pay players at
  # or above a rating, and so do this mode's (`swar_bands/1`).
  defp extra_points_attrs(data) do
    base = %{extra_points_mode: "acceleration"}

    if extra_points_apply?(data.tournament) do
      base
      |> Map.put(:extra_points_bands, swar_bands(data.xtra_points))
      |> Map.merge(
        if Enum.any?(data.players, &(&1.extra_pts != 0)),
          do: %{count_extra_points: true},
          else: %{}
      )
    else
      base
    end
  end

  @doc """
  SWAR's `[XTRA_POINTS]` table - four `{points x 4, Elo}` slots - as an
  `extra_points_bands` string for acceleration mode ("2000:1, 1800:0.5").

  A slot with Elo 0 is left out: SWAR's `AssignExtraPoints` stops at the
  first one (`if (XtraPoints.Elo[i] == 0) break;`), so it never gives
  anybody anything, where "0:bonus" here would give everybody the bonus.
  Every other slot is SWAR's rule exactly: the highest Elo at or below the
  player's gets its points, zero points included.
  """
  def swar_bands(slots) do
    slots
    |> Enum.filter(fn {_pts, elo} -> elo > 0 end)
    |> Enum.uniq_by(fn {_pts, elo} -> elo end)
    |> Enum.sort_by(fn {_pts, elo} -> elo end)
    |> Enum.map_join(", ", fn {pts, elo} -> "#{elo}:#{format_quarter_points(pts)}" end)
  end

  defp format_quarter_points(pts) do
    points = pts / 4
    if points == Float.round(points, 0), do: Integer.to_string(trunc(points)), else: "#{points}"
  end

  defp extra_points_apply?(t),
    do: map_tournament_type(t.type) != "roundrobin" and not swiss321?(t)

  ## ---------- FIDE homologation ----------
  #
  # `FideHomologation` is the "homologated for FIDE" tickbox, and the
  # 16-entry block beside it SWAR's per-round FIDE tournament ids - "id
  # 89495 for rounds 1-3, this other one for rounds 4-9" - which is
  # `fide_id_ranges` here, the same model. An entry without an id, or with
  # a round range that runs backwards or overlaps an earlier one, is left
  # out: this app refuses such a range, and one bad entry must not stop the
  # import. `event_code` keeps every id, as before (`swar_event_code/1`),
  # and the block itself travels back out untouched (`swar_settings/1`).
  defp fide_attrs(t) do
    ranges =
      t
      |> Map.get(:fide_ids, [])
      |> Enum.filter(&(is_integer(&1.id) and &1.id > 0 and &1.de >= 1 and &1.aa >= &1.de))
      |> Enum.sort_by(& &1.de)
      |> Enum.reduce([], fn r, acc ->
        case acc do
          [prev | _] when r.de <= prev.aa -> acc
          _ -> [r | acc]
        end
      end)
      |> Enum.reverse()
      |> Enum.map(fn r ->
        %{"fide_tournament_id" => to_string(r.id), "from_round" => r.de, "to_round" => r.aa}
      end)

    %{fide_homologated: t.fide_homolog != 0}
    |> Map.merge(if ranges != [], do: %{fide_id_ranges: ranges}, else: %{})
  end

  ## ---------- SWAR's own settings, kept for the export ----------

  @doc """
  The `[TOURNOI]`, `[TIE_BREAK]`, `[CATEGORIES]` and `[XTRA_POINTS]` values
  a SWAR file carries that OpenPairings has no setting for - or maps onto
  one of its own in a way that cannot be undone - exactly as the file had
  them, for `Tournament.swar_settings`. `SwarExport` writes each back where
  the tournament still agrees with it, so a tournament that came from SWAR
  goes back to SWAR with the settings it arrived with: the rating SWAR pairs
  and seeds by (`elo_used`, `elo_equal`), the first table number, the
  rating-report round ranges, the pairing colour order, SWAR's XtraPoints
  band table (which pays at or above a rating, where this app's bands pay
  below one), its exact tournament type (an accelerated Swiss is a plain
  Swiss here), its full tie-break list (three of SWAR's have no counterpart
  here), the chief arbiter with their title, and the rest listed below.
  String keys, integers and strings only, so it stores as JSON as it is.
  """
  def swar_settings(data) do
    t = data.tournament

    %{
      "version" => data.version,
      "mac" => data.mac,
      "type" => t.type,
      "federation" => t.federation,
      "arbiter1" => t.arbiter1,
      "cadence" => t.cadence,
      "cadence_other" => t.cadence_other,
      "frbe_from" => t.frbe_from,
      "frbe_to" => t.frbe_to,
      "fide_from" => t.fide_from,
      "fide_to" => t.fide_to,
      "cat_separes" => t.cat_separes,
      "elo_ou_pays" => t.elo_ou_pays,
      "fide_homolog" => t.fide_homolog,
      # The entries in use only: a v7 file may hold fifteen or sixteen
      # (`parse_tournoi_section/2`), the export always writes sixteen.
      "fide_ids" =>
        t
        |> Map.get(:fide_ids, [])
        |> Enum.map(&[&1.de, &1.aa, &1.id])
        |> Enum.reject(&(&1 == [0, 0, 0])),
      "fide_arb1" => t.fide_arb1,
      "fide_arb2" => t.fide_arb2,
      "fide_remarks" => t.fide_remarks,
      "sw_elo_r1" => t.sw_elo_r1,
      "sw_amer_presence" => t.sw_amer_presence,
      "plusieurs" => t.plusieurs,
      "first_table" => t.first_table,
      # `SW321_PreBye` is absent before v6.03, where it is SWAR's 0.
      "sw321" => [
        t.sw321_win,
        t.sw321_nul,
        t.sw321_los,
        t.sw321_bye,
        t.sw321_pre,
        t.sw321_prebye || 0
      ],
      "elo_used" => t.elo_used,
      "tb_personel" => t.tb_personel,
      "appar_order" => t.appar_order,
      "elo_equal" => t.elo_equal,
      "bye_value" => t.bye_value,
      "ff_value" => t.ff_value,
      "tiebreaks" => data.tiebreaks,
      "category_type" => data.categories.type,
      "xtra_points" => Enum.map(data.xtra_points, fn {pts, elo} -> [pts, elo] end)
    }
  end

  ## ---------- [EXCLUSION]: SWAR's "ICN style" team events ----------
  #
  # SWAR's `USE_EXCLUSION` (`Swar.h`), and what `EnvoiJAVAFO.cpp` makes of
  # `Exclusion.Values` when it writes the `XXP` lines JaVaFo pairs with:
  #
  #   -1 EXCLU_NO        nothing
  #    0 EXCLU_PART_JOU  groups of player numbers (NI), "1,4:12,15,21": every
  #                      pair within a group never meets (EcrireExclusionJou)
  #    1 EXCLU_PART_CLU  club numbers, "618:621": players of the same listed
  #                      club never meet (EcrireExclusionClu, `atoi` against
  #                      ClubNr)
  #    2 EXCLU_PART_NAT  nationalities, "BEL:FRA", same within each listed one
  #    3 EXCLU_GLOB_CLU  every club (BuildAllClub - by club NUMBER)
  #    4 EXCLU_GLOB_NAT  every nationality
  #
  # SWAR's own manual calls 3 and 4 the way to run "ICN style" competitions -
  # schools, or the NATO event - which is the team competition a .swar file
  # can actually describe. This app has the same rules (`PairingsEngine.
  # Exclusions`, "SWAR parity #7-10"), so they are carried over instead of
  # being read and dropped, as they were before: pairing a further round
  # here would otherwise seat teammates against each other.
  #
  # Two differences, both on the side of the file's intent:
  #
  #   * SWAR groups clubs by number, this app by club name. The rule is set
  #     by name, and `exclusion_warnings/1` says so when the two groupings
  #     would keep a different set of players apart.
  #   * 4 does nothing in SWAR v6.65: `BuildAllNat` has an empty body
  #     (docs/swar-source-audit-2026-09-09.md, F2). The file says "keep each
  #     nationality apart", so that is what it becomes here - the audit's own
  #     advice is not to calibrate this rule against SWAR's bug.
  #
  # Each becomes a pairing rule (`create_exclusion_rule/2`) once the
  # tournament exists; 0 is explicit forbidden pairings, written in
  # `create_exclusion_pairs/3` once the players exist.
  defp exclusion_rule(%{exclusion: %{type: 3}}), do: %{"kind" => "club"}
  defp exclusion_rule(%{exclusion: %{type: 4}}), do: %{"kind" => "federation"}

  defp exclusion_rule(%{exclusion: %{type: 1, values: values}, players: players}) do
    case listed_club_names(values, players) do
      [] -> nil
      names -> %{"kind" => "club", "names" => names}
    end
  end

  defp exclusion_rule(%{exclusion: %{type: 2, values: values}}) do
    case exclusion_values(values) |> Enum.map(&Federation.normalize/1) |> Enum.uniq() do
      [] -> nil
      codes -> %{"kind" => "federation", "names" => codes}
    end
  end

  defp exclusion_rule(_data), do: nil

  # The rule, once the tournament exists. The file's own, so `import: true`:
  # it was announced before this copy had a round of its own to depart from.
  defp create_exclusion_rule(tournament, data) do
    case exclusion_rule(data) do
      nil ->
        :ok

      attrs ->
        case Tournaments.add_pairing_rule(tournament, attrs, import: true) do
          {:ok, _rule} -> :ok
          {:error, _reason} -> Repo.rollback("Could not import the file's exclusion rule.")
        end
    end
  end

  # `Exclusion.Values` is ':'-separated, as `ImplodeValues1` (`TOptions.cpp`)
  # stores it.
  defp exclusion_values(values) when is_binary(values) do
    values
    |> String.split(":")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp exclusion_values(_values), do: []

  # SWAR compares each listed entry with `atoi` against the player's club
  # number, so "618" and "618 - Club" both mean club 618. A listed club no
  # player belongs to excludes nobody in SWAR either, and is left out. A
  # club name holding a comma cannot go in this app's comma-separated list;
  # `exclusion_warnings/1` names the difference that makes.
  defp listed_club_names(values, players) do
    numbers = listed_club_numbers(values)

    players
    |> Enum.filter(&(&1.club_nr in numbers))
    |> Enum.map(&String.trim(&1.club || ""))
    |> Enum.reject(&(&1 == "" or String.contains?(&1, ",")))
    |> Enum.uniq()
  end

  defp listed_club_numbers(values) do
    values
    |> exclusion_values()
    |> Enum.flat_map(fn entry ->
      case Integer.parse(entry) do
        {n, _rest} -> [n]
        :error -> []
      end
    end)
  end

  @doc false
  # The notices an [EXCLUSION] section can give (see `exclusion_rule/1`).
  # Only the club rule has one: SWAR keeps players apart by club NUMBER, this
  # app by club NAME, and where the two groupings differ - a club spelled two
  # ways, two clubs sharing a name, several players without a club number -
  # a different set of players is kept apart from the next round on.
  def exclusion_warnings(%{exclusion: %{type: type}} = data) when type in [1, 3] do
    players = data.players

    swar_groups =
      players
      |> Enum.filter(&(type == 3 or &1.club_nr in listed_club_numbers(data.exclusion.values)))
      |> groups_of(& &1.club_nr)

    listed_names =
      case exclusion_rule(data) do
        %{"names" => names} -> Enum.map(names, &String.downcase/1)
        _ -> []
      end

    our_groups =
      players
      |> Enum.reject(&(club_key(&1) == ""))
      |> Enum.filter(&(type == 3 or club_key(&1) in listed_names))
      |> groups_of(&club_key/1)

    if swar_groups == our_groups do
      []
    else
      [
        gettext(
          "This SWAR file keeps players of the same club apart, and that rule has been carried over. SWAR tells clubs apart by club number, OpenPairings by club name, and in this file the two do not match for every player - a club spelled two ways, two clubs with one name, or players without a club number. Check the clubs on the Players page and the rule under Settings before pairing the next round."
        )
      ]
    end
  end

  def exclusion_warnings(_data), do: []

  defp club_key(p), do: (p.club || "") |> String.trim() |> String.downcase()

  # The groups of two or more players a rule keeps apart, as a set of sets
  # of player numbers - equal sets keep exactly the same pairs apart.
  defp groups_of(players, key_fun) do
    players
    |> Enum.group_by(key_fun, & &1.ni)
    |> Map.values()
    |> Enum.filter(&(length(&1) >= 2))
    |> MapSet.new(&MapSet.new/1)
  end

  # EXCLU_PART_JOU: each ':'-separated group of player numbers becomes
  # forbidden pairings, every pair within the group - the `XXP` lines
  # SWAR's `EcrireExclusionJou` writes for it. A number no player has is
  # skipped, as SWAR's own `CheckJou` would refuse to pair with it anyway.
  defp create_exclusion_pairs(tournament, %{exclusion: %{type: 0, values: values}}, players_by_ni) do
    values
    |> exclusion_values()
    |> Enum.flat_map(fn group ->
      ids =
        group
        |> String.split(",")
        |> Enum.flat_map(fn entry ->
          case Integer.parse(String.trim(entry)) do
            {ni, _rest} -> List.wrap(players_by_ni[ni] && players_by_ni[ni].id)
            :error -> []
          end
        end)
        |> Enum.uniq()

      for {a, i} <- Enum.with_index(ids), b <- Enum.drop(ids, i + 1), do: {a, b}
    end)
    |> Enum.uniq()
    |> Enum.each(fn {a, b} ->
      case Tournaments.add_forbidden_pairing(tournament, a, b, import: true) do
        {:ok, _row} -> :ok
        {:error, :already_forbidden} -> :ok
        {:error, _reason} -> Repo.rollback("Could not import the file's excluded pairings.")
      end
    end)
  end

  defp create_exclusion_pairs(_tournament, _data, _players_by_ni), do: :ok

  # `TOURNOI_TYPE.SWISS_321 == 3` (manual §5.1) is SWAR's 3-2-1 scheme
  # (`IsSwiss321`): a club-configured scale for the result plus a separate
  # presence point per round attended. Despite the name the values are the
  # club's own; "3-2-1" is the common Win 2 / Draw 1 / Loss 0 + presence 1.
  #
  # Every rule below is read off SWAR's own source (v6.65 FRBE):
  #
  # * Scale. `SW321_Win/Nul/Los/Bye/Pre` are stored ×4: the options dialog
  #   writes `4 * value` and reads back `/ 4` (TOptions.cpp:616-620,
  #   698-702), and the HTML header prints `/ 4` (Html.cpp:730-734). A
  #   previous version of this function used ÷8 and halved every value.
  #   `SW321_PreBye` is a 0/1 flag (TOptions.cpp:703).
  #
  # * Result points. `ConvertPoint321` (Utils.cpp:1197-1222), which
  #   `GetPointsUntilRound` uses for a 3-2-1 tournament (Classement.cpp:
  #   102-105): WIN, WIN_FF pay `SW321_Win`; DRAW, DRAW_FF, DRAW_ZERO pay
  #   `SW321_Nul`; LOST, LOST_FF, ZERO_DRAW pay `SW321_Los`; LOST_BYE pays
  #   `SW321_Bye`; everything else - WIN_BYE, DRAW_BYE, ZERO_ZERO,
  #   ZERO_ZEROFF, NO_RESULT (an absence) - pays 0. `AbsValue` is never
  #   paid.
  #
  # * Presence. `GetPresentPtsUntilRound` (Classement.cpp:137-157) adds
  #   `SW321_Pre` for a result in RESULTATS_NORMAUX, RESULTATS_WIN or
  #   RESULTATS_SPECIAUX (Swar.h:227-247) - a game, a forfeit WIN, a 0-0,
  #   a ½-0 - and another `SW321_Pre` for any bye result when
  #   `SW321_PreBye` is set. A forfeit loss, a double forfeit and an
  #   absence get none.
  #
  # * Total. The standings rank on `Points + ExtraPts + SpecialPts`
  #   (Classement.cpp:1425), `SpecialPts` being the presence sum
  #   (Classement.cpp:1389-1390); ExtraPts are zeroed for 3-2-1 on load.
  #   The file stores only `Points`, so its presence never appears in it.
  #
  # * The bye. SWAR forces `ByeValue` to `PTS_0` for the type
  #   (TOptions.cpp:566), so the pairing bye is LOST_BYE on `TABLE_BYE`
  #   (PairingSwiss.cpp:73-79, 390-392): `SW321_Bye`, plus `SW321_Pre` with
  #   PreBye. The one real fixture (test3-321.swar) has exactly those -
  #   every unpaired LOST_BYE there is on table 4096 = `TABLE_BYE` - and its
  #   absences are `TABLE_ABSENT` with no result (PairingSwiss.cpp:805-809),
  #   worth nothing.
  #
  # Onto the model: points_win/draw/loss are Win/Nul/Los, `bye_value` is
  # `SW321_Bye`, `presence_value` is `SW321_Pre` (its being set is what
  # makes `Standings.presence_scheme?/1` true) and
  # `presence_on_allocated_bye` is PreBye. `Standings` then pays a
  # zero-point bye like the pairing bye, an absence nothing, and a 0-0 or
  # 0-0FF nothing. WIN_BYE, DRAW_BYE and DRAW_FF, which a 3-2-1 file from
  # SWAR's own dialog does not hold, have no equivalent here - see
  # `swiss321_warnings/1`.
  defp swiss321?(%{type: 3}), do: true
  defp swiss321?(_), do: false

  defp scoring_attrs(%{type: 3} = t) do
    %{
      points_win: t.sw321_win / 4,
      points_draw: t.sw321_nul / 4,
      points_loss: t.sw321_los / 4,
      bye_value: t.sw321_bye / 4,
      presence_value: t.sw321_pre / 4,
      presence_on_allocated_bye: prebye_set?(t)
    }
  end

  # Round robin: SWAR forces this to a full point at load, for every
  # round-robin file, regardless of what `ByeValue` itself says.
  # `TournoiReadStream` (`TournoiReadWrite.cpp:451-452`) runs this
  # unconditionally right after reading `ByeValue`:
  #
  #   if (IsRobin(Tournoi.Type))
  #       Tournoi.ByeValue = (USE_POINTS)PTS_1;
  #
  # `IsRobin` is `ROBIN || ROBIN_DBL || ROBIN_AR` (`Utils.cpp:538-540`) - the
  # same three ordinals `map_tournament_type/1` below already calls
  # "roundrobin". A second, dialog-only forcing to `PTS_0` also exists
  # (`TOptions.cpp:569-583`), but it only reaches the tournament if the
  # arbiter opens the Options tab and the dialog writes back - the load-path
  # forcing above always runs regardless, so it is the one worth mirroring.
  # This importer's job is to reproduce the tournament the file describes,
  # and for a round robin that is SWAR's forced full point, not whatever the
  # file's own `ByeValue` byte happens to say -
  # `round_robin_bye_warnings/1` tells the arbiter so.
  #
  # OpenPairings' OWN round robin (no SWAR file involved) still writes a
  # zero-point "requested-zero" bye (`round_robin.ex`) - a deliberate,
  # correct choice for a NATIVE round robin, since FIDE does not award a
  # point for one, and this clause never touches it: it only concerns a
  # round robin read FROM a SWAR file. See
  # docs/swar-source-audit-pass2-2026-09-09.md §3 (F11).
  defp scoring_attrs(t) do
    if map_tournament_type(t.type) == "roundrobin" do
      %{bye_value: 1.0}
    else
      %{bye_value: map_bye_value(t.bye_value)}
    end
  end

  # `SW321_PreBye` (manual §5.16, field 85 - only present in file version >=
  # "v6.03", nil in older files) reads as a 0/1 int (raw 1 in the real
  # test3-321.swar fixture). Nonzero means "add presence points for bye
  # games". Older files (nil) or a zero value leave the flag at its false
  # default.
  defp prebye_set?(%{sw321_prebye: prebye}) when is_number(prebye) and prebye != 0, do: true
  defp prebye_set?(_t), do: false

  @tournament_types %{
    0 => "swiss",
    1 => "swiss",
    2 => "swiss",
    3 => "swiss",
    4 => "roundrobin",
    5 => "roundrobin",
    6 => "roundrobin",
    7 => "swiss",
    8 => "swiss"
  }
  defp map_tournament_type(type), do: Map.get(@tournament_types, type, "swiss")

  # A round robin is a round robin in `pairing_system` too, not only in
  # `type`. The import used to set `type` alone, leaving the schema's
  # `pairing_system: "swiss"`, and everything that asks "is this a round
  # robin?" asks `pairing_system`: `Standings` ranked an imported SWAR round
  # robin by the Swiss rules of C.07 - no Article 15.2 (a forfeit among the
  # tied players left direct encounter unresolved, so SWAR's own sample of
  # FIDE's round-robin tie-break exercise came out in reverse order), a
  # free round treated as a pairing-allocated bye with an Article 16 dummy
  # in Sonneborn-Berger, and Buchholz not dropped (Article 8). Found by
  # re-ranking SWAR's archive with tools/swar_rerank.exs. The same fields a
  # TRF26 import sets from its `192` code (`TrfImport.system_attrs/1`).
  #
  # SWAR's `ROBIN_DBL` plays each pairing twice in consecutive rounds
  # (`Swar.h`: "2 rencontres consecutives") - this app's match format;
  # `ROBIN_AR` repeats the whole table after the first cycle ("aller-retour")
  # - a double round robin.
  defp system_attrs(%{type: 4}), do: %{pairing_system: "round_robin", rr_cycles: 1}
  defp system_attrs(%{type: 5}), do: %{pairing_system: "round_robin", rr_match_format: true}
  defp system_attrs(%{type: 6}), do: %{pairing_system: "round_robin", rr_cycles: 2}

  # SWAR's `SWISS_DBL` ("2 rencontres consecutives", `Swar.h`; its
  # `PairingSwiss.cpp` pairs the even round as the odd one with the colours
  # reversed) is this app's Swiss match format - which needs an even number
  # of rounds, as a two-game match does.
  defp system_attrs(%{type: 1, nb_rounds: n}) when is_integer(n) and n > 0 and rem(n, 2) == 0,
    do: %{swiss_match_format: true}

  defp system_attrs(_swiss), do: %{}

  # SWAR's [TOURNOI] `federation` field is *which Belgian federation entity*
  # organizes the tournament, not a FIDE country code: FRBE/KBSB are the
  # (French/Dutch-named) national federation itself, FEFB/VSF/SVDB are its
  # Walloon/Flemish regional leagues, and code 6 is "direct FIDE" homologation
  # with no specific sub-federation. All of these are Belgium as far as FIDE
  # reporting is concerned - `PairingsEngine.Federation.normalize/1` collapses
  # them to the single FIDE country code "BEL" that TRF export and the
  # tournament's own `federation` field are supposed to carry (see
  # docs/swar-import.md).
  @federations %{
    0 => "",
    1 => "FRBE",
    2 => "KBSB",
    3 => "FEFB",
    4 => "VSF",
    5 => "SVDB",
    6 => "FIDE"
  }
  defp map_federation(code), do: Map.get(@federations, code, "") |> Federation.normalize()

  # ByeValue: 0 = full point, 1 = half point, 2 = zero points (manual §5.16).
  defp map_bye_value(0), do: 1.0
  defp map_bye_value(1), do: 0.5
  defp map_bye_value(2), do: 0.0
  defp map_bye_value(_), do: 1.0

  # SWAR's `DEPARTAGES` enum, in its own declaration order (`Swar.h`):
  #
  #   0 none          4 Buchholz Cut-1     8 direct encounter  12 ARO
  #   1 Buchholz      5 Buchholz Cut-2     9 Koya              13 ARO Cut-1
  #   2 median-1      6 Sonneborn-Berger  10 wins              14 black games
  #   3 median-2      7 cumulative        11 performance       15 black wins
  #
  # This mapped six of them, with a comment saying the rest were "skipped"
  # because they had no counterpart here. That was true when it was written
  # and stopped being true as the tie-break catalogue grew: Koya, ARO, ARO
  # Cut-1, Buchholz Cut-2, median Buchholz and black-games-played are all in
  # `PairingsEngine.Tiebreaks` now, all `available: true`, and the importer
  # was never told. Same drift as `@playing_codes` in `TrfImport` and
  # `@fts_tables` in `Backup`: a list that was complete on the day it was
  # written, in a file that does not get read when the OTHER list grows.
  #
  # It is not a missing column. `map_tiebreaks/1` compacts, so a tournament
  # SWAR ranked on Cut-2 then Buchholz imported ranked on Buchholz - the
  # second criterion silently promoted to first, and the standings order
  # changed with nothing on screen saying so.
  @tiebreak_codes %{
    1 => "BH",
    2 => "MBH",
    4 => "BHC1",
    5 => "BHC2",
    6 => "SB",
    7 => "PS",
    8 => "DE",
    9 => "KS",
    10 => "WIN",
    12 => "ARO",
    13 => "AROC1",
    14 => "BPG"
  }

  # Three have no honest counterpart and are left out on purpose:
  #
  #   3  median-2       we have one median Buchholz, which is median-1
  #   11 performance    not a tie-break in this app's catalogue
  #   15 black wins     `WON` counts wins over the board, not black wins
  #
  # Named rather than left to fall through `nil`, so the warning below can
  # say WHICH criterion was lost instead of only that the count changed.
  @tiebreak_names %{
    3 => "Buchholz median-2",
    11 => "performance rating",
    15 => "games won with Black"
  }

  @doc false
  # Public for `SwarExport`, which writes the file's own list back while the
  # tournament still ranks by what this made of it.
  def map_tiebreaks(codes) do
    codes
    |> Enum.map(&Map.get(@tiebreak_codes, &1))
    |> Enum.reject(&is_nil/1)
  end

  @doc false
  def tiebreak_warnings(codes) do
    dropped =
      codes
      |> Enum.reject(&(&1 == 0))
      |> Enum.reject(&Map.has_key?(@tiebreak_codes, &1))
      |> Enum.map(&Map.get(@tiebreak_names, &1, "an unrecognised method (code #{&1})"))
      |> Enum.uniq()

    case dropped do
      [] ->
        []

      names ->
        [
          "This file ranks on a tie-break this app does not have " <>
            "(#{Enum.join(names, ", ")}). It has been left out, which moves every " <>
            "criterion after it up one place - so the standings order here may " <>
            "differ from SWAR's. Check the tie-break list on the Settings page " <>
            "before publishing."
        ]
    end
  end

  # TournoiStd: 0=Standard, 1=Rapid, 2=Blitz (manual §5.13/4.2 field 87).
  defp map_standard(0), do: "standard"
  defp map_standard(1), do: "rapid"
  defp map_standard(2), do: "blitz"
  defp map_standard(_), do: "standard"

  # `Cadence` (manual field 88, alongside `Cadence_Other`) is a 0-based index
  # into one of three dropdown lists SWAR's own UI fills at runtime - which
  # list depends on the sibling `TournoiStd` field (0=Standard/1=Rapid/
  # 2=Blitz, same field `map_standard/1` reads). None of this is documented
  # in the binary-format notes this importer otherwise leans on; it was
  # reverse-engineered from SWAR's OWN SOURCE (`Utils.cpp`'s `GetCadence/2`,
  # which builds a language-file key `"_STD_CADENCE_%02d"`-style from
  # `Cadence + 1`) and its shipped translation table
  # (`Languages/Swar.Lang.fr.ini`, `[CADENCES]` section) - the source the
  # maintainer supplied directly, not something inferred from a .swar sample.
  # Translated here from the .ini's French to plain English, in the same
  # "X min + Y sec/move" shorthand `rate_of_play` already uses elsewhere.
  #
  # The LAST entry of each list is "autre cadence" ("other cadence" - SWAR's
  # own UI detects "Other" this way too, by comparing against the last
  # list entry rather than a fixed sentinel index) - deliberately absent from
  # these tables so `cadence_label/2` returns `nil` for it, falling through
  # to `Cadence_Other`'s free text in `tournament_attrs/1`.
  @std_cadences {
    "105 min/40 moves + 15 min, sudden death",
    "120 min/40 moves + 15 min + 30 sec/move from move 40",
    "120 min/40 moves + 30 min, sudden death",
    "120 min/10 moves + 30 min + 30 sec/move from move 40",
    "120 min, sudden death",
    "150 min, sudden death",
    "60 min, sudden death",
    "60 min + 30 sec/move",
    "65 min, sudden death",
    "75 min + 30 sec/move",
    "90 min/40 moves + 15 min + 30 sec/move from move 1",
    "90 min/40 moves + 30 min + 30 sec/move from move 1",
    "90 min + 30 sec/move"
  }

  @rap_cadences {
    "Rapid 10 min + 10 sec/move",
    "Rapid 10 min + 15 sec/move",
    "Rapid 10 min + 5 sec/move",
    "Rapid 11 min, sudden death",
    "Rapid 12 min, sudden death",
    "Rapid 13 min + 3 sec/move",
    "Rapid 13 min + 5 sec/move",
    "Rapid 15 min, sudden death",
    "Rapid 15 min + 10 sec/move",
    "Rapid 15 min + 15 sec/move",
    "Rapid 15 min + 5 sec/move",
    "Rapid 20 min, sudden death",
    "Rapid 20 min + 10 sec/move",
    "Rapid 20 min + 15 sec/move",
    "Rapid 20 min + 5 sec/move",
    "Rapid 25 min, sudden death",
    "Rapid 25 min + 10 sec/move",
    "Rapid 25 min + 15 sec/move",
    "Rapid 25 min + 5 sec/move",
    "Rapid 30 min, sudden death",
    "Rapid 45 min, sudden death",
    "Rapid 8 min + 4 sec/move"
  }

  @bli_cadences {
    "Blitz 3 min + 2 sec/move",
    "Blitz 3 min + 3 sec/move",
    "Blitz 4 min + 2 sec/move",
    "Blitz 4 min + 3 sec/move",
    "Blitz 5 min, sudden death",
    "Blitz 5 min + 2 sec/move",
    "Blitz 5 min + 3 sec/move",
    "Blitz 6 min + 2 sec/move",
    "Blitz 6 min + 3 sec/move",
    "Blitz 7 min + 2 sec/move",
    "Blitz 7 min + 3 sec/move",
    "Blitz 8 min + 2 sec/move",
    "Blitz 10 min, sudden death"
  }

  @doc false
  def cadence_label(tournoi_std, cadence) when is_integer(cadence) and cadence >= 0 do
    table =
      case tournoi_std do
        1 -> @rap_cadences
        2 -> @bli_cadences
        _ -> @std_cadences
      end

    if cadence < tuple_size(table), do: elem(table, cadence), else: nil
  end

  def cadence_label(_tournoi_std, _cadence), do: nil

  # SWAR's [CATEGORIES] block carries TWO value lists. Settled 2026-09-09
  # from SWAR's own source (`docs/swar-source-audit-2026-09-09.md`): for
  # `Categorie` type 3/4 (age-then-rating / rating-then-age) they are the
  # bounds of the SECOND axis and the first, and a player's `CatIndex` packs
  # ONE index per axis into one integer - `idx / 100` for axis 1, `idx % 100`
  # for axis 2 (`Categories.cpp:737`, both one-based). Types 1/2/5 (rating
  # alone, age alone, free text) use `value1` only; `value2` is blank
  # padding.
  #
  # This app has no single "two-axis category" concept, but a player already
  # carries a SET of category tags (see `PairingsEngine.Categories`
  # moduledoc), so both axes import as their own named categories and a
  # two-axis player is tagged with both - see `category_axes/2` and
  # `player_attrs/2` below, and "Categories: two axes, two tag sets" in
  # docs/swar-import.md for the full reasoning, including why pairing still
  # settles on one category (axis 1) deterministically.
  #
  # Public (`@doc false`) for the same reason `cadence_label/2` above is: the
  # only file that could exercise this through `import_file/2` is a real club
  # export nobody has, and the parse is not what is under test.
  @doc false
  def category_warnings(%{type: t}) when t in 0..5, do: []

  def category_warnings(%{type: t}) do
    [
      "This file's category block has an unrecognised type (#{t}); its " <>
        "categories were not imported. Check the categories on the Settings " <>
        "page before pairing by category."
    ]
  end

  def category_warnings(_no_category_block), do: []

  # [CATEGORIES]: Categorie type 0 (NO_CATEGO, manual §5.18) means the
  # tournament defines no categories at all - value1/value2 are all blank
  # padding in that case.
  #
  # Types 3/4 (age-then-rating, rating-then-age) are two-axis: both `value1`
  # and `value2` hold a real, independent axis, so both become named
  # categories - axis 1 first (it is also the pairing category, see
  # `PairingsEngine.Categories.pairing_category/2` and docs/swar-import.md),
  # then axis 2, each list's own blanks rejected and de-duplicated.
  #
  # Every other type (1, 2, 5) is single-axis: `value1` alone, same as
  # before.
  defp map_categories(%{type: 0}), do: []

  defp map_categories(%{type: t, value1: v1, value2: v2}) when t in [3, 4] do
    (reject_blank(v1) ++ reject_blank(v2)) |> Enum.uniq()
  end

  defp map_categories(%{value1: v1}) do
    v1 |> reject_blank() |> Enum.uniq()
  end

  # The SWAR `Categorie` type when it names a two-axis file, for
  # `Tournament.swar_category_type` - lets `SwarExport` know to split
  # `categories` back across `value1`/`value2` rather than writing
  # everything into `value1`.
  defp two_axis_type(%{type: t}) when t in [3, 4], do: t
  defp two_axis_type(_categories), do: nil

  # The axis-2 names alone, in file order, for `Tournament.swar_category_axis2`.
  defp axis2_names(%{type: t, value2: v2}) when t in [3, 4],
    do: v2 |> reject_blank() |> Enum.uniq()

  defp axis2_names(_categories), do: []

  defp reject_blank(list), do: Enum.reject(list, &(&1 == ""))

  # Per-player CatIndex resolves into BOTH `[CATEGORIES]` value lists.
  #
  # SWAR encodes both axes in this one integer, and it is one-based:
  # `Categories.cpp:737` is `CatIndex += (value == 1 ? (i + 1) * 100 : i + 1)`
  # over a zero-based `i`, so the axis-1 slot lands in the hundreds as
  # `(slot + 1) * 100` and the axis-2 slot in the units as `slot + 1`. Slot 0
  # is therefore stored as 100 (axis 1) or 1 (axis 2), not 0.
  #
  # This used to divide by 100 and stop, which is `slot + 1` - one too high.
  # Every player came in one category stronger than the file said, and the
  # last category in the list never received anybody. Fixed in 0.53.0 (see
  # `docs/swar-source-audit-2026-09-09.md` §F1); the same off-by-one applies
  # equally to axis 2, decoded the same way.
  #
  # Legacy normalisation: old SWAR files stored `CatIndex` as a small
  # ordinal (the axis-1 slot itself, `1..16`, no axis 2 possible); current
  # ones store it pre-multiplied by 100. SWAR normalises on the way in,
  # unconditionally, for any file - `TournoiReadStream`
  # (`TournoiReadWrite.cpp:623-624`) multiplies whenever the stored value is
  # under 100:
  #
  #   if (CatIndex < 100)
  #       CatIndex *= 100
  #
  # Without mirroring this, a legacy file's `cat_index: 2` decodes as
  # "axis 2 slot 1 only", losing axis 1 entirely, where SWAR shows
  # `Value1[1]`. Reachability is bounded (`TournoiReadStream` itself refuses
  # a file older than SWAR can still open) but not dated from the source,
  # and such files are exactly why SWAR still carries the step. See
  # docs/swar-source-audit-pass2-2026-09-09.md §5.2.
  @doc false
  def category_axes(0, _categories), do: {"", ""}

  def category_axes(cat_index, categories) do
    normalized = if cat_index < 100, do: cat_index * 100, else: cat_index
    slot1 = div(normalized, 100) - 1
    slot2 = rem(normalized, 100) - 1

    axis1 =
      if slot1 >= 0, do: categories.value1 |> Enum.at(slot1, "") |> to_string(), else: ""

    axis2 =
      if slot2 >= 0, do: categories.value2 |> Enum.at(slot2, "") |> to_string(), else: ""

    {axis1, axis2}
  end

  # Axis 1 alone - the pairing category (see docs/swar-import.md). Kept
  # because it is the direct `category_name/2` seam the older tests and the
  # module's public API used; `category_axes/2` above is the full answer.
  @doc false
  def category_name(cat_index, categories) do
    {axis1, _axis2} = category_axes(cat_index, categories)
    axis1
  end

  # Paye: 0=Not paid, 1=Paid, 2=Free (manual §5.20).
  defp map_paid(0), do: "nopaid"
  defp map_paid(1), do: "paid"
  defp map_paid(2), do: "gratis"
  defp map_paid(_), do: "paid"

  # Affilie: 0=Not affiliated, 1=Affiliated, 2=G-License (manual §5.21). A
  # guest license still counts as some affiliation for our boolean field.
  defp map_affiliated(0), do: false
  defp map_affiliated(_), do: true

  # Absent: 1=Forfeit, 2=Absent, 4=Present (manual §5.19). "Absent" alone
  # does NOT mean permanently gone - SWAR's own `AbsentThisRound` (Utils.cpp)
  # treats Absent=2 as round-specific whenever AbsentRondes is non-empty: a
  # round not in that list is PRESENT, not absent. Round-specific exclusion
  # is `absent_rounds`'s job (see `Pairing.eligible_players/2`); this
  # boolean should only ever mean "permanently out, no round list at all" -
  # otherwise a player who sat out one round (a very common case: illness,
  # a work conflict, a bye request) gets silently excluded from every round
  # after that, in OpenPairings, forever, even though they came back and
  # played per SWAR's own reading of the same data.
  @doc false
  def map_absent(2, absent_rondes) when absent_rondes in [nil, ""], do: true
  def map_absent(_, _), do: false

  defp map_forfeit(1), do: true
  defp map_forfeit(_), do: false

  # SWAR dates arrive as "dd/mm/yyyy" (or, rarely, "yyyy/mm/dd" for very old
  # files) with no guaranteed zero-padding; convert to ISO "yyyy-mm-dd". The
  # manual documents auto-detecting the order by checking whether the first
  # number is > 1000 (i.e. clearly a year).
  defp normalize_date(""), do: ""

  defp normalize_date(s) do
    case String.split(s, "/") do
      [a, b, c] ->
        {y, m, d} =
          case Integer.parse(a) do
            {n, _} when n > 1000 -> {a, b, c}
            _ -> {c, b, a}
          end

        "#{String.pad_leading(y, 4, "0")}-#{String.pad_leading(m, 2, "0")}-#{String.pad_leading(d, 2, "0")}"

      _ ->
        s
    end
  end

  ## ---------- Players ----------

  @doc false
  # Two things SWAR's own loader and pairing do to the player list before
  # anything is paired, done here the same way:
  #
  #   * **Pairing numbers are SWAR's seed order.** A player's `Ni` is only a
  #     registration number; SWAR seeds and pairs by `Rank`. Its Swiss hands
  #     JaVaFo the players numbered in `(category when separate, Class,
  #     Rank)` order (`EnvoiJAVAFO.cpp`, `EcrireClassementJAVAFO`), and its
  #     round robin numbers each Berger table by the players' order in
  #     `(category, Rank)` (`PairingRobin.cpp`: `InitRobin` sorts with
  #     `ComparePlayerCatRank`, renumbers Rank from 1 in each category when
  #     categories are separate, and `GetAdvers` looks a player up by that
  #     position). The pairing number here is that position - so a round
  #     robin continued here plays SWAR's own Berger table
  #     (`RoundRobin.schedule/3` is SWAR's `GenerationBerger`, colours
  #     included), each category its own table when categories are separate,
  #     and a Swiss continued here orders its brackets as SWAR's would. It
  #     used to be `Ni`: a round robin saved before pairing then played a
  #     table in registration order, and a Swiss seeded round 1 by it. `Ni`
  #     itself matters only inside the file, to find a record's opponent, and
  #     the import keys by it throughout. Players on the same Rank (SWAR's
  #     sort leaves their order to `qsort`) go by `Ni`.
  #   * **No extra points in a round robin or a 3-2-1 event**, which SWAR's
  #     loader zeroes (`extra_points_attrs/1`).
  def prepare_players(data) do
    t = data.tournament
    separate? = t.cat_separes != 0
    zero_extra? = not extra_points_apply?(t)

    seeds =
      data.players
      |> Enum.sort_by(fn p -> {if(separate?, do: max(p.cat_index, 1), else: 0), p.rank, p.ni} end)
      |> Enum.with_index(1)
      |> Map.new(fn {p, i} -> {p.ni, i} end)

    players =
      Enum.map(data.players, fn p ->
        p = Map.put(p, :seed, Map.fetch!(seeds, p.ni))
        if zero_extra?, do: zero_extra_points(p), else: p
      end)

    %{data | players: players}
  end

  # The player's own extra points and each round's copy of them
  # (`[RONDE]` `XtraPts`, which `insert_round/4` records as the round's
  # virtual points) - SWAR discards both for these types.
  defp zero_extra_points(p) do
    %{p | extra_pts: 0, rounds: Enum.map(p.rounds, &Map.put(&1, :xtra_pts, 0))}
  end

  # Matched in full, not `{:ok, player} =`. `create_player/2` returns an
  # ordinary error tuple for a blank name, a FIDE id out of range, a name
  # over 100 characters - all of which a real `.swar` can carry - and the
  # bare match turned that into a `MatchError` that killed the importing
  # LiveView instead of showing the message the UI already has a place for.
  # The transaction rolled back either way; only the report was lost. The
  # pure path thirty lines up (`build_player_structs/2`) and
  # `TrfImport.create_players/2` both already do it this way.
  defp create_players(tournament, swar_players, categories) do
    Map.new(swar_players, fn p ->
      case Tournaments.create_player(tournament.id, player_attrs(p, categories)) do
        {:ok, player} ->
          {p.ni, player}

        {:error, :duplicate_fide_id} ->
          Repo.rollback("Duplicate FIDE id #{p.mat_fide} (player #{String.trim(p.name || "")})")

        {:error, :archived} ->
          Repo.rollback("Could not import player #{String.trim(p.name || "")}: archived")

        {:error, changeset} ->
          Repo.rollback(
            "Could not import player #{String.trim(p.name || "")}: " <>
              changeset_error_text(changeset)
          )
      end
    end)
  end

  # Shared by `create_players/3` (persisting) and `build_player_structs/2`
  # (pure, no Repo) - the one place a parsed SWAR [JOUEURS] record maps onto
  # `Player.changeset/2` attrs.
  defp player_attrs(p, categories) do
    {category, axis2} = category_axes(p.cat_index, categories)
    tags = [category, axis2] |> reject_blank() |> Enum.uniq()

    %{
      # SWAR's own spelling is canonical - a FIDE database match (see
      # `resolve_fide_match/1` below) only ever contributes `fide_id`,
      # `title` and (conditionally) `fide_rating`; it must never touch
      # `name`, which always comes straight from the SWAR record.
      name: p.name,
      sex: map_sex(p.sex),
      title: fide_title_or(p),
      fide_id: zero_to_nil(p.mat_fide),
      fide_rating: fide_rating_or(p),
      national_id: zero_to_blank(p.mat_nat),
      national_rating: p.elo,
      federation: Federation.normalize(p.country),
      birth_year: birth_year(p.birth),
      birth_date: birth_date(p.birth),
      club: p.club,
      # SWAR's seed order, not its registration number - see
      # `prepare_players/1`.
      pairing_number: Map.get(p, :seed, p.ni),
      paid: map_paid(p.paye),
      affiliated: map_affiliated(p.affilie),
      absent: map_absent(p.absent, p.absent_rondes),
      forfeit: map_forfeit(p.absent),
      # SWAR's HandyTable is the accessible TABLE NUMBER this player must
      # sit at (0 = none), not a yes/no flag - `@table_handicap` above
      # documents SWAR's own 1001+ numbering for exactly this concept - so
      # it lands in `fixed_board`, which is the only field
      # `PairingDisplay.special?/1` ever looks at.
      #
      # It used to set `special_table: p.handy_table != 0` and nothing else.
      # That boolean is read in one place (`SwarExport`'s HandyTable field);
      # the display, the sort order, the printed sheet and the PGN all read
      # `fixed_board`. So a SWAR-imported handicap player was special
      # nowhere an arbiter could see - the accommodation survived the import
      # only as a flag that could be re-exported.
      #
      # `special_table` is deliberately NOT set here: `Player.changeset/2`'s
      # `sync_special_table/1` derives it from the `fixed_board` key this
      # map now carries, so the two cannot disagree again.
      fixed_board: fixed_board(p.handy_table),
      absent_rounds: p.absent_rondes,
      extra_points: p.extra_pts / 4.0,
      # Both category fields, written together. A SWAR file's `CatIndex`
      # packs one axis-1 slot and (for a two-axis file) one axis-2 slot into
      # one integer; `category_axes/2` above decodes both. `category` is
      # always axis 1 alone - it is the pairing-pool override
      # `PairingsEngine.Categories.pairing_category/2` needs, and axis 1 is
      # also the pairing category by convention (see docs/swar-import.md) -
      # while `categories` is the full tag SET, both axes when there are
      # two, so the Players grid, prize lists and per-category standings all
      # see a two-axis player under both their age band and their rating
      # band. `Player.changeset/2` would fold `category` into `categories`
      # anyway; saying it here means the attrs map on its own is already
      # right, rather than correct only because something downstream repairs
      # it.
      category: category,
      categories: tags,
      club_number: zero_to_nil(p.club_nr)
    }
  end

  defp map_sex(1), do: "m"
  defp map_sex(2), do: "w"
  defp map_sex(_), do: ""

  @titles %{
    1 => "WCM",
    2 => "WFM",
    3 => "CM",
    4 => "WIM",
    5 => "FM",
    6 => "WGM",
    7 => "HM",
    8 => "IM",
    9 => "HG",
    10 => "GM"
  }
  defp map_title(code), do: Map.get(@titles, code, "")

  # 0 is SWAR's "this player has no fixed table". A negative value can only
  # be a corrupt (or i16-wrapped) record, and is read the same way rather
  # than becoming a table number no hall has -
  # `Player.changeset/2` validates `fixed_board` as a positive integer and
  # would reject it, failing the whole import over one junk field.
  defp fixed_board(handy_table) when is_integer(handy_table) and handy_table > 0,
    do: handy_table

  defp fixed_board(_), do: nil

  defp zero_to_nil(0), do: nil
  defp zero_to_nil(n), do: n

  defp zero_to_blank(0), do: ""
  defp zero_to_blank(n), do: Integer.to_string(n)

  # "YYYYMMDD"; "19000101" is SWAR's placeholder for an unknown birth date.
  defp birth_year(birth) when is_binary(birth) and byte_size(birth) >= 4 do
    case Integer.parse(String.slice(birth, 0, 4)) do
      {1900, _} -> nil
      {year, _} when year > 1900 -> year
      _ -> nil
    end
  end

  defp birth_year(_), do: nil

  # Full date of birth ("YYYYMMDD", same placeholder/sentinel rules as
  # `birth_year/1` above, which stays in sync since both read the same raw
  # `p.birth` string). A partial date (e.g. year known, month/day zeroed
  # out) fails `Date.new/3` and falls back to `nil` - `birth_year` alone
  # still carries what SWAR actually knew in that case.
  defp birth_date(birth) when is_binary(birth) and byte_size(birth) == 8 do
    with {year, ""} <- Integer.parse(String.slice(birth, 0, 4)),
         {month, ""} <- Integer.parse(String.slice(birth, 4, 2)),
         {day, ""} <- Integer.parse(String.slice(birth, 6, 2)),
         true <- year > 1900,
         {:ok, date} <- Date.new(year, month, day) do
      date
    else
      _ -> nil
    end
  end

  defp birth_date(_), do: nil

  # `title`/`fide_rating` prefer a resolved FIDE-database match (see
  # `resolve_fide_match/1`) over SWAR's own (often blank/stale) `Title`/
  # `EloFide` fields - but only when SWAR didn't already have its own FIDE
  # id (`p.fide_match` is only ever set for players SWAR had no `mat_fide`
  # for in the first place; see `annotate_fide_match/1`). `name` is
  # deliberately never touched here - see the comment on `create_players/3`.
  defp fide_title_or(%{fide_match: %FidePlayer{title: t}}) when is_binary(t) and t != "",
    do: t

  defp fide_title_or(p), do: map_title(p.title)

  # Only fills in a rating the player doesn't already have - SWAR's own
  # `EloFide` (when nonzero) always wins over the FIDE database's current
  # rating, which may well have moved since the tournament was played.
  defp fide_rating_or(%{fide_match: %FidePlayer{standard_rating: r}, elo_fide: 0})
       when is_integer(r),
       do: r

  defp fide_rating_or(p), do: p.elo_fide

  ## ---------- Rounds & pairings ----------

  defp create_rounds(tournament, swar_players, players_by_ni) do
    max_round =
      swar_players
      |> Enum.flat_map(& &1.rounds)
      |> Enum.map(& &1.round_nr)
      |> Enum.max(fn -> 0 end)

    # `//1` because a file with no rounds gives `1..0`, which Elixir's
    # two-argument form reads as a DESCENDING range - it iterates [1, 0],
    # warns, and asks for round 0 of a tournament that has none. The step
    # makes an empty range empty. Same shape as the two ranges fixed in the
    # engine's weighted matching (Ainalrami v0.25.0, audit finding 30).
    for round_number <- 1..max(max_round, 0)//1 do
      entries =
        for p <- swar_players, r <- p.rounds, r.round_nr == round_number, do: {p, r}

      if entries != [] do
        insert_round(tournament, round_number, entries, players_by_ni)
      end
    end
  end

  defp insert_round(tournament, round_number, entries, players_by_ni) do
    {pairings, byes} = build_round(entries, Standings.presence_scheme?(tournament))

    status = if Enum.any?(pairings, &(&1.result == "")), do: "playing", else: "finished"

    round =
      Repo.insert!(%Round{
        tournament_id: tournament.id,
        number: round_number,
        status: status,
        virtual_points: round_virtual_points(entries, players_by_ni)
      })

    Enum.each(pairings, fn p ->
      Repo.insert!(%Pairing{
        round_id: round.id,
        board: p.board,
        white_player_id: Map.fetch!(players_by_ni, p.white_ni).id,
        black_player_id: p.black_ni && Map.fetch!(players_by_ni, p.black_ni).id,
        result: p.result
      })
    end)

    if byes != [] do
      rows =
        Enum.map(byes, fn b ->
          %{
            tournament_id: tournament.id,
            player_id: Map.fetch!(players_by_ni, b.player_ni).id,
            round: round_number,
            type: b.type
          }
        end)

      Repo.insert_all("byes", rows)
    end

    PairingsEngine.Tournaments.freeze_round_display_boards!(round.id)
  end

  # Each `[RONDE]` record's `XtraPts` - the extra points SWAR paired that
  # player with in that round, frozen when the round was set up
  # (`InitNextRonde`, `AssignXtraPointsManuels`) - as the round's recorded
  # virtual points, so the next round paired here hands the engine the same
  # history SWAR's `XXA` lines would have (`Pairing.accelerations/3`), and
  # the export writes the same numbers back. Quarter points, as SWAR stores
  # them; zero entries are left out, as the pairing records them.
  defp round_virtual_points(entries, players_by_ni) do
    for {p, r} <- entries, (r[:xtra_pts] || 0) != 0, into: %{} do
      {to_string(Map.fetch!(players_by_ni, p.ni).id), r.xtra_pts / 4}
    end
  end

  # Builds one Pairing row per GAME (not per player) by walking each
  # player's [RONDE] entry for this round and, when it references a real
  # opponent, consuming both sides at once so the game isn't double-counted.
  # Entries without a real opponent become either a "bye" pairing
  # (pairing-allocated) or a row in the schemaless `byes` table (requested /
  # absent).
  defp build_round(entries, swiss321?) do
    by_ni = Map.new(entries, fn {p, r} -> {p.ni, {p, r}} end)

    {_visited, pairings, byes} =
      Enum.reduce(entries, {MapSet.new(), [], []}, fn {player, r}, {visited, pairings, byes} ->
        if MapSet.member?(visited, player.ni) do
          {visited, pairings, byes}
        else
          case mutual_opponent(player, r, by_ni) do
            {opp_player, opp_r} ->
              pairing = pair_game(player, r, opp_player, opp_r)
              visited = visited |> MapSet.put(player.ni) |> MapSet.put(opp_player.ni)
              {visited, [pairing | pairings], byes}

            nil ->
              visited = MapSet.put(visited, player.ni)

              case single_sided(player, r, swiss321?) do
                {:pairing, pairing} -> {visited, [pairing | pairings], byes}
                {:bye, bye} -> {visited, pairings, [bye | byes]}
                :nothing -> {visited, pairings, byes}
              end
          end
        end
      end)

    {finalize_boards(Enum.reverse(pairings)), Enum.reverse(byes)}
  end

  defp real_opponent(%{advers: advers}), do: advers not in [0, -1]

  # One side's `Advers` is not enough to build a game from. `pair_game/4`
  # feeds `Repo.insert!(%Pairing{})` directly, bypassing `Pairing.changeset/2`
  # and its self-pairing check, so a file whose `[RONDE]` entry points at the
  # player themselves - or at an opponent whose own entry names somebody else
  # - would write a board with the same player on both sides, or a game only
  # one player believes in. Both checks fall through to `single_sided/2`,
  # which is what an entry with no usable opponent already means.
  # `TrfImport.mutual_opponent/3` guards its rank lookup exactly this way.
  defp mutual_opponent(player, r, by_ni) do
    with true <- real_opponent(r),
         true <- r.advers != player.ni,
         {opp_player, opp_r} <- Map.get(by_ni, r.advers),
         true <- opp_r.advers == player.ni do
      {opp_player, opp_r}
    else
      _ -> nil
    end
  end

  # Determines white/black from the `Color` field (falling back to the
  # opponent's color, then to whichever player has the lower start number)
  # and maps each side's own Result bitfield to our result string.
  defp pair_game(pa, ra, pb, rb) do
    {white_p, white_r, black_p, black_r} =
      cond do
        ra.color == 1 -> {pa, ra, pb, rb}
        ra.color == -1 -> {pb, rb, pa, ra}
        rb.color == 1 -> {pb, rb, pa, ra}
        rb.color == -1 -> {pa, ra, pb, rb}
        pa.ni <= pb.ni -> {pa, ra, pb, rb}
        true -> {pb, rb, pa, ra}
      end

    %{
      board: white_r.table,
      white_ni: white_p.ni,
      black_ni: black_p.ni,
      result: combine_results(result_class(white_r.result), result_class(black_r.result))
    }
  end

  # A player's [RONDE] entry with no real opponent: a pairing-allocated bye
  # becomes an actual "bye" Pairing row (board assigned afterwards); a
  # requested half/zero-point bye or an absence becomes a `byes` row.
  #
  # A 3-2-1 file stores its pairing bye as `LOST_BYE` on `TABLE_BYE`: SWAR
  # forces `ByeValue` to `PTS_0` for the type (TOptions.cpp:566), so
  # `SetPlayerBye` writes `GetResultByeValue()` = `LOST_BYE`
  # (PairingSwiss.cpp:73-79, 390-392). That is the pairing-allocated bye,
  # and it imports as one, so the engine knows the player has had it.
  defp single_sided(player, r, swiss321?) do
    case result_class(r.result) do
      :loss_bye when swiss321? and r.table == @table_bye ->
        {:pairing, %{board: nil, white_ni: player.ni, black_ni: nil, result: "bye"}}

      :win_bye ->
        {:pairing, %{board: nil, white_ni: player.ni, black_ni: nil, result: "bye"}}

      :draw_bye ->
        {:bye, %{player_ni: player.ni, type: "requested-half"}}

      :loss_bye ->
        {:bye, %{player_ni: player.ni, type: "requested-zero"}}

      # No result, and neither SWAR's absence table nor its bye table: a
      # round the player was not in - SWAR's `TABLE_FORFAIT` (a withdrawn
      # player's rounds, `ProcessAbsent`), or the empty record this app's
      # own export writes for a round before a late entrant joined that is
      # not an absence, or after a withdrawal. SWAR scores it nothing and
      # does not count it as an absence: `GetPoints` pays `AbsValue` only
      # for `TABLE_ABSENT` and `GetNbAbsence` counts only those (Utils.cpp
      # 1102-1118, 1254-1257). It used to become an "absent" row, so a round
      # trip through a `.swar` file paid those rounds and used up the
      # allowance with them. Nothing is stored - the shape a round a player
      # was not in has here.
      :none when r.table not in [@table_absent, @table_bye] ->
        :nothing

      _ ->
        if r.table == @table_bye do
          {:pairing, %{board: nil, white_ni: player.ni, black_ni: nil, result: "bye"}}
        else
          {:bye, %{player_ni: player.ni, type: "absent"}}
        end
    end
  end

  # Pairing-allocated byes have no real board (their Table field is the
  # TABLE_BYE sentinel, not a board number) - number them right after the
  # highest real board used in the round. Handicap-table pairings (Table in
  # TABLE_HANDICAP+1..TABLE_BYE-1, see @table_handicap above) get the same
  # treatment, placed just before the byes: SWAR's own per-round handicap
  # numbering isn't a real board number either, and left as-is it sorts a
  # pairing wildly out of place anywhere board order matters.
  @doc false
  def finalize_boards(pairings) do
    {byes, rest} = Enum.split_with(pairings, &(&1.board == nil))
    {handicap, real} = Enum.split_with(rest, &handicap_table?(&1.board))
    max_board = real |> Enum.map(& &1.board) |> Enum.max(fn -> 0 end)

    numbered_handicap =
      handicap
      |> Enum.sort_by(& &1.board)
      |> Enum.with_index(max_board + 1)
      |> Enum.map(fn {p, i} -> %{p | board: i} end)

    max_board_with_handicap = max_board + length(numbered_handicap)

    numbered_byes =
      byes
      |> Enum.with_index(1)
      |> Enum.map(fn {p, i} -> %{p | board: max_board_with_handicap + i} end)

    real ++ numbered_handicap ++ numbered_byes
  end

  defp handicap_table?(board) when is_integer(board),
    do: board >= @table_handicap and board < @table_bye

  defp handicap_table?(_), do: false

  ## ---------- Result bitfield mapping (manual §5.2) ----------

  defp result_class(0x4000), do: :win
  defp result_class(0x2000), do: :draw
  defp result_class(0x1000), do: :loss
  defp result_class(0x0400), do: :zero_zero
  defp result_class(0x0200), do: :draw_zero
  defp result_class(0x0100), do: :zero_draw
  defp result_class(0x0040), do: :win_bye
  defp result_class(0x0020), do: :draw_bye
  defp result_class(0x0010), do: :loss_bye
  defp result_class(0x0008), do: :zero_zeroff
  defp result_class(0x0004), do: :win_ff
  defp result_class(0x0002), do: :draw_ff
  defp result_class(0x0001), do: :loss_ff
  defp result_class(0), do: :none
  defp result_class(_), do: :unknown

  # Combines each side's own result class into our symmetric result string.
  # DRAW_ZERO/ZERO_DRAW (one side scores 0.5, the other 0) is a legacy SWAR
  # result once used for special occasions (per the federation it no longer
  # appears in real files) - each side's own class already names BOTH
  # players' scores from that side's perspective ("I scored the draw value,
  # my opponent scored zero" / vice versa), so a mutually-consistent pair
  # maps directly onto "1/2-0"/"0-1/2", FIDE's own VCL.13 asymmetric result.
  #
  # Public (not just the `defp` this started as) so a test can exercise
  # every result-class combination directly - real DRAW_ZERO/ZERO_DRAW SWAR
  # fixtures don't exist to build a binary test file from (see above), same
  # reasoning as `finalize_boards/1`'s own `@doc false def`.
  @doc false
  def combine_results(:win, :loss), do: "1-0"
  def combine_results(:loss, :win), do: "0-1"
  def combine_results(:draw, :draw), do: "1/2-1/2"
  def combine_results(:draw_ff, :draw_ff), do: "1/2-1/2"
  def combine_results(:win_ff, :loss_ff), do: "1-0FF"
  def combine_results(:loss_ff, :win_ff), do: "0-1FF"
  def combine_results(:zero_zeroff, :zero_zeroff), do: "0-0FF"
  def combine_results(:zero_zero, :zero_zero), do: "0-0"
  def combine_results(:draw_zero, :zero_draw), do: "1/2-0"
  def combine_results(:zero_draw, :draw_zero), do: "0-1/2"
  def combine_results(:none, _), do: ""
  def combine_results(_, :none), do: ""
  def combine_results(_, _), do: ""
end
