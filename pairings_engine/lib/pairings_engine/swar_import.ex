defmodule PairingsEngine.SwarImport do
  @moduledoc """
  Importer for `.swar` files — the native save format of the SWAR chess
  tournament pairing program (by Georges Marchal / FRBE).

  `parse/1` is a pure binary parser that mirrors the on-disk structure as a
  plain data map. `import_file/1` builds on top of it to create a
  `PairingsEngine.Tournaments.Tournament`, its players, rounds and pairings.

  The format is a sequential binary serialization with no index and no
  recovery from misparses — every field must be read in exact order. See
  the SWAR format manual for the full field-by-field layout; the section
  order implemented here is: header, [TOURNOI], [DATES], [TIE_BREAK],
  [EXCLUSION], [CATEGORIES], [XTRA_POINTS], [JOUEURS] (with per-player
  [RONDE] round data).
  """

  alias PairingsEngine.Repo
  alias PairingsEngine.Tournaments
  alias PairingsEngine.Tournaments.{Tournament, Round, Pairing}

  ## ---------- Windows-1252 decoding ----------

  # Bytes 0x80-0x9F differ between Windows-1252 and ISO-8859-1/Latin-1.
  # Unmapped bytes in that range (81, 8D, 8F, 90, 9D) have no Windows-1252
  # assignment; we fall back to the raw codepoint so decoding never crashes.
  @cp1252_high %{
    0x80 => 0x20AC,
    0x82 => 0x201A,
    0x83 => 0x0192,
    0x84 => 0x201E,
    0x85 => 0x2026,
    0x86 => 0x2020,
    0x87 => 0x2021,
    0x88 => 0x02C6,
    0x89 => 0x2030,
    0x8A => 0x0160,
    0x8B => 0x2039,
    0x8C => 0x0152,
    0x8E => 0x017D,
    0x91 => 0x2018,
    0x92 => 0x2019,
    0x93 => 0x201C,
    0x94 => 0x201D,
    0x95 => 0x2022,
    0x96 => 0x2013,
    0x97 => 0x2014,
    0x98 => 0x02DC,
    0x99 => 0x2122,
    0x9A => 0x0161,
    0x9B => 0x203A,
    0x9C => 0x0153,
    0x9E => 0x017E,
    0x9F => 0x0178
  }

  @doc "Decodes a Windows-1252 (CP-1252) byte string to a UTF-8 Elixir string."
  def cp1252_decode(bytes) when is_binary(bytes) do
    bytes
    |> :binary.bin_to_list()
    |> Enum.map(fn
      byte when byte >= 0x80 and byte <= 0x9F -> Map.get(@cp1252_high, byte, byte)
      byte -> byte
    end)
    |> List.to_string()
  end

  ## ---------- Primitives ----------

  defp read_i32(<<v::little-signed-32, rest::binary>>), do: {v, rest}
  defp read_i16(<<v::little-signed-16, rest::binary>>), do: {v, rest}
  defp read_u8(<<v::8, rest::binary>>), do: {v, rest}

  defp read_str(<<len::little-signed-32, rest::binary>>) when len >= 0 do
    <<bytes::binary-size(^len), rest2::binary>> = rest
    {cp1252_decode(bytes), rest2}
  end

  defp read_n(bin, 0, _fun), do: {[], bin}

  defp read_n(bin, n, fun) when n > 0 do
    {v, bin} = fun.(bin)
    {rest, bin} = read_n(bin, n - 1, fun)
    {[v | rest], bin}
  end

  defp version_gte?(version, target), do: version >= target

  ## ---------- Public API ----------

  @doc """
  Parses a raw `.swar` binary into a plain map mirroring the SWAR structure.
  Returns `{:ok, map}` or `{:error, reason}`.
  """
  def parse(binary) when is_binary(binary) do
    {version, rest} = read_str(binary)
    {guid, rest} = read_str(rest)
    {mac, rest} = read_str(rest)

    {tournoi, rest} = parse_tournoi(rest, version)
    {dates, rest} = parse_dates(rest, tournoi.nb_rounds)
    {tiebreaks, rest} = parse_tie_break(rest)
    {exclusion, rest} = parse_exclusion(rest)
    {categories, rest} = parse_categories(rest, version)
    {xtra_points, rest} = parse_xtra_points(rest)
    {players, _rest} = parse_joueurs(rest, version)

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
       players: players
     }}
  rescue
    e in MatchError -> {:error, {:parse_failed, Exception.message(e)}}
    e in ArgumentError -> {:error, {:parse_failed, Exception.message(e)}}
    e -> {:error, {:parse_failed, Exception.message(e)}}
  end

  ## ---------- [TOURNOI] ----------

  defp parse_tournoi(bin, version) do
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
        read_n(bin, 16, fn bin ->
          {de, bin} = read_i32(bin)
          {aa, bin} = read_i32(bin)
          {id, bin} = read_i32(bin)
          {%{de: de, aa: aa, id: id}, bin}
        end)
      else
        {_old_fide_id, bin} = read_str(bin)
        {[], bin}
      end

    {fide_arb1, bin} = read_str(bin)
    {fide_arb2, bin} = read_str(bin)
    {_dummy1, bin} = read_str(bin)
    {fide_remarks, bin} = read_str(bin)
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

  defp parse_categories(bin, version) do
    {_marker, bin} = read_str(bin)
    {type, bin} = read_i32(bin)
    max_categ = if version_gte?(version, "v6.50"), do: 16, else: 12
    {value1, bin} = read_n(bin, max_categ + 1, &read_str/1)
    {value2, bin} = read_n(bin, max_categ + 1, &read_str/1)
    {%{type: type, value1: value1, value2: value2}, bin}
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
    {elo_fide, bin} = read_i32(bin)
    {title, bin} = read_i32(bin)
    {club_nr, bin} = read_i32(bin)
    {club, bin} = read_str(bin)
    {nb_parties, bin} = read_i32(bin)
    {points, bin} = read_i32(bin)

    {points_adjusted, bin} =
      if version_gte?(version, "v6.49") do
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
  # TABLE_FORFAIT (0x2000) and TABLE_ABSENT (0x4000) don't need a dedicated
  # constant: any single-sided entry that isn't a bye/draw-bye/loss-bye falls
  # through to the "absent" `byes` row regardless of its exact Table value.
  @table_bye 0x1000

  @doc """
  Reads a `.swar` file from `path`, parses it, and creates the tournament
  (with its players, rounds and pairings) inside a single transaction.
  Pass a `%PairingsEngine.Accounts.Scope{}` as `scope` to make the logged-in
  user the owner; `nil` creates it unowned (visible to nobody in the web UI).
  Returns `{:ok, %Tournament{}}` or `{:error, reason}`.
  """
  def import_file(path, scope \\ nil) do
    with {:ok, binary} <- File.read(path),
         {:ok, data} <- parse(binary) do
      # Individual writes inside the transaction (players, rounds…) don't
      # broadcast — the transaction may still roll back, and even on
      # success a subscriber could otherwise query the database before the
      # writes are committed. Broadcast once, for real, after commit.
      result =
        Tournaments.with_broadcast_suppressed(fn ->
          Repo.transaction(fn ->
            case do_import(data, scope) do
              {:ok, tournament} -> tournament
              {:error, reason} -> Repo.rollback(reason)
            end
          end)
        end)

      case result do
        {:ok, tournament} ->
          Tournaments.broadcast_tournament_change(tournament.id, :tournament)
          Tournaments.broadcast_user_tournaments(tournament.user_id)

        _ ->
          :ok
      end

      result
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_import(data, scope) do
    with {:ok, tournament} <- create_tournament(data, scope) do
      players_by_ni = create_players(tournament, data.players, data.categories)
      create_rounds(tournament, data.players, players_by_ni)
      {:ok, mark_status(tournament)}
    end
  end

  # A .swar file only exists once at least one round has been paired, so an
  # imported tournament is never really at the "setup" stage — leave it
  # there only for the (empty) edge case of a file with no round data at
  # all; otherwise mark it "running" like any tournament with paired rounds.
  defp mark_status(tournament) do
    if Tournaments.list_rounds(tournament.id) == [] do
      tournament
    else
      {:ok, updated} = Tournaments.update_tournament(tournament, %{status: "running"})
      updated
    end
  end

  ## ---------- Tournament ----------

  defp create_tournament(data, scope) do
    t = data.tournament

    attrs = %{
      name: t.name,
      type: map_tournament_type(t.type),
      venue: t.city,
      city: t.city,
      federation: map_federation(t.federation),
      start_date: normalize_date(t.start_date),
      end_date: normalize_date(t.end_date),
      organizer: t.organizer,
      chief_arbiter: t.arbiter1,
      deputy_arbiter: t.arbiter2,
      rounds_count: max(t.nb_rounds, 1),
      tiebreaks: map_tiebreaks(data.tiebreaks),
      bye_value: map_bye_value(t.bye_value),
      standard: map_standard(t.tournoi_std),
      rate_of_play: t.cadence_other,
      organizer_club_number: t.club_or_logo,
      round_dates: Enum.map(data.dates, &normalize_date/1),
      categories: map_categories(data.categories)
    }

    %Tournament{user_id: scope && scope.user.id}
    |> Tournament.changeset(attrs)
    |> Repo.insert()
  end

  @tournament_types %{0 => "swiss", 1 => "swiss", 2 => "swiss", 3 => "swiss", 4 => "roundrobin", 5 => "roundrobin", 6 => "roundrobin", 7 => "swiss", 8 => "swiss"}
  defp map_tournament_type(type), do: Map.get(@tournament_types, type, "swiss")

  @federations %{0 => "", 1 => "FRBE", 2 => "KBSB", 3 => "FEFB", 4 => "VSF", 5 => "SVDB", 6 => "FIDE"}
  defp map_federation(code), do: Map.get(@federations, code, "")

  # ByeValue: 0 = full point, 1 = half point, 2 = zero points (manual §5.16).
  defp map_bye_value(0), do: 1.0
  defp map_bye_value(1), do: 0.5
  defp map_bye_value(2), do: 0.0
  defp map_bye_value(_), do: 1.0

  # Only the six methods explicitly requested map to our codes; everything
  # else (Koya, ARO, performance, black-piece stats, ...) is skipped.
  @tiebreak_codes %{1 => "BH", 4 => "BHC1", 6 => "SB", 8 => "DE", 10 => "WIN", 7 => "PS"}
  defp map_tiebreaks(codes) do
    codes
    |> Enum.map(&Map.get(@tiebreak_codes, &1))
    |> Enum.reject(&is_nil/1)
  end

  # TournoiStd: 0=Standard, 1=Rapid, 2=Blitz (manual §5.13/4.2 field 87).
  defp map_standard(0), do: "standard"
  defp map_standard(1), do: "rapid"
  defp map_standard(2), do: "blitz"
  defp map_standard(_), do: "standard"

  # [CATEGORIES]: Categorie type 0 (NO_CATEGO, manual §5.18) means the
  # tournament defines no categories at all — value1/value2 are all blank
  # padding in that case. Otherwise collect the non-blank names/boundaries
  # from both value sets (order preserved, de-duplicated).
  defp map_categories(%{type: 0}), do: []

  defp map_categories(%{value1: v1, value2: v2}) do
    (v1 ++ v2) |> Enum.reject(&(&1 == "")) |> Enum.uniq()
  end

  # Per-player CatIndex resolves into the [CATEGORIES] value1 list. Per the
  # manual's "Known Quirks" §10.2, a CatIndex < 100 is stored already
  # multiplied by 100 (so category 1 is stored as 100) — divide back down to
  # get a 0-based slot index. CatIndex 0 means "no category".
  defp category_name(0, _categories), do: ""

  defp category_name(cat_index, categories) do
    categories.value1
    |> Enum.at(div(cat_index, 100), "")
    |> to_string()
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

  # Absent: 1=Forfeit, 2=Absent, 4=Present (manual §5.19).
  defp map_absent(2), do: true
  defp map_absent(_), do: false

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

  defp create_players(tournament, swar_players, categories) do
    for p <- swar_players, into: %{} do
      attrs = %{
        name: p.name,
        sex: map_sex(p.sex),
        title: map_title(p.title),
        fide_id: zero_to_nil(p.mat_fide),
        fide_rating: p.elo_fide,
        national_id: zero_to_blank(p.mat_nat),
        national_rating: p.elo,
        federation: p.country,
        birth_year: birth_year(p.birth),
        club: p.club,
        pairing_number: p.ni,
        paid: map_paid(p.paye),
        affiliated: map_affiliated(p.affilie),
        absent: map_absent(p.absent),
        forfeit: map_forfeit(p.absent),
        special_table: p.handy_table != 0,
        absent_rounds: p.absent_rondes,
        extra_points: p.extra_pts / 4.0,
        category: category_name(p.cat_index, categories),
        club_number: zero_to_nil(p.club_nr)
      }

      {:ok, player} = Tournaments.create_player(tournament.id, attrs)
      {p.ni, player}
    end
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

  ## ---------- Rounds & pairings ----------

  defp create_rounds(tournament, swar_players, players_by_ni) do
    max_round =
      swar_players
      |> Enum.flat_map(& &1.rounds)
      |> Enum.map(& &1.round_nr)
      |> Enum.max(fn -> 0 end)

    for round_number <- 1..max(max_round, 0) do
      entries =
        for p <- swar_players, r <- p.rounds, r.round_nr == round_number, do: {p, r}

      if entries != [] do
        insert_round(tournament, round_number, entries, players_by_ni)
      end
    end
  end

  defp insert_round(tournament, round_number, entries, players_by_ni) do
    {pairings, byes} = build_round(entries)

    status = if Enum.any?(pairings, &(&1.result == "")), do: "playing", else: "finished"

    round =
      Repo.insert!(%Round{
        tournament_id: tournament.id,
        number: round_number,
        status: status
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
  end

  # Builds one Pairing row per GAME (not per player) by walking each
  # player's [RONDE] entry for this round and, when it references a real
  # opponent, consuming both sides at once so the game isn't double-counted.
  # Entries without a real opponent become either a "bye" pairing
  # (pairing-allocated) or a row in the schemaless `byes` table (requested /
  # absent).
  defp build_round(entries) do
    by_ni = Map.new(entries, fn {p, r} -> {p.ni, {p, r}} end)

    {_visited, pairings, byes} =
      Enum.reduce(entries, {MapSet.new(), [], []}, fn {player, r}, {visited, pairings, byes} ->
        if MapSet.member?(visited, player.ni) do
          {visited, pairings, byes}
        else
          opponent = if real_opponent(r), do: Map.get(by_ni, r.advers), else: nil

          case opponent do
            {opp_player, opp_r} ->
              pairing = pair_game(player, r, opp_player, opp_r)
              visited = visited |> MapSet.put(player.ni) |> MapSet.put(opp_player.ni)
              {visited, [pairing | pairings], byes}

            nil ->
              visited = MapSet.put(visited, player.ni)

              case single_sided(player, r) do
                {:pairing, pairing} -> {visited, [pairing | pairings], byes}
                {:bye, bye} -> {visited, pairings, [bye | byes]}
              end
          end
        end
      end)

    {finalize_boards(Enum.reverse(pairings)), Enum.reverse(byes)}
  end

  defp real_opponent(%{advers: advers}), do: advers not in [0, -1]

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
  defp single_sided(player, r) do
    case result_class(r.result) do
      :win_bye ->
        {:pairing, %{board: nil, white_ni: player.ni, black_ni: nil, result: "bye"}}

      :draw_bye ->
        {:bye, %{player_ni: player.ni, type: "requested-half"}}

      :loss_bye ->
        {:bye, %{player_ni: player.ni, type: "requested-zero"}}

      _ ->
        if r.table == @table_bye do
          {:pairing, %{board: nil, white_ni: player.ni, black_ni: nil, result: "bye"}}
        else
          {:bye, %{player_ni: player.ni, type: "absent"}}
        end
    end
  end

  # Pairing-allocated byes have no real board (their Table field is the
  # TABLE_BYE sentinel, not a board number) — number them right after the
  # highest real board used in the round.
  defp finalize_boards(pairings) do
    {byes, real} = Enum.split_with(pairings, &(&1.board == nil))
    max_board = real |> Enum.map(& &1.board) |> Enum.max(fn -> 0 end)

    numbered_byes =
      byes
      |> Enum.with_index(1)
      |> Enum.map(fn {p, i} -> %{p | board: max_board + i} end)

    real ++ numbered_byes
  end

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
  # NOTE: DRAW_ZERO/ZERO_DRAW (one side scores 0.5, the other 0) is a legacy
  # SWAR result once used for special occasions; per the federation it no
  # longer appears in real files. It has no equivalent here, so it is
  # deliberately dropped: the pairing imports with a blank result.
  defp combine_results(:win, :loss), do: "1-0"
  defp combine_results(:loss, :win), do: "0-1"
  defp combine_results(:draw, :draw), do: "1/2-1/2"
  defp combine_results(:draw_ff, :draw_ff), do: "1/2-1/2"
  defp combine_results(:win_ff, :loss_ff), do: "1-0FF"
  defp combine_results(:loss_ff, :win_ff), do: "0-1FF"
  defp combine_results(:zero_zeroff, :zero_zeroff), do: "0-0FF"
  defp combine_results(:zero_zero, :zero_zero), do: "0-0"
  defp combine_results(:draw_zero, :zero_draw), do: ""
  defp combine_results(:zero_draw, :draw_zero), do: ""
  defp combine_results(:none, _), do: ""
  defp combine_results(_, :none), do: ""
  defp combine_results(_, _), do: ""
end
