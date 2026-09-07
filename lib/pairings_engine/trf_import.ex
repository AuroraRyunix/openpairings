defmodule PairingsEngine.TrfImport do
  @moduledoc """
  Imports a FIDE TRF16 file (`Ainalrami.Trf.parse/1`) as a brand-new
  tournament - players, rounds, pairings, byes - owned by the importing
  user. One-step, single-transaction create, same shape as
  `PairingsEngine.Federations.BEL.SwarImport.import_file/2`: broadcast-suppressed writes
  inside the transaction, `Tournaments.refresh_status!/1` and the real
  broadcasts after commit.

  TRF16 has no board-number field and no explicit "which two rows are the
  same game" marker beyond each player's own per-round opponent reference -
  a game is reconstructed by pairing up two players' round columns when
  they mutually reference each other (mirrors `Ainalrami.Trf`'s own
  `validate_games!/2`, which already guarantees any *mutual* pair is
  legal). Board numbers are then assigned sequentially in starting-rank
  order, real games before byes. See `docs/trf-import.md`.

  TRF's own per-player points column (TRF16 columns 81-84) is a
  self-reported total that arbiter software sometimes leaves stale after a
  late correction - it is never trusted outright. After import,
  `PairingsEngine.Pairing.trf_player_rows/2` recomputes each player's
  points from what was actually written to the database (same formula
  `PairingsEngine.TrfExport` uses), and any player whose recomputed total
  disagrees with the TRF file's declared total is returned in `warnings`
  for the caller to show as a notice - the import itself always proceeds
  either way.
  """

  alias PairingsEngine.{Encoding, Repo, Tiebreaks, Tournaments}
  alias PairingsEngine.Tournaments.{ForbiddenPairing, Tournament, Player, Round, Pairing}
  alias PairingsEngine.Pairing, as: PairingCtx

  # The app's one TRF16 implementation. This module already read files with
  # it in effect - the app serialized with a local `PairingsEngine.Trf` and
  # handed the text to Ainalrami's parser on the pairing path - so the only
  # thing that changes here is that the reader and the writer are now
  # provably the same reader and writer.
  alias Ainalrami.Trf

  # The one TRF error type the app has, and it matters most here: this is
  # the rescue that decides whether a bad uploaded file becomes a flash
  # message or a crash. Naming the wrong module in a `rescue` is not a
  # compile error and not a failed match, it is a clause that never fires.
  alias Ainalrami.Trf.ValidationError

  @doc """
  Parses `content` (a TRF16 file's raw text) and imports it as a new
  tournament owned by `scope`'s user (`nil` creates it unowned, same as
  `SwarImport.import_file/2`).

  Returns `{:ok, %Tournament{}, warnings}` where `warnings` is a (possibly
  empty) list of either `%{kind: :points, player_name:, trf_points:,
  computed_points:}` - one per player whose recomputed points disagree with
  the TRF file's own points column (see the moduledoc) - or `%{kind: :note,
  text:}`, one per thing the file said that this app could not apply
  exactly. Returns `{:error, reason}` on a parse
  failure or an invalid file; never raises. `reason` is either a
  `Ainalrami.Trf.ValidationError` struct, a `{:parse_failed, message}`
  tuple, or a plain string - pass it to `error_message/1` for a single
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
  builds unpersisted `%Tournament{}`/`%Player{}` structs - same decoding
  (CP1252/BOM fallback), parsing and header/player field mapping
  `import_text/2` itself uses internally, but with NO `Repo` calls: nothing
  is written to the database, and the returned structs have no `id` (never
  needed - `PairingsEngine.Norms.Forms` only ever reads scalar fields off a
  tournament/player, never `id`).

  Unlike `import_text/2`, this never builds rounds/pairings/byes - TRF's
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
  # frequently Windows-1252 encoded rather than UTF-8 - an accented name
  # (e.g. "Boûtchon", "Gaëtan") then arrives as raw single-byte CP1252,
  # which is not valid UTF-8 on its own. Left untranslated, that byte
  # sequence gets stored as invalid UTF-8 straight through the database:
  # mojibake in the UI and in every re-export (TRF, norms xlsx, ...).
  #
  # Mirrors the same strip-BOM-before-detect + CP1252-fallback pattern the
  # KBSB rating-list parser uses, reusing the same
  # `PairingsEngine.Encoding.cp1252_decode/1` helper either fallback needs.
  # Order matters: stripping the BOM first, on the
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
    if String.valid?(binary), do: binary, else: Encoding.cp1252_decode(binary)
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
  # over to the second - an orphan player nobody's games reference. Caught
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
      paired = paired_rounds_from_data(data.players)
      create_rounds(tournament, data.players, players_by_rank, paired)

      # Everything the file says ABOUT the tournament rather than about a
      # game. Each of these was parsed and then dropped on the floor until
      # 0.48.0, which is the quiet kind of wrong: a re-imported tournament
      # looked complete and was configured differently from the one that
      # left.
      notes =
        import_forbidden_pairings(tournament, data, players_by_rank) ++
          import_future_byes(tournament, data, players_by_rank, paired) ++
          import_extra_points(tournament, data, players_by_rank)

      {tournament, acceleration_notes} = import_acceleration(tournament, data, players_by_rank)

      warnings =
        points_warnings(tournament, data.players, players_by_rank) ++
          notes ++ acceleration_notes

      {:ok, tournament, warnings}
    end
  end

  defp note(text), do: %{kind: :note, text: text}

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
  # (pure, no Repo) - the one place TRF's header fields map onto
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
      # The file's own `142`/`XXR` when it has one - the tournament's
      # length, which is not the same as how much of it has been played and
      # is what the final-round colour rule turns on. Only the games could
      # say before, so a 9-round event imported three rounds in became a
      # 3-round event.
      rounds_count: max(t[:number_of_rounds] || 0, max(rounds_from_data(data.players), 1)),
      round_dates: t[:round_dates] || [],
      officials: deputy_officials(t[:deputy_arbiters] || [], chief_fide_id)
    }
    |> Map.merge(scoring_attrs(t[:point_system]))
    |> Map.merge(system_attrs(t[:type_code]))
    |> Map.merge(tiebreak_attrs(t[:tie_breaks]))
  end

  defp rounds_from_data(players) do
    from_games = players |> Enum.map(&length(&1.games)) |> Enum.max(fn -> 0 end)
    from_games
  end

  # The last round the file actually PAIRED, which is not the length of the
  # longest game list. A trailing column holding nothing but an
  # arbiter-granted bye - a TRF26 `240` for the round about to be paired,
  # which `Ainalrami.Trf.parse/1` folds into the games so that an engine
  # leaves that player out - describes a round nobody has paired yet.
  # Creating a Round row for it would make the app count an unpaired round
  # as played; those byes go to the `byes` table instead
  # (`import_future_byes/4`).
  defp paired_rounds_from_data(players) do
    players
    |> Enum.map(fn p ->
      p.games
      |> Enum.with_index(1)
      |> Enum.filter(fn {g, _round} -> Trf.participated_in_pairing?(g) end)
      |> Enum.map(fn {_g, round} -> round end)
      |> Enum.max(fn -> 0 end)
    end)
    |> Enum.max(fn -> 0 end)
  end

  # TRF26's `162` (and the engines' `BB*` lines) say what a result is worth,
  # and a score decides which bracket a player is paired in - so a 3-1-0
  # file imported at 1 / half / 0 does not merely report different totals,
  # it would pair a different tournament from the next round on. The inverse
  # of `Tournament.engine_point_system/1`, field for field.
  #
  # `zero_point_bye` lands on `abs_value` only when it differs from the
  # loss: nil there means "score an absence at `points_loss`", which is
  # exactly what the file is saying when the two agree, and writing the
  # value anyway would turn a default into a setting.
  defp scoring_attrs(nil), do: %{}

  defp scoring_attrs(system) do
    attrs =
      %{
        points_win: system[:win],
        points_draw: system[:draw],
        points_loss: system[:loss],
        bye_value: system[:pairing_allocated_bye]
      }
      |> Enum.reject(fn {_field, value} -> is_nil(value) end)
      |> Map.new()

    zero = system[:zero_point_bye]
    loss = system[:loss] || Trf.default_point_system().loss

    if is_nil(zero) or zero == loss, do: attrs, else: Map.put(attrs, :abs_value, zero)
  end

  # TRF26's `192`, the encoded type of tournament (FIDE's ETT26 table) -
  # the inverse of `PairingsEngine.TrfExport`'s own mapping. It is the one
  # field that says which EDITION of the Dutch rules paired the boards, and
  # the app models that as the choice of engine: JaVaFo implements the
  # system as it stood before 1 February 2026, Ainalrami the one in force
  # since. A code this app has no system for (Dubov, Burstein, a CUSTOM_*,
  # a team system) leaves the defaults alone rather than guessing; the
  # settings the file could not fill are the arbiter's to set, and
  # `infer_type/1` has already read the plain-language `092` line.
  defp system_attrs(nil), do: %{}

  defp system_attrs(code) do
    baku? = String.ends_with?(code, "_BAKU")
    base = String.replace_suffix(code, "_BAKU", "")

    system =
      cond do
        base == "FIDE_DUTCH_2017" ->
          %{pairing_system: "swiss", pairing_engine: "javafo"}

        base in ~w(FIDE_DUTCH FIDE_DUTCH_2026) ->
          %{pairing_system: "swiss", pairing_engine: "ainalrami"}

        base in ~w(FIDE_DOUBLEROUNDROBIN BERGER_DOUBLEROUNDROBIN) ->
          %{pairing_system: "round_robin", rr_cycles: 2}

        String.contains?(base, "ROUNDROBIN") ->
          %{pairing_system: "round_robin", rr_cycles: berger_cycles(base)}

        true ->
          %{}
      end

    if baku?, do: Map.put(system, :acceleration, "baku"), else: system
  end

  # `BERGER_ROUNDROBIN_Gn` - all games repeated n times. This app offers one
  # or two cycles, so anything past two is clamped and the arbiter is not
  # told a number the app cannot honour.
  defp berger_cycles(base) do
    case Regex.run(~r/_G(\d+)$/, base) do
      [_, n] -> min(String.to_integer(n), 2)
      nil -> 1
    end
  end

  # TRF26's `202`/`212`. The codes are FIDE's own C.07 vocabulary, which is
  # also this app's (`PairingsEngine.Tiebreaks`), so the ones it can compute
  # are taken as they are and the rest are dropped - a tie-break this
  # installation does not implement, listed as though it were configured,
  # would be a standings column that silently never fills.
  defp tiebreak_attrs(nil), do: %{}

  defp tiebreak_attrs(codes) do
    known = MapSet.new(Tiebreaks.catalogue(), & &1.code)
    kept = Enum.filter(codes, &MapSet.member?(known, &1))

    if kept == [], do: %{}, else: %{tiebreaks: kept}
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
  # Ainalrami.Trf's @type_labels) - reverse-mapped by substring rather
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
  # year-only form TrfExport itself writes for a birth_year-only player -
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

  defp create_rounds(tournament, trf_players, players_by_rank, max_round) do
    sorted = Enum.sort_by(trf_players, & &1.rank)

    all_entries =
      for round_number <- 1..max_round//1, into: %{} do
        entries =
          for p <- sorted,
              game = Enum.at(p.games, round_number - 1),
              game != nil,
              game.result not in [nil, ""],
              do: {p, game}

        {round_number, entries}
      end

    # An INTERIOR round with no results still gets a Round row. Skipping it
    # left a hole - rows numbered 1 and 3 with no 2 - and several readers
    # index rounds positionally rather than by number:
    # `Pairing.games_per_player/3` maps over the number-ordered rows and
    # `Trf.place_games/2` writes them back with `Enum.with_index(1)`, so
    # round 3's game was emitted in round 2's columns while the round dates
    # still came from rounds 1 and 2.
    #
    # A blank interior round is legal input (see `Trf.parse_games/1`'s
    # Annexure-B note), so this is a real file shape rather than a
    # hypothetical. Trailing empty rounds are still skipped: those are
    # placeholder columns for rounds that have not happened, and inventing
    # rows for them would claim the tournament is further along than it is.
    last_with_entries =
      all_entries
      |> Enum.filter(fn {_n, entries} -> entries != [] end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.max(fn -> 0 end)

    for round_number <- 1..max_round//1, round_number <= last_with_entries do
      insert_round(
        tournament,
        round_number,
        Map.fetch!(all_entries, round_number),
        players_by_rank
      )
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
  # round and pair the two into one game. `Ainalrami.Trf.parse/1`
  # already validated that any *mutually referencing* pair is legal (see
  # `Trf.validate_games!/2`) - this only needs to check the reference is
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

  # `Trf.playing_codes/0`, not a private copy. There WAS a private copy here
  # reading `~w(1 = 0 + -)`, written before TRF16's unrated twins `W`/`D`/`L`
  # were supported, and never updated when they were. Since this guard is
  # what decides whether a round entry is a GAME, an unrated game stopped
  # being one: it fell through to `single_sided/2` and was reinterpreted as a
  # bye, losing the opponent entirely.
  #
  # The proof it was a drift rather than a decision is thirty lines below -
  # `result_string("W", _)`, `result_string("L", "W")` and
  # `result_string("D", "D")` were unreachable, because nothing could ever
  # reach the call site. So this app's own TRF export did not round-trip
  # through its own importer.
  @playing_codes Trf.playing_codes()

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
  defp result_string("W", _), do: "1-0U"
  defp result_string("L", "W"), do: "0-1U"
  defp result_string("D", "D"), do: "1/2-1/2U"
  defp result_string("+", _), do: "1-0FF"
  defp result_string("-", "+"), do: "0-1FF"
  defp result_string("-", "-"), do: "0-0FF"
  defp result_string(_, _), do: ""

  # A round entry that never resolves to a real, mutual opponent this round:
  # either a genuine TRF bye code, or a playing code whose opponent isn't
  # resolvable in this round's roster. OpenPairings models exactly one
  # "full points, no game" outcome (the pairing-allocated bye - a `pairings`
  # row with no black player) - both TRF's "U" (pairing-allocated) and "F"
  # (full-point bye) collapse into that same row, since there is no second
  # full-point-bye type to keep them apart (see docs/trf-import.md). "H"
  # (half-point bye) and "Z" (zero-point bye), and a dangling playing code
  # reinterpreted by the point value it represents (mirrors
  # `PairingsEngine.Pairing.bye_safe_result/2`, the same normalization in
  # the opposite direction), become `byes` table rows.
  #
  # The three lists below are the SECOND private copy of the played-code
  # vocabulary in this module - `@playing_codes` above was the first, and it
  # is the one that drifted. This one has not: it is complete against
  # v0.14.0's `Trf.playing_codes/0` and `Trf.bye_codes/0` today. That is
  # luck, not design, and the same luck the first copy had until `W`/`D`/`L`
  # were added upstream.
  #
  # Pointing it at `Trf.playing_codes/0` directly is not possible, and that
  # is worth writing down so the next reader does not try: this call site is
  # not asking "is this a playing code" - it is asking WHAT POINT VALUE a
  # code stands for, a three-way split that runs ACROSS both engine lists
  # ("1" and "F" are both full-point; "=" and "H" are both half). Neither
  # `playing_codes/0` nor `bye_codes/0` expresses that partition, and the
  # engine publishes no function that does. `Trf.points_for/2` comes close
  # but keys on a configurable point system, so a file with its own
  # `BBU`/`BBW` values would silently re-bucket - a behaviour change, not a
  # de-duplication.
  #
  # What the engine lists CAN do is police the domain, which is the half
  # that actually broke last time. Their union is exactly the set of codes
  # `Trf.validate_game!/5` lets through, so it is exactly the set this
  # function must handle; the check below fails the BUILD if the two ever
  # disagree, rather than waiting for a FunctionClauseError mid-import on an
  # arbiter's file.
  @single_sided_full ~w(U F 1 + W)
  @single_sided_half ~w(H = D)
  @single_sided_zero ~w(Z 0 - L)

  @single_sided_handled Enum.sort(@single_sided_full ++ @single_sided_half ++ @single_sided_zero)
  @single_sided_domain Enum.sort(Trf.playing_codes() ++ Trf.bye_codes())

  if @single_sided_handled != @single_sided_domain do
    raise """
    PairingsEngine.TrfImport.single_sided/2 no longer covers Ainalrami.Trf's \
    result vocabulary.

      handled here: #{inspect(@single_sided_handled)}
      engine says:  #{inspect(@single_sided_domain)}
      missing:      #{inspect(@single_sided_domain -- @single_sided_handled)}
      unknown:      #{inspect(@single_sided_handled -- @single_sided_domain)}

    Every code the engine accepts must land in exactly one of the three \
    point-value buckets above (full point, half point, zero). A code missing \
    from all three raises FunctionClauseError on a real TRF file instead.
    """
  end

  defp single_sided(p, %{result: result}) do
    case result do
      code when code in @single_sided_full ->
        {:pairing, %{board: nil, white_rank: p.rank, black_rank: nil, result: "bye"}}

      code when code in @single_sided_half ->
        {:bye, %{rank: p.rank, type: "requested-half"}}

      code when code in @single_sided_zero ->
        {:bye, %{rank: p.rank, type: "requested-zero"}}
    end
  end

  # None of the real pairings carry a board number (TRF16 has no such
  # field) - number them 1..N in discovery (starting-rank) order, byes
  # (no black player) numbered last, same convention SwarImport uses for
  # its own pairing-allocated byes.
  defp finalize_boards(pairings) do
    {byes, real} = Enum.split_with(pairings, &(&1.black_rank == nil))

    (real ++ byes)
    |> Enum.with_index(1)
    |> Enum.map(fn {p, i} -> %{p | board: i} end)
  end

  ## ---------- what the file says about the tournament ----------

  # `260` (and `XXP`) - the pairs the arbiter ruled out. Parsed since the
  # engine learned to read them and dropped here until 0.48.0, so a
  # re-imported tournament forgot who must never meet and would happily
  # pair them in its next round.
  #
  # A group forbids every pair WITHIN it, which is the reference's own
  # reading. Order is normalised to (smaller id, larger id) because that is
  # what `ForbiddenPairing.changeset/2` would have done and what the unique
  # index requires; these go in through `insert_all` rather than the context
  # function, which would broadcast per row inside the import transaction.
  defp import_forbidden_pairings(tournament, data, players_by_rank) do
    groups = data.tournament[:forbidden_pairs] || []
    rounds = tournament.rounds_count

    rows =
      for group <- groups,
          {ranks, _first, _last} = normalise_group(group),
          [a, b] <- pairs_within(ranks),
          player_a = players_by_rank[a],
          player_b = players_by_rank[b],
          not is_nil(player_a) and not is_nil(player_b) do
        {low, high} = Enum.min_max([player_a.id, player_b.id])

        %{tournament_id: tournament.id, player_a_id: low, player_b_id: high, soft: false}
      end
      |> Enum.uniq_by(&{&1.player_a_id, &1.player_b_id})

    if rows != [], do: Repo.insert_all(ForbiddenPairing, rows)

    # A `260` may name a range of rounds ("no clubmates in the first two"),
    # and this app's forbidden pairings hold for the whole event. Widening
    # is the safe direction - the engine will never seat a pair the arbiter
    # separated - but it is a change to what the file said, so it is said
    # out loud rather than absorbed.
    limited =
      Enum.count(groups, fn group ->
        {_ranks, first, last} = normalise_group(group)
        first > 1 or last < rounds
      end)

    if limited == 0 do
      []
    else
      [
        note(
          "#{limited} prohibited-pairing rule#{if limited == 1, do: "", else: "s"} in the file " <>
            "applied only to some rounds; imported as applying to every round."
        )
      ]
    end
  end

  defp normalise_group({ranks, first, last}), do: {ranks, first, last}
  defp normalise_group(ranks) when is_list(ranks), do: {ranks, 1, :infinity}

  defp pairs_within(ranks) do
    indexed = Enum.with_index(ranks)
    for {a, i} <- indexed, {b, j} <- indexed, i < j, do: Enum.sort([a, b])
  end

  # `240` records naming a round nobody has paired yet - the arbiter's
  # "this player is not playing that round", which is a `byes` row and not
  # a Round. A round already in the player rows came in through
  # `create_rounds/4` and is skipped here.
  defp import_future_byes(tournament, data, players_by_rank, paired) do
    records = for r <- data.tournament[:byes] || [], r.round > paired, do: r

    {rows, unsupported} =
      Enum.reduce(records, {[], 0}, fn record, {rows, unsupported} ->
        case future_bye_type(record.type) do
          nil ->
            {rows, unsupported + length(record.ranks)}

          type ->
            new =
              for rank <- record.ranks, player = players_by_rank[rank], not is_nil(player) do
                %{
                  tournament_id: tournament.id,
                  player_id: player.id,
                  round: record.round,
                  type: type
                }
              end

            {rows ++ new, unsupported}
        end
      end)

    rows = Enum.uniq_by(rows, &{&1.player_id, &1.round})
    if rows != [], do: Repo.insert_all("byes", rows)

    # A full-point bye granted in advance has no row this app can write:
    # its `byes` table records the half-point and zero-point kinds an
    # arbiter grants, and a full point is a pairing's own allocation.
    if unsupported == 0 do
      []
    else
      [
        note(
          "#{unsupported} full-point bye#{if unsupported == 1, do: "", else: "s"} granted for a " <>
            "round that is not yet paired could not be imported - grant them once the round exists."
        )
      ]
    end
  end

  defp future_bye_type("H"), do: "requested-half"
  defp future_bye_type("Z"), do: "requested-zero"
  defp future_bye_type(_full_point), do: nil

  # An untyped `299` - points an arbiter assigned outside the scoring
  # system, which the `001` column does not carry. This app calls them a
  # player's extra points, and counting them in the standings is a per
  # tournament opt-in: a file that bothered to record them meant them to
  # count, so the flag goes on with them.
  defp import_extra_points(tournament, data, players_by_rank) do
    records = data.tournament[:free_points] || []

    by_rank =
      Enum.reduce(records, %{}, fn record, acc ->
        Enum.reduce(record.ranks, acc, fn rank, acc ->
          Map.update(acc, rank, record.points, &(&1 + record.points))
        end)
      end)

    for {rank, points} <- by_rank, player = players_by_rank[rank], not is_nil(player) do
      player |> Ecto.Changeset.change(extra_points: points) |> Repo.update!()
    end

    everybody = Enum.filter(records, &(&1.ranks == []))

    if by_rank != %{} do
      Tournaments.update_tournament(tournament, %{"count_extra_points" => true})
    end

    if everybody == [] do
      []
    else
      [
        note(
          "The file assigns points to every player at once, which this app cannot express " <>
            "per player; those were not imported."
        )
      ]
    end
  end

  # `250`/`XXA` virtual points are DATA - the numbers each player was
  # actually given - where `192`'s `_BAKU` suffix is only a declaration.
  # This app implements exactly one acceleration method (FIDE C.04.7 Baku),
  # so the honest test is whether that method reproduces the file's own
  # numbers for this roster and round count. If it does, the tournament is
  # accelerated; if it does not, the file used something else and the
  # import says so rather than mislabelling it Baku and pairing the rest of
  # the event differently from the way it started.
  defp import_acceleration(tournament, data, players_by_rank) do
    given =
      data.players
      |> Enum.reject(&(&1[:accelerations] in [nil, []]))
      |> Map.new(&{&1.rank, trim_trailing_zeros(&1[:accelerations])})
      |> Enum.reject(fn {_rank, points} -> points == [] end)
      |> Map.new()

    cond do
      given == %{} ->
        {tournament, []}

      baku_reproduces?(tournament, players_by_rank, given) ->
        case Tournaments.update_tournament(tournament, %{"acceleration" => "baku"}) do
          {:ok, updated} -> {updated, []}
          {:error, _changeset} -> {tournament, []}
        end

      true ->
        {tournament,
         [
           note(
             "The file gives some players virtual points that FIDE's Baku method does not " <>
               "produce for this field, so the tournament was imported without acceleration."
           )
         ]}
    end
  end

  defp baku_reproduces?(tournament, players_by_rank, given) do
    players = Map.values(players_by_rank)
    rounds = given |> Map.values() |> Enum.map(&length/1) |> Enum.max(fn -> 0 end)
    id_to_rank = Map.new(players_by_rank, fn {rank, player} -> {player.id, rank} end)

    %{tournament | acceleration: "baku"}
    |> PairingCtx.accelerations(players, rounds)
    |> Enum.reduce(%{}, fn {id, points}, acc ->
      Map.put(acc, Map.fetch!(id_to_rank, id), trim_trailing_zeros(points))
    end)
    |> Enum.reject(fn {_rank, points} -> points == [] end)
    |> Map.new()
    |> Kernel.==(given)
  end

  # A player's virtual points are one value per round from round 1, and a
  # trailing run of zeroes says nothing - the accelerated span simply ended.
  # Comparing with them in place would call two identical accelerations
  # different because one file wrote the zeroes and the other stopped.
  defp trim_trailing_zeros(points) do
    points |> Enum.reverse() |> Enum.drop_while(&(&1 == 0 or &1 == 0.0)) |> Enum.reverse()
  end

  ## ---------- points cross-check ----------

  # Recomputes points from what actually landed in the database (via the
  # same code TrfExport itself uses) and flags any player whose TRF-file
  # points column disagrees - floating point roundtrips through 0.5-point
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
        %{
          kind: :points,
          player_name: String.trim(p.name || ""),
          trf_points: declared,
          computed_points: computed
        }
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp changeset_error_text(changeset) do
    Enum.map_join(changeset.errors, "; ", fn {field, {msg, _}} -> "#{field} #{msg}" end)
  end
end
