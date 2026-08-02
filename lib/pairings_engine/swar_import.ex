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

  import Ecto.Query

  alias PairingsEngine.Repo
  alias PairingsEngine.{Tournaments, Standings}
  alias PairingsEngine.Tournaments.{Tournament, Player, Round, Pairing}
  alias PairingsEngine.Fide.FidePlayer

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

  # `points_adjusted` (SWAR's arbiter-entered correction) arrived in v6.49
  # and is gone again in v7, whose [JOUEURS] record is exactly one int
  # shorter across the `NbParties`..`Perf` run. Every int in that run is zero
  # in the only v7 file available to reverse engineer against (its tournament
  # hadn't started), so which one was dropped isn't provable from it —
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

    # v7 dropped `EloFide`: Belgium retired its own rating list (the KBSB
    # export's `Elo` column is zero for everyone now), so the single Elo a v7
    # record still carries *is* the FIDE rating — checked against the local
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
  # TABLE_FORFAIT (0x2000) and TABLE_ABSENT (0x4000) don't need a dedicated
  # constant: any single-sided entry that isn't a bye/draw-bye/loss-bye falls
  # through to the "absent" `byes` row regardless of its exact Table value.
  @table_bye 0x1000

  @doc """
  Reads a `.swar` file from `path`, parses it, and creates the tournament
  (with its players, rounds and pairings) inside a single transaction — the
  original one-step API, kept for any non-interactive caller (tests, a
  future CLI/API import, ...) that has no way to ask a human to resolve a
  missing FIDE id. Players SWAR has no `mat_fide` for are matched against
  the local FIDE database same as `prepare_import/1` (see there); anyone
  left ambiguous or unmatched is simply imported without a `fide_id`,
  exactly like before this module could match FIDE ids at all.
  Pass a `%PairingsEngine.Accounts.Scope{}` as `scope` to make the logged-in
  user the owner; `nil` creates it unowned (visible to nobody in the web UI).
  Returns `{:ok, %Tournament{}, warnings}` or `{:error, reason}` — `warnings`
  is a (possibly empty) list from `points_adjusted_warnings/3`: SWAR's own
  arbiter-entered `points_adjusted` correction (file version >= v6.49) can't
  be reconstructed from replayed pairings/byes the way ordinary standings
  always are, so an import that silently drops it is flagged here instead.
  """
  def import_file(path, scope \\ nil) do
    with {:ok, binary} <- File.read(path),
         {:ok, data} <- parse(binary) do
      cache = build_fide_candidates_cache(data.players)
      players = Enum.map(data.players, &best_effort_fide_match(&1, cache))
      run_import(%{data | players: players}, scope)
    else
      {:error, reason} -> {:error, reason}
    end
  end

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
  []` means every player is already settled — the caller can go straight to
  `commit_import(prepared, %{}, scope)` without showing anything.
  """
  def prepare_import(path) do
    with {:ok, binary} <- File.read(path),
         {:ok, data} <- parse(binary) do
      cache = build_fide_candidates_cache(data.players)

      {players, unresolved} =
        Enum.map_reduce(data.players, [], fn p, unresolved ->
          case resolve_fide_match(p, cache) do
            {:matched, resolved} -> {resolved, unresolved}
            {:unresolved, candidates} -> {p, [unresolved_entry(p, candidates) | unresolved]}
            :not_applicable -> {p, unresolved}
          end
        end)

      {:ok, %{data: %{data | players: players}, unresolved: Enum.reverse(unresolved)}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Commits a tournament from `prepared` (as returned by `prepare_import/1`),
  applying the caller's chosen resolution for each of `prepared.unresolved`
  first. `resolutions` maps a player's `ni` (the SWAR internal number used
  as the key throughout `unresolved`) to either a FIDE id (integer) to
  adopt, or anything else (`nil`, `"skip"`, or simply an absent key) to
  import that player without a `fide_id` — same outcome as if no match had
  ever been attempted. Runs the same single-transaction,
  broadcast-after-commit import as `import_file/2`.
  Returns `{:ok, %Tournament{}, warnings}` or `{:error, reason}` — see
  `import_file/2` for what `warnings` carries.
  """
  def commit_import(%{data: data}, resolutions, scope \\ nil) when is_map(resolutions) do
    players = Enum.map(data.players, &apply_resolution(&1, resolutions))
    run_import(%{data | players: players}, scope)
  end

  @doc """
  Parses `binary` (a raw `.swar` file's bytes — same shape `parse/1` and
  `import_file/2` take) and builds unpersisted `%Tournament{}`/`%Player{}`
  structs, reusing the exact same header/player field mapping (federation
  normalization, birth dates, ratings, ...) `import_file/2` writes to the
  database with — but with NO `Repo` calls whatsoever: nothing is written,
  and no FIDE-database resolve step runs (that needs the DB — see
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
    with {:ok, tournament} <- build_tournament_struct(data),
         {:ok, players} <- build_player_structs(data.players, data.categories) do
      {:ok, {tournament, players}}
    end
  end

  defp build_tournament_struct(data) do
    %Tournament{}
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
  # broadcast — the transaction may still roll back, and even on success a
  # subscriber could otherwise query the database before the writes are
  # committed. Broadcast once, for real, after commit.
  #
  # Status is derived the same way, and for the same reason: `refresh_status!/1`
  # runs *after* the transaction commits (so it sees the imported rounds/
  # results as they actually landed) and outside `with_broadcast_suppressed`
  # (so its own broadcast, if the status actually changed, isn't swallowed).
  # A fully-scored import (every paired round has every result) lands on
  # "finished"; a partial one lands on "running" — see
  # `PairingsEngine.Tournaments.refresh_status!/1`.
  defp run_import(data, scope) do
    result =
      Tournaments.with_broadcast_suppressed(fn ->
        Repo.transaction(fn ->
          case do_import(data, scope) do
            {:ok, tournament, warnings} -> {tournament, warnings}
            {:error, reason} -> Repo.rollback(reason)
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
    with {:ok, tournament} <- create_tournament(data, scope) do
      players_by_ni = create_players(tournament, data.players, data.categories)
      create_rounds(tournament, data.players, players_by_ni)
      warnings = points_adjusted_warnings(tournament, data, players_by_ni)
      {:ok, tournament, warnings}
    end
  end

  # SWAR's own arbiter-entered correction (appeals, deductions — file version
  # >= v6.49's points_adjusted field) can't be reconstructed by replaying
  # pairings/byes the way our own standings always are, so it's silently
  # discarded on import unless we say something. Mirrors
  # TrfImport.points_warnings/3's declared-vs-recomputed cross-check.
  #
  # Gated on the file actually carrying points_adjusted at all (see
  # `has_points_adjusted?/1`) — files from outside that window hardcode it to
  # 0 regardless of a player's real score (see parse_player/2), so comparing
  # that against real computed points would produce a false-positive warning
  # for nearly every player.
  # `version_gte?/2` is a plain private function (not a `defguard`), so this
  # is a single-clause function with an `if` rather than two pattern-matched
  # clauses guarded on it.
  defp points_adjusted_warnings(tournament, data, players_by_ni) do
    if has_points_adjusted?(data.version) do
      computed_by_id =
        tournament
        |> Standings.standings()
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
  # (no `fide_id`) — there's nobody to ask.
  defp best_effort_fide_match(p, cache) do
    case resolve_fide_match(p, cache) do
      {:matched, resolved} -> resolved
      _ -> p
    end
  end

  # One query per DISTINCT federation among players SWAR left with no FIDE
  # id (`mat_fide == 0`), instead of one query per such PLAYER —
  # `fide_candidates/2` below reads from this instead of re-querying for a
  # federation an earlier player in the same file already covered.
  defp build_fide_candidates_cache(players) do
    federations =
      players
      |> Enum.filter(&(&1.mat_fide == 0))
      |> Enum.map(&normalize_federation(&1.country))
      |> Enum.uniq()

    Map.new(federations, fn federation ->
      {federation, Repo.all(from(f in FidePlayer, where: f.federation == ^federation))}
    end)
  end

  # `mat_fide == 0` means SWAR itself has no FIDE id on file for this
  # player — the only case worth searching the local FIDE database for.
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
  # FIDE database already store it) + same federation, *any* birth year —
  # this is both the pool `resolve_fide_match/1` narrows down to an exact
  # birth-year match, and the candidate list shown to the user when it
  # can't (so "right person, wrong/missing year on one side" still shows up
  # as a one-click choice instead of falling through to "no match").
  defp fide_candidates(p, cache) do
    name = normalize_name_for_match(p.name)
    federation = normalize_federation(p.country)

    cache
    |> Map.get(federation, [])
    |> Enum.filter(&(normalize_name_for_match(&1.name) == name))
  end

  # Diacritics are folded, not just case: SWAR carries whatever the arbiter
  # typed (CP-1252, so "Müller" round-trips fine) while the FIDE list is
  # inconsistent about them, and a plain downcase makes "Müller"/"Muller" two
  # different people — the player then shows up with no candidates at all,
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

  # Same name, ANY federation — for the candidate list only, never for
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
      federation: normalize_federation(p.country),
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
  # place (see `resolve_fide_match/1`) — a player that already had one, or
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

    %Tournament{user_id: scope && scope.user.id}
    |> Tournament.changeset(attrs)
    |> Repo.insert()
  end

  ## ---------- Arbiters / officials ----------

  # Titles SWAR prefixes an official's name with. Arbiter (IA/FA/NA/…) and
  # organizer (IO/NO) grades both show up in these fields, and FIDE's own
  # database stores the name without them, so they have to come off before
  # anything can be matched — or written into an IT3/FA1 name cell.
  @official_titles ~w(IA FA NA IO NO FST FI FT DI SI NI)

  @doc false
  # SWAR writes officials as "TITLE First Last", comma-separating multiple
  # people in one field ("IA Sylvin De Vet, NA Marc Van Dyck"). That's the
  # opposite convention to FIDE's "Last, First", so a comma here is a person
  # boundary, not a name boundary — safe to split on precisely because SWAR
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
  # Names only — FIDE ids need the database, so they're filled in by
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
  # schema and the FIDE forms, so multiples are joined rather than dropped —
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
  # name resolves to exactly one FIDE entry. Only ever runs on the persisting
  # path — `tournament_attrs/1` is shared with the pure `build_structs/1`
  # builder, which must not touch the database.
  defp resolve_official_fide_ids(attrs) do
    officials = Map.get(attrs, :officials) || %{}

    officials =
      1..4
      |> Enum.reduce(officials, fn n, acc ->
        put_official_fide_id(acc, "deputy#{n}_name", "deputy#{n}_fide_id")
      end)

    officials =
      case match_official_fide_id(Map.get(attrs, :chief_arbiter)) do
        nil -> officials
        id -> Map.put(officials, "chief_arbiter_fide_id", to_string(id))
      end

    Map.put(attrs, :officials, officials)
  end

  defp put_official_fide_id(officials, name_key, id_key) do
    case match_official_fide_id(Map.get(officials, name_key)) do
      nil -> officials
      id -> Map.put(officials, id_key, to_string(id))
    end
  end

  # An official's name matched against the FIDE database, or `nil` unless
  # exactly one entry matches — same "never silently guess" rule the player
  # matcher follows.
  #
  # Compares an order-independent token set, because the two sides disagree on
  # word order by convention: SWAR has "Sylvin De Vet", FIDE has "De Vet,
  # Sylvin". Sorting the (diacritic-folded) tokens makes those equal without
  # having to guess which words are the surname.
  defp match_official_fide_id(name) do
    case official_name_key(name) do
      [] ->
        nil

      tokens ->
        tokens
        |> fide_players_matching_tokens()
        |> Enum.filter(&(official_name_key(&1.name) == tokens))
        |> case do
          [one] -> one.fide_id
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
  # `other_federation_candidates/2` — the index folds diacritics the same way
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
  # (pure, no Repo) — the one place SWAR's [TOURNOI]/[DATES]/[TIE_BREAK]/
  # [CATEGORIES] header fields map onto `Tournament.changeset/2` attrs.
  defp tournament_attrs(data) do
    t = data.tournament

    %{
      name: t.name,
      type: map_tournament_type(t.type),
      venue: t.city,
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
      rate_of_play: t.cadence_other,
      organizer_club_number: t.club_or_logo,
      round_dates: Enum.map(data.dates, &normalize_date/1),
      categories: map_categories(data.categories),
      # `AbsValue` (manual §4.2 field 92, general [TOURNOI] header, fields
      # 91/96 group alongside `ByeValue`/`FF_Value`) — the points paid for a
      # plain absence (`byes` row `type: "absent"`). Unlike `presence_value`
      # (SW321_Pre, only mapped inside `scoring_attrs/1`'s `type == 3`
      # clause), this applies to EVERY SWAR import regardless of tournament
      # type, so it's mapped here unconditionally rather than in
      # `scoring_attrs/1`. Raw `abs_value` is a `UChar`: 0 or 5, representing
      # 0.0 or 0.5 points.
      abs_value: if(t.abs_value == 5, do: 0.5, else: 0.0)
    }
    |> Map.merge(scoring_attrs(t))
  end

  # `TOURNOI_TYPE.SWISS_321 == 3` (manual §5.1) is the flag for "this
  # tournament's [TOURNOI] header carries custom win/draw/loss/bye point
  # values" — SWAR's "3-2-1" scoring feature, which despite the name is a
  # club-configurable point scale (win/draw/loss are independently settable
  # ints), not literally fixed at 3/2/1. `SW321_Win/Nul/Los/Bye` are stored
  # ×4 — this is what the format manual states explicitly for this field
  # group (twice: in the field table and in "Known Quirks"), mirroring how
  # the ordinary per-player `Points` field is ×2. A PREVIOUS version of this
  # function used ÷8, which silently HALVED every configured point value
  # relative to what the club actually set up (e.g. a real win worth 2.0
  # points imported as 1.0) — this is the bug reported by KBSB: "players
  # don't get the full 3-2-1 points from played games". The ÷8 divisor had
  # been "verified" by checking that dividing the file's raw per-player
  # `points` total by 8 reproduced `wins*1.0 + draws*0.5 + 0*losses`
  # (SW321_Los happened to be 0 in the fixture) — but that check is
  # circular: SW321_Los being 0 makes losses contribute nothing to the
  # total regardless of the divisor chosen, so *any* divisor "passes" that
  # check while only the ratio (2:1:0 here) is actually being tested, never
  # the absolute scale. See docs/swar-import.md for the non-circular
  # re-derivation (the manual's explicit ×4 annotation, cross-checked
  # against multiple real players' totals via an independently-discovered
  # formula involving `SW321_Pre`).
  #
  # `SW321_Pre` ("presence points", manual §4.6 field 84) DOES appear in
  # the real 3-2-1 fixture — every unpaired "LOST_BYE" round for every
  # affected player is scored as `SW321_Pre` raw points (÷4), not
  # `SW321_Bye` (no `WIN_BYE`/`DRAW_BYE` round occurs anywhere in the
  # fixture, so `SW321_Bye`'s actual role is unconfirmed by this file).
  # `Tournament.presence_value` now models this: SWAR's own result-code
  # bitmask (manual §5.2, `RESULTATS_LOST`) files `LOST_BYE` under its
  # generic "loss" category, but 3-2-1 mode pays it at `SW321_Pre`
  # specifically, not at `SW321_Los`/`points_loss` — confirmed non-circularly
  # against the real fixture (see above). `SW321_PreBye` (field 85, manual
  # §5.16, present only in file version >= v6.03) is documented verbatim as
  # "Add presence points for bye games" — i.e. a pairing-allocated bye
  # (`WIN_BYE`) is paid `SW321_Bye + SW321_Pre` when it is set/nonzero.
  # That option maps onto `Tournament.presence_on_allocated_bye` (a boolean
  # flag consulted by `PairingsEngine.Standings.bye_points/2`, which adds
  # `presence_value` on top of `bye_value` for a pairing-allocated bye when
  # set) rather than being folded into `bye_value` here — an earlier version
  # of this clause did fold it in (`bye_value: SW321_Bye/4 + SW321_Pre/4`),
  # which produced the right totals but silently redefined `bye_value` away
  # from the club's configured SW321_Bye, losing the distinction for
  # display/editing.
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

  defp scoring_attrs(t), do: %{bye_value: map_bye_value(t.bye_value)}

  # `SW321_PreBye` (manual §5.16, field 85 — only present in file version >=
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

  # SWAR's [TOURNOI] `federation` field is *which Belgian federation entity*
  # organizes the tournament, not a FIDE country code: FRBE/KBSB are the
  # (French/Dutch-named) national federation itself, FEFB/VSF/SVDB are its
  # Walloon/Flemish regional leagues, and code 6 is "direct FIDE" homologation
  # with no specific sub-federation. All of these are Belgium as far as FIDE
  # reporting is concerned — `normalize_federation/1` collapses them to the
  # single FIDE country code "BEL" that TRF export and the tournament's own
  # `federation` field are supposed to carry (see docs/swar-import.md).
  @federations %{
    0 => "",
    1 => "FRBE",
    2 => "KBSB",
    3 => "FEFB",
    4 => "VSF",
    5 => "SVDB",
    6 => "FIDE"
  }
  defp map_federation(code), do: Map.get(@federations, code, "") |> normalize_federation()

  # Regional/organizational markers that all mean "Belgium" for FIDE-reporting
  # purposes — never a genuine ISO/FIDE country code in their own right, so
  # they must never end up in `tournament.federation` / `player.federation`
  # (TRF export reads those fields directly — see docs/import-export.md).
  # "FIDE" (SWAR federation code 6, "direct FIDE homologation, no specific
  # sub-federation") is included too — this importer only ever sees
  # KBSB/FRBE-organized tournaments, so it's still Belgium, just not
  # attributed to one of the named regional leagues. Any other value (a
  # real FIDE federation code, or "" for "none selected") passes through
  # unchanged.
  @belgian_federation_markers ~w(FRBE KBSB FEFB VSF SVDB FIDE)

  @doc """
  Collapses a Belgian regional/organizational federation marker (any of
  `#{inspect(@belgian_federation_markers)}`) to the single FIDE country
  code "BEL"; any other value (a real FIDE federation code, or "" for
  "none selected") passes through unchanged. Public so
  `PairingsEngine.TrfExport` can apply the same normalization defensively
  at export time, for a tournament whose `federation` field was already
  stored raw in the database (e.g. imported before this normalization
  existed on the SWAR-import side) — see `docs/swar-import.md`.
  """
  def normalize_federation(code) when is_binary(code) do
    upcased = code |> String.trim() |> String.upcase()
    if upcased in @belgian_federation_markers, do: "BEL", else: upcased
  end

  def normalize_federation(other), do: other

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
      {:ok, player} = Tournaments.create_player(tournament.id, player_attrs(p, categories))
      {p.ni, player}
    end
  end

  # Shared by `create_players/3` (persisting) and `build_player_structs/2`
  # (pure, no Repo) — the one place a parsed SWAR [JOUEURS] record maps onto
  # `Player.changeset/2` attrs.
  defp player_attrs(p, categories) do
    %{
      # SWAR's own spelling is canonical — a FIDE database match (see
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
      federation: normalize_federation(p.country),
      birth_year: birth_year(p.birth),
      birth_date: birth_date(p.birth),
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

  # Full date of birth ("YYYYMMDD", same placeholder/sentinel rules as
  # `birth_year/1` above, which stays in sync since both read the same raw
  # `p.birth` string). A partial date (e.g. year known, month/day zeroed
  # out) fails `Date.new/3` and falls back to `nil` — `birth_year` alone
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
  # `EloFide` fields — but only when SWAR didn't already have its own FIDE
  # id (`p.fide_match` is only ever set for players SWAR had no `mat_fide`
  # for in the first place; see `annotate_fide_match/1`). `name` is
  # deliberately never touched here — see the comment on `create_players/3`.
  defp fide_title_or(%{fide_match: %FidePlayer{title: t}}) when is_binary(t) and t != "",
    do: t

  defp fide_title_or(p), do: map_title(p.title)

  # Only fills in a rating the player doesn't already have — SWAR's own
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
