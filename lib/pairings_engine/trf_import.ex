defmodule PairingsEngine.TrfImport do
  @moduledoc """
  Imports a FIDE TRF16 file (`PairingsEngine.Trf.parse/1`) as a brand-new
  tournament — players, rounds, pairings, byes — owned by the importing
  user. One-step, single-transaction create, same shape as
  `PairingsEngine.SwarImport.import_file/2`: broadcast-suppressed writes
  inside the transaction, `Tournaments.refresh_status!/1` and the real
  broadcasts after commit.

  TRF16 has no board-number field and no explicit "which two rows are the
  same game" marker beyond each player's own per-round opponent reference —
  a game is reconstructed by pairing up two players' round columns when
  they mutually reference each other (mirrors `PairingsEngine.Trf`'s own
  `validate_games!/1`, which already guarantees any *mutual* pair is
  legal). Board numbers are then assigned sequentially in starting-rank
  order, real games before byes. See `docs/trf-import.md`.

  TRF's own per-player points column (TRF16 columns 81-84) is a
  self-reported total that arbiter software sometimes leaves stale after a
  late correction — it is never trusted outright. After import,
  `PairingsEngine.Pairing.trf_player_rows/2` recomputes each player's
  points from what was actually written to the database (same formula
  `PairingsEngine.TrfExport` uses), and any player whose recomputed total
  disagrees with the TRF file's declared total is returned in `warnings`
  for the caller to show as a notice — the import itself always proceeds
  either way.
  """

  alias PairingsEngine.{Repo, SwarImport, Tournaments, Trf}
  alias PairingsEngine.Tournaments.{Tournament, Player, Round, Pairing}
  alias PairingsEngine.Pairing, as: PairingCtx
  alias PairingsEngine.Trf.ValidationError

  @doc """
  Parses `content` (a TRF16 file's raw text) and imports it as a new
  tournament owned by `scope`'s user (`nil` creates it unowned, same as
  `SwarImport.import_file/2`).

  Returns `{:ok, %Tournament{}, warnings}` where `warnings` is a (possibly
  empty) list of `%{player_name:, trf_points:, computed_points:}` maps — one
  per player whose recomputed points disagree with the TRF file's own
  points column (see the moduledoc). Returns `{:error, reason}` on a parse
  failure or an invalid file; never raises. `reason` is either a
  `PairingsEngine.Trf.ValidationError` struct, a `{:parse_failed, message}`
  tuple, or a plain string — pass it to `error_message/1` for a single
  user-facing string.
  """
  def import_text(content, scope \\ nil) when is_binary(content) do
    case build_structs_with_data(content) do
      {:ok, {_tournament, _players, data}} -> run_import(data, scope)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Parses `content` (a TRF16 file's raw text, same as `import_text/2`) and
  builds unpersisted `%Tournament{}`/`%Player{}` structs — same decoding
  (CP1252/BOM fallback), parsing and header/player field mapping
  `import_text/2` itself uses internally, but with NO `Repo` calls: nothing
  is written to the database, and the returned structs have no `id` (never
  needed — `PairingsEngine.Norms.Forms` only ever reads scalar fields off a
  tournament/player, never `id`).

  Unlike `import_text/2`, this never builds rounds/pairings/byes — TRF's
  round data has no representation independent of a persisted tournament's
  players and round rows, and no caller of this pure builder (norm-report
  generation from an uploaded file) needs it. Returns `{:ok, {tournament,
  players}}` or `{:error, reason}` (see `error_message/1`); never raises.
  """
  def build_structs(content) when is_binary(content) do
    case build_structs_with_data(content) do
      {:ok, {tournament, players, _data}} -> {:ok, {tournament, players}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Shared by `import_text/2` and `build_structs/1`: decode + parse + build
  # the same unpersisted structs either caller needs, while also handing
  # back the raw parsed `data` (with each player's per-round games) that
  # only `import_text/2`'s round-building step still needs.
  defp build_structs_with_data(content) do
    case content |> decode_content() |> parse_trf() do
      {:ok, data} ->
        with {:ok, tournament} <- build_tournament_struct(data),
             {:ok, players} <- build_player_structs(data.players) do
          {:ok, {tournament, players, data}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_tournament_struct(data) do
    %Tournament{}
    |> Tournament.changeset(tournament_attrs(data))
    |> case do
      %{valid?: true} = changeset -> {:ok, Ecto.Changeset.apply_changes(changeset)}
      changeset -> {:error, "Could not import: " <> changeset_error_text(changeset)}
    end
  end

  defp build_player_structs(trf_players) do
    trf_players
    |> Enum.reduce_while({:ok, []}, fn p, {:ok, acc} ->
      case %Player{} |> Player.changeset(player_attrs(p)) do
        %{valid?: true} = changeset ->
          {:cont, {:ok, [Ecto.Changeset.apply_changes(changeset) | acc]}}

        changeset ->
          {:halt,
           {:error,
            "Could not import player #{String.trim(p.name || "")}: " <>
              changeset_error_text(changeset)}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Formats any error `import_text/2` can return as a single flash-ready string."
  def error_message(%ValidationError{message: message}),
    do: "This TRF file has an invalid result: #{message}"

  def error_message({:parse_failed, message}), do: "Could not read this TRF file: #{message}"
  def error_message(reason) when is_binary(reason), do: reason
  def error_message(reason), do: "Could not import this TRF file: #{inspect(reason)}"

  ## ---------- encoding ----------

  # TRF files exported by Windows chess software (SWAR and similar) are
  # frequently Windows-1252 encoded rather than UTF-8 — an accented name
  # (e.g. "Boûtchon", "Gaëtan") then arrives as raw single-byte CP1252,
  # which is not valid UTF-8 on its own. Left untranslated, that byte
  # sequence gets stored as invalid UTF-8 straight through the database:
  # mojibake in the UI and in every re-export (TRF, norms xlsx, ...).
  #
  # Mirrors the same strip-BOM-before-detect + CP1252-fallback pattern
  # `PairingsEngine.Kbsb.Parser.parse/1` uses for the rating-list import
  # (see there), reusing the same `SwarImport.cp1252_decode/1` helper
  # either fallback needs. Order matters: stripping the BOM first, on the
  # raw bytes, means a CP1252-encoded file that happens to start with a
  # UTF-8 BOM never has those 3 bytes mis-decoded into three valid-but-wrong
  # characters by the CP1252 fallback.
  defp decode_content(content) do
    content
    |> strip_bom_bytes()
    |> decode()
  end

  defp strip_bom_bytes(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom_bytes(binary), do: binary

  defp decode(binary) do
    if String.valid?(binary), do: binary, else: SwarImport.cp1252_decode(binary)
  end

  ## ---------- parsing ----------

  defp parse_trf(content) do
    case Trf.parse(content) do
      %{players: []} -> {:error, {:parse_failed, "no player records (\"001\" lines) found"}}
      data -> validate_unique_ranks(data)
    end
  rescue
    e in ValidationError -> {:error, e}
    e -> {:error, {:parse_failed, Exception.message(e)}}
  end

  # Every downstream step keys players by their TRF starting rank
  # (`create_players/2`'s `players_by_rank` map, and `build_round/1`'s own
  # `by_rank`) via `Map.new/2`, which silently keeps only the *last* entry
  # for a repeated key. A corrupt or malicious TRF with two "001" lines
  # sharing the same starting rank would otherwise import both players as
  # DB rows, but silently drop the first one's rounds and hand its rank
  # over to the second — an orphan player nobody's games reference. Caught
  # up front, before any row is written, so this is always a clean rollback
  # rather than a half-imported tournament.
  defp validate_unique_ranks(data) do
    dupes =
      data.players
      |> Enum.map(& &1.rank)
      |> Enum.frequencies()
      |> Enum.filter(fn {_rank, count} -> count > 1 end)
      |> Enum.map(fn {rank, _count} -> rank end)
      |> Enum.sort()

    case dupes do
      [] ->
        {:ok, data}

      _ ->
        {:error,
         {:parse_failed, "duplicate starting rank(s) in \"001\" lines: #{Enum.join(dupes, ", ")}"}}
    end
  end

  ## ---------- transaction wrapper (mirrors SwarImport.run_import/2) ----------

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
      players_by_rank = create_players(tournament, data.players)
      create_rounds(tournament, data.players, players_by_rank)
      warnings = points_warnings(tournament, data.players, players_by_rank)
      {:ok, tournament, warnings}
    end
  end

  ## ---------- tournament ----------

  defp create_tournament(data, scope) do
    %Tournament{user_id: scope && scope.user.id}
    |> Tournament.changeset(tournament_attrs(data))
    |> Repo.insert()
    |> case do
      {:ok, tournament} -> {:ok, tournament}
      {:error, changeset} -> {:error, "Could not import: " <> changeset_error_text(changeset)}
    end
  end

  # Shared by `create_tournament/2` (persisting) and `build_tournament_struct/1`
  # (pure, no Repo) — the one place TRF's header fields map onto
  # `Tournament.changeset/2` attrs.
  defp tournament_attrs(data) do
    t = data.tournament
    {chief_arbiter, chief_fide_id} = parse_arbiter_line(t[:chief_arbiter])

    %{
      name: blank_to_default(t[:name], "Imported tournament"),
      type: infer_type(t[:type]),
      pairing_system: "swiss",
      venue: t[:city] || "",
      city: t[:city] || "",
      federation: t[:federation] || "",
      start_date: t[:start_date] || "",
      end_date: t[:end_date] || "",
      chief_arbiter: chief_arbiter || "",
      time_control: t[:time_control] || "",
      rounds_count: max(rounds_from_data(data.players), 1),
      round_dates: t[:round_dates] || [],
      officials: deputy_officials(t[:deputy_arbiters] || [], chief_fide_id)
    }
  end

  defp rounds_from_data(players) do
    from_games = players |> Enum.map(&length(&1.games)) |> Enum.max(fn -> 0 end)
    from_games
  end

  # TRF16's 092/112 arbiter lines are "<FIDE id> <name>" when the id is
  # known (this is exactly the inverse of TrfExport.chief_arbiter_line/1 /
  # deputy_arbiter_lines/1), else just the free-text name.
  defp parse_arbiter_line(nil), do: {nil, nil}
  defp parse_arbiter_line(""), do: {nil, nil}

  defp parse_arbiter_line(line) do
    case Regex.run(~r/^(\d+)\s+(.+)$/, String.trim(line)) do
      [_, id, name] -> {name, id}
      _ -> {line, nil}
    end
  end

  defp deputy_officials(deputies, chief_fide_id) do
    base = if chief_fide_id, do: %{"chief_arbiter_fide_id" => chief_fide_id}, else: %{}

    deputies
    |> Enum.take(4)
    |> Enum.with_index(1)
    |> Enum.reduce(base, fn {line, n}, acc ->
      {name, fide_id} = parse_arbiter_line(line)

      acc
      |> maybe_put("deputy#{n}_name", name)
      |> maybe_put("deputy#{n}_fide_id", fide_id)
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp blank_to_default(v, default) when v in [nil, ""], do: default
  defp blank_to_default(v, _default), do: v

  # "Individual: Swiss System" / "Team: Round Robin System" etc (see
  # PairingsEngine.Trf's @type_labels) — reverse-mapped by substring rather
  # than an exact table, since a hand-written or third-party TRF's 092 line
  # may phrase it slightly differently.
  defp infer_type(nil), do: "swiss"

  defp infer_type(label) do
    team? = String.contains?(label, "Team")
    rr? = String.contains?(label, "Round Robin")

    cond do
      team? and rr? -> "team-roundrobin"
      team? -> "team-swiss"
      rr? -> "roundrobin"
      true -> "swiss"
    end
  end

  ## ---------- players ----------

  defp create_players(tournament, trf_players) do
    Map.new(trf_players, fn p ->
      case Tournaments.create_player(tournament.id, player_attrs(p)) do
        {:ok, player} ->
          {p.rank, player}

        {:error, :duplicate_fide_id} ->
          Repo.rollback(
            "Duplicate FIDE id #{p.fide_number} (player #{String.trim(p.name || "")})"
          )

        {:error, changeset} ->
          Repo.rollback(
            "Could not import player #{String.trim(p.name || "")}: " <>
              changeset_error_text(changeset)
          )
      end
    end)
  end

  defp player_attrs(p) do
    {birth_date, birth_year} = birth_from_iso(p.birth_date)

    %{
      name: String.trim(p.name || ""),
      sex: p.sex || "",
      title: p.title || "",
      fide_id: zero_to_nil(p.fide_number),
      fide_rating: p.fide_rating || 0,
      federation: p.federation || "",
      birth_year: birth_year,
      birth_date: birth_date,
      pairing_number: p.rank
    }
  end

  defp zero_to_nil(0), do: nil
  defp zero_to_nil(v), do: v

  # Trf.parse's birth_date is already "" | "YYYY-MM-DD" | "YYYY-00-00" (the
  # year-only form TrfExport itself writes for a birth_year-only player —
  # see Pairing.player_birth_date/1). A genuinely malformed date (bad month/
  # day) falls back to nil/nil rather than raising.
  defp birth_from_iso(v) when v in [nil, ""], do: {nil, nil}

  defp birth_from_iso(iso) do
    case String.split(iso, "-") do
      [y, "00", "00"] -> {nil, parse_year(y)}
      [y, m, d] -> full_date(y, m, d)
      _ -> {nil, nil}
    end
  end

  defp parse_year(y) do
    case Integer.parse(y) do
      {year, ""} -> year
      _ -> nil
    end
  end

  defp full_date(y, m, d) do
    with {year, ""} <- Integer.parse(y),
         {month, ""} <- Integer.parse(m),
         {day, ""} <- Integer.parse(d),
         {:ok, date} <- Date.new(year, month, day) do
      {date, year}
    else
      _ -> {nil, parse_year(y)}
    end
  end

  ## ---------- rounds, pairings & byes ----------

  defp create_rounds(tournament, trf_players, players_by_rank) do
    sorted = Enum.sort_by(trf_players, & &1.rank)
    max_round = rounds_from_data(trf_players)

    for round_number <- 1..max_round//1 do
      entries =
        for p <- sorted,
            game = Enum.at(p.games, round_number - 1),
            game != nil,
            game.result not in [nil, ""],
            do: {p, game}

      if entries != [] do
        insert_round(tournament, round_number, entries, players_by_rank)
      end
    end

    :ok
  end

  defp insert_round(tournament, round_number, entries, players_by_rank) do
    {pairings, byes} = build_round(entries)

    status = if Enum.any?(pairings, &(&1.result == "")), do: "playing", else: "finished"

    round =
      Repo.insert!(%Round{tournament_id: tournament.id, number: round_number, status: status})

    Enum.each(pairings, fn p ->
      Repo.insert!(%Pairing{
        round_id: round.id,
        board: p.board,
        white_player_id: Map.fetch!(players_by_rank, p.white_rank).id,
        black_player_id: p.black_rank && Map.fetch!(players_by_rank, p.black_rank).id,
        result: p.result
      })
    end)

    if byes != [] do
      rows =
        Enum.map(byes, fn b ->
          %{
            tournament_id: tournament.id,
            player_id: Map.fetch!(players_by_rank, b.rank).id,
            round: round_number,
            type: b.type
          }
        end)

      Repo.insert_all("byes", rows)
    end

    PairingsEngine.Tournaments.freeze_round_display_boards!(round.id)
  end

  # Walks each player's round entry (in starting-rank order) and, for a
  # playing code, tries to resolve the opponent's own entry for the same
  # round and pair the two into one game. `PairingsEngine.Trf.parse/1`
  # already validated that any *mutually referencing* pair is legal (see
  # `Trf.validate_games!/1`) — this only needs to check the reference is
  # mutual at all before trusting it. A dangling/unresolvable playing code,
  # or a genuine TRF bye code (H/F/U/Z), falls through to `single_sided/2`.
  defp build_round(entries) do
    by_rank = Map.new(entries, fn {p, g} -> {p.rank, {p, g}} end)

    {_visited, pairings, byes} =
      Enum.reduce(entries, {MapSet.new(), [], []}, fn {p, g}, {visited, pairings, byes} ->
        if MapSet.member?(visited, p.rank) do
          {visited, pairings, byes}
        else
          case mutual_opponent(p, g, by_rank) do
            {opp, opp_g} ->
              pairing = pair_game(p, g, opp, opp_g)
              visited = visited |> MapSet.put(p.rank) |> MapSet.put(opp.rank)
              {visited, [pairing | pairings], byes}

            nil ->
              visited = MapSet.put(visited, p.rank)

              case single_sided(p, g) do
                {:pairing, item} -> {visited, [item | pairings], byes}
                {:bye, item} -> {visited, pairings, [item | byes]}
              end
          end
        end
      end)

    {finalize_boards(Enum.reverse(pairings)), Enum.reverse(byes)}
  end

  @playing_codes ~w(1 = 0 + -)

  defp mutual_opponent(p, %{result: result, opponent_rank: opp_rank}, by_rank)
       when result in @playing_codes and not is_nil(opp_rank) do
    with {opp, opp_g} <- Map.get(by_rank, opp_rank),
         true <- opp.rank != p.rank,
         true <- opp_g.opponent_rank == p.rank,
         true <- opp_g.result not in [nil, ""] do
      {opp, opp_g}
    else
      _ -> nil
    end
  end

  defp mutual_opponent(_p, _g, _by_rank), do: nil

  defp pair_game(p, g, opp, opp_g) do
    {white_p, white_code, black_p, black_code} =
      cond do
        g.colour == "w" -> {p, g.result, opp, opp_g.result}
        g.colour == "b" -> {opp, opp_g.result, p, g.result}
        opp_g.colour == "w" -> {opp, opp_g.result, p, g.result}
        opp_g.colour == "b" -> {p, g.result, opp, opp_g.result}
        p.rank <= opp.rank -> {p, g.result, opp, opp_g.result}
        true -> {opp, opp_g.result, p, g.result}
      end

    %{
      board: nil,
      white_rank: white_p.rank,
      black_rank: black_p.rank,
      result: result_string(white_code, black_code)
    }
  end

  # Inverse of PairingsEngine.Pairing.trf_game/2's white-perspective mapping.
  defp result_string("1", _), do: "1-0"
  defp result_string("0", "1"), do: "0-1"
  defp result_string("0", "0"), do: "0-0"
  defp result_string("=", "="), do: "1/2-1/2"
  defp result_string("=", "0"), do: "1/2-0"
  defp result_string("0", "="), do: "0-1/2"
  defp result_string("+", _), do: "1-0FF"
  defp result_string("-", "+"), do: "0-1FF"
  defp result_string("-", "-"), do: "0-0FF"
  defp result_string(_, _), do: ""

  # A round entry that never resolves to a real, mutual opponent this round:
  # either a genuine TRF bye code, or a playing code whose opponent isn't
  # resolvable in this round's roster. OpenPairings models exactly one
  # "full points, no game" outcome (the pairing-allocated bye — a `pairings`
  # row with no black player) — both TRF's "U" (pairing-allocated) and "F"
  # (full-point bye) collapse into that same row, since there is no second
  # full-point-bye type to keep them apart (see docs/trf-import.md). "H"
  # (half-point bye) and "Z" (zero-point bye), and a dangling playing code
  # reinterpreted by the point value it represents (mirrors
  # `PairingsEngine.Pairing.bye_safe_result/2`, the same normalization in
  # the opposite direction), become `byes` table rows.
  defp single_sided(p, %{result: result}) do
    case result do
      code when code in ["U", "F", "1", "+"] ->
        {:pairing, %{board: nil, white_rank: p.rank, black_rank: nil, result: "bye"}}

      code when code in ["H", "="] ->
        {:bye, %{rank: p.rank, type: "requested-half"}}

      code when code in ["Z", "0", "-"] ->
        {:bye, %{rank: p.rank, type: "requested-zero"}}
    end
  end

  # None of the real pairings carry a board number (TRF16 has no such
  # field) — number them 1..N in discovery (starting-rank) order, byes
  # (no black player) numbered last, same convention SwarImport uses for
  # its own pairing-allocated byes.
  defp finalize_boards(pairings) do
    {byes, real} = Enum.split_with(pairings, &(&1.black_rank == nil))

    (real ++ byes)
    |> Enum.with_index(1)
    |> Enum.map(fn {p, i} -> %{p | board: i} end)
  end

  ## ---------- points cross-check ----------

  # Recomputes points from what actually landed in the database (via the
  # same code TrfExport itself uses) and flags any player whose TRF-file
  # points column disagrees — floating point roundtrips through 0.5-point
  # increments exactly, so > 0.01 is a real mismatch, not noise.
  defp points_warnings(tournament, trf_players, players_by_rank) do
    computed_by_rank =
      tournament
      |> PairingCtx.trf_player_rows(Map.values(players_by_rank))
      |> Map.new(&{&1.rank, &1.points})

    trf_players
    |> Enum.map(fn p ->
      computed = Map.get(computed_by_rank, p.rank, 0.0)
      declared = p.points || 0.0

      if abs(computed - declared) > 0.01 do
        %{player_name: String.trim(p.name || ""), trf_points: declared, computed_points: computed}
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp changeset_error_text(changeset) do
    Enum.map_join(changeset.errors, "; ", fn {field, {msg, _}} -> "#{field} #{msg}" end)
  end
end
