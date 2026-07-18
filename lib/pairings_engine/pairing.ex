defmodule PairingsEngine.Pairing do
  @moduledoc """
  Round lifecycle: builds the TRF input for JaVaFo, runs the engine, and
  creates the round with its pairings.

  JaVaFo (© Roberto Ricca, the FIDE-endorsed Dutch-system engine) is invoked
  as `java -jar javafo.jar input.trf -p output.txt`; the output lists one
  "white black" pair of TRF starting ranks per line, 0 meaning the
  pairing-allocated bye.
  """

  import Ecto.Query
  require Logger
  alias PairingsEngine.{Repo, Trf, Tournaments, Exclusions}
  alias PairingsEngine.Tournaments.{Player, Round, Pairing, Tournament}

  def javafo_jar do
    Path.join(:code.priv_dir(:pairings_engine), "javafo/javafo.jar")
  end

  @doc """
  Pairs the next round. Dispatches on `tournament.pairing_system`:

    * `"swiss"` (default) — the JaVaFo/Dutch path below, unchanged.
    * `"round_robin"` — delegates to `PairingsEngine.RoundRobin.pair_next_round/1`.
    * `"keizer"` — delegates to `PairingsEngine.Keizer.pair_next_round/1`.

  Returns `{:ok, round}` or `{:error, reason}`. This is the single public
  entry point the UI calls (see `PairingsEngineWeb.PairingsLive`'s "pair"
  event) — it never crashes on an unimplemented pairing system, it just
  returns a plain-string error the caller already renders as-is.
  """
  def pair_next_round(%Tournament{pairing_system: "round_robin"} = tournament) do
    dispatch_stub(tournament, PairingsEngine.RoundRobin)
  end

  def pair_next_round(%Tournament{pairing_system: "keizer"} = tournament) do
    dispatch_stub(tournament, PairingsEngine.Keizer)
  end

  def pair_next_round(%Tournament{} = tournament) do
    paired = paired_rounds_count(tournament.id)
    next_number = paired + 1
    active = active_players(tournament.id)
    eligible = eligible_players(tournament.id, next_number)

    result =
      cond do
        next_number > max_pairable_round(tournament) ->
          {:error, "All #{tournament.rounds_count} rounds have already been paired"}

        length(eligible) < 2 ->
          {:error, "At least two active players are needed"}

        not round_complete?(tournament.id, paired) ->
          {:error, "Round #{paired} still has missing results"}

        true ->
          tournament
          |> ensure_pairing_numbers(active)
          |> do_pair(next_number)
      end

    case result do
      {:ok, _round} ->
        Tournaments.broadcast_tournament_change(tournament.id, :rounds)
        Tournaments.refresh_status!(tournament.id)

      _ ->
        :ok
    end

    result
  end

  # `swiss_match_format` inserts BOTH legs of a match (rounds `next_number`
  # and `next_number + 1`) in one `do_pair/2` call — see that function —
  # so the pairing boundary must leave room for both legs of the *next*
  # match, not just the next single round: with 2 rounds left, pairing
  # must still be allowed (it fills the final match); with 1 round left,
  # it must not (there's no room for a second leg). Hence `rounds_count -
  # 1` rather than `rounds_count`. As a consequence, `paired_rounds_count/1`
  # always lands on an even number after a successful match-format pairing
  # (each call adds exactly 2 rounds), so `next_number = paired + 1` is
  # always odd the next time `pair_next_round/1` runs — every match-format
  # pairing run always starts a fresh match at its first leg, never lands
  # mid-match.
  defp max_pairable_round(%Tournament{swiss_match_format: true, rounds_count: n}), do: n - 1
  defp max_pairable_round(%Tournament{rounds_count: n}), do: n

  # Calls `module.pair_next_round(tournament)` (module dispatched at runtime
  # so the compiler doesn't over-narrow the result type to today's single
  # `{:error, :not_implemented}` stub return value — once RoundRobin/Keizer
  # are actually implemented this same function keeps working unchanged)
  # and turns a not-implemented stub result into a friendly, user-facing
  # string. PairingsLive's "pair" handler just does `to_string(reason)` on
  # any non-changeset error, so a plain string here is what ends up on
  # screen — no atom formatting, no crash.
  #
  # On success, refreshes the tournament's derived status the same way the
  # Swiss path below does — RoundRobin/Keizer pair a round and broadcast
  # `:rounds` themselves, but neither calls `Tournaments.refresh_status!/1`,
  # so without this a round-robin/Keizer tournament would stay stuck on
  # "setup" after its first round is paired. Centralized here (rather than
  # in each engine module) so it's a single call site for both.
  defp dispatch_stub(tournament, module) do
    case module.pair_next_round(tournament) do
      {:error, :not_implemented} ->
        {:error, "This pairing system is not available yet"}

      {:ok, _round} = result ->
        Tournaments.refresh_status!(tournament.id)
        result

      other ->
        other
    end
  end

  @doc """
  Deletes a paired round (only the latest one, to keep history sane).

  Under `tournament.swiss_match_format`, a single `do_pair/2` call inserts
  BOTH legs of a match (rounds N and N+1 — see `create_mirrored_leg/4` and
  the comment above `max_pairable_round/1`, which documents that
  `paired_rounds_count/1` always lands on an even number after a
  match-format pairing run). Deleting only one leg would break that
  invariant — orphaning leg 1, or stranding the tournament with a
  `next_number` `max_pairable_round/1` can never reach again — so both legs
  of the match are deleted together here.

  Also deletes the round's `byes` rows: the `byes` table has no `round_id`
  foreign key (see the migration), so a plain `Round` delete would otherwise
  leave orphaned bye rows behind that collide (`UNIQUE(player_id, round)`)
  the next time this round number is paired.
  """
  def delete_round(tournament_id, number) do
    if number == paired_rounds_count(tournament_id) do
      match_format? =
        Repo.one(from t in Tournament, where: t.id == ^tournament_id, select: t.swiss_match_format)

      numbers = if match_format? and number > 1, do: [number - 1, number], else: [number]

      Repo.delete_all(
        from r in Round, where: r.tournament_id == ^tournament_id and r.number in ^numbers
      )

      Repo.delete_all(
        from b in "byes",
          where: b.tournament_id == ^tournament_id and b.round in ^numbers
      )

      Tournaments.broadcast_tournament_change(tournament_id, :rounds)
      Tournaments.refresh_status!(tournament_id)
      :ok
    else
      {:error, "Only the latest round can be unpaired"}
    end
  end

  def paired_rounds_count(tournament_id) do
    Repo.aggregate(from(r in Round, where: r.tournament_id == ^tournament_id), :count)
  end

  def round_complete?(_tournament_id, 0), do: true

  def round_complete?(tournament_id, number) do
    not Repo.exists?(
      from p in Pairing,
        join: r in Round,
        on: p.round_id == r.id,
        where: r.tournament_id == ^tournament_id and r.number == ^number and p.result == ""
    )
  end

  ## ---------- pairing numbers ----------

  @doc """
  Assigns `pairing_number` to every player in `players` that doesn't have
  one yet — highest rating first, name ascending as the tie-break (FIDE
  C.04.2.B), continuing from the current max existing number — then leaves
  them frozen forever (never reassigned once set). Returns `tournament`
  unchanged, so it composes in a pipe the same way the Swiss path above
  uses it.

  Exposed (not private) so `PairingsEngine.Keizer` can freeze pairing
  numbers at its own first pairing exactly the same way, rather than
  duplicating this logic — see that module's `do_pair/4`.
  """
  def ensure_pairing_numbers(tournament, players) do
    if Enum.any?(players, &is_nil(&1.pairing_number)) do
      max_existing =
        players |> Enum.map(&(&1.pairing_number || 0)) |> Enum.max(fn -> 0 end)

      players
      |> Enum.filter(&is_nil(&1.pairing_number))
      |> Enum.sort_by(&{-Player.rating(&1), &1.name})
      |> Enum.with_index(max_existing + 1)
      |> Enum.each(fn {player, number} ->
        {:ok, _} = Tournaments.update_player(player, %{pairing_number: number})
      end)
    end

    tournament
  end

  ## ---------- the pairing run ----------

  # Runs JaVaFo once for `next_number` and inserts its result as a `Round`.
  # When `tournament.swiss_match_format` is set, this is leg 1 of a match:
  # `create_round/5` also inserts leg 2 (`next_number + 1`) in the same
  # transaction, an exact colour-reversed mirror of leg 1 — no second
  # JaVaFo call, no new TRF file (see `create_mirrored_leg/4`). Round-
  # specific absentees for `next_number` (`round_absentees` below) are
  # threaded through so leg 2 can mirror their "requested-zero" bye rows
  # too, rather than independently re-evaluating `absent_for_round?/2` for
  # `next_number + 1` — a deliberate scope limitation, see
  # `create_mirrored_leg/4`.
  defp do_pair(tournament, next_number) do
    active = active_players(tournament.id)

    {players, round_absentees} =
      Enum.split_with(active, &(not absent_for_round?(&1, next_number)))

    # Players requesting an absence for this specific round get a
    # "requested-zero" bye row instead of being sent to JaVaFo, so the
    # pairing engine never considers them for this round. Computed once over
    # the whole active/round_absentees split, before any category
    # partitioning happens below — unaffected by `pair_by_category`.
    #
    # The actual `insert_round_absentee_byes/3` call happens later, inside
    # `create_round/5`'s or `insert_category_round/3`'s `Repo.transaction`
    # (after JaVaFo has already succeeded) rather than here — see those
    # functions. Running it here, before JaVaFo is even invoked, would
    # permanently commit these bye rows even if JaVaFo then failed, bricking
    # the round on retry (UNIQUE(player_id, round) violation).
    if tournament.pair_by_category do
      do_pair_by_category(tournament, players, next_number, round_absentees)
    else
      do_pair_single(tournament, players, next_number, round_absentees)
    end
  end

  # `players` here is `next_number`'s round-specific ELIGIBLE subset of
  # `active_players/1` (see `do_pair/2`'s `Enum.split_with/2`), not the whole
  # frozen `pairing_number` pool — `active_players/1` covers permanent
  # absentees/forfeits/inactive status, but a player sitting out only THIS
  # round (`absent_rounds`) still holds their global `pairing_number` and
  # still appears in `active_players/1`, just not here.
  #
  # We still need a LOCAL contiguous 1..M rank map: sending JaVaFo a TRF
  # whose starting ranks aren't contiguous 1..N crashes it with a bare
  # NullPointerException — confirmed against the real jar (see
  # `test/pairings_engine/swar_import_test.exs`'s "pairing a new round after
  # import doesn't crash when a historical opponent is now excluded").
  #
  # Crucially, that local map is now built over the FULL frozen roster
  # (`full_roster_players/1` — every player who ever held a `pairing_number`,
  # regardless of current active/absent/forfeit/withdrawn status), NOT just
  # `players`. If it were scoped to `players`, any historical opponent now
  # outside that subset — a withdrawn/forfeited player, a round-specific
  # absentee — would miss the rank map, and
  # `remap_trf_rows_to_local_ranks/2` would rewrite that genuinely-played
  # game into a synthetic bye code, silently destroying its colour history
  # and letting JaVaFo violate FIDE colour alternation. Scoping the map to
  # the full roster guarantees every possible historical opponent resolves
  # to a real rank with a real TRF row.
  #
  # A row is sent for every full-roster player (a rank column with no
  # matching row is meaningless to JaVaFo). Players who aren't actually
  # candidates for THIS round — everyone not in `players` — are still marked
  # with an explicit `0000 - Z` line via `javafo_input/4`'s `eligible_ids`
  # (`mark_ineligible_for_round/2`), the verified-safe JaVaFo-native way to
  # keep a player's real history while excluding them from pairing this run.
  #
  # JaVaFo's output pairs (local ranks) are translated back to real players
  # via the inverse map in `create_round/5`. Board numbering (JaVaFo's output
  # *order*, not its rank values) is completely unaffected by this.
  defp do_pair_single(tournament, players, next_number, round_absentees) do
    full_roster = full_roster_players(tournament.id)
    eligible_ids = MapSet.new(players, & &1.id)

    local_rank_by_player_id =
      full_roster |> Enum.with_index(1) |> Map.new(fn {p, i} -> {p.id, i} end)

    by_id = Map.new(full_roster, &{&1.id, &1})

    player_by_local_rank =
      Map.new(local_rank_by_player_id, fn {id, rank} -> {rank, Map.fetch!(by_id, id)} end)

    trf = javafo_input(tournament, full_roster, local_rank_by_player_id, eligible_ids)

    dir = Path.join(System.tmp_dir!(), "pairingsengine")
    File.mkdir_p!(dir)
    input = Path.join(dir, "t#{tournament.id}_r#{next_number}.trf")
    output = Path.join(dir, "t#{tournament.id}_r#{next_number}_pairs.txt")
    File.write!(input, trf)

    case System.cmd("java", ["-jar", javafo_jar(), input, "-p", output], stderr_to_stdout: true) do
      {_out, 0} ->
        case output |> File.read!() |> parse_pairs() do
          {:ok, pairs} ->
            create_round(pairs, tournament, player_by_local_rank, next_number, round_absentees)

          {:error, message} ->
            Logger.error(
              "JaVaFo produced no pairings output for tournament #{tournament.id} round #{next_number} (exit 0, empty output file)"
            )

            {:error, message}
        end

      {out, code} ->
        Logger.error(
          "JaVaFo failed for tournament #{tournament.id} round #{next_number} (exit #{code}):\n#{out}"
        )

        {:error, "JaVaFo failed (exit #{code}):\n#{out}"}
    end
  end

  ## ---------- native per-category Swiss pairing (SWAR-parity #24) ----------

  # Partitions `players` by `player.category`, in `tournament.categories`
  # list order, plus a trailing "Uncategorized" pool for players whose
  # category is blank or doesn't match any listed category — a deliberate
  # product decision to still pair these players together as their own
  # pool, rather than excluding them from pairing entirely. Runs every
  # category's independent JaVaFo call (or synthesizes a 1-player group's
  # automatic bye) FIRST, entirely before any DB round/pairing row exists —
  # deliberately mirroring `do_pair_single/4`'s own ordering (build TRF /
  # run JaVaFo, only touch the DB once every pairing decision is known).
  # This isn't just style parity: `games_per_player/2` (used while building
  # each category's TRF input) queries "every paired Round of this
  # tournament" with no round-number filter, so if the `next_number` Round
  # row already existed (even pairing-less) while a later category's TRF
  # was being built, every player would pick up a phantom "Z" (zero-point
  # bye) game for the round STILL BEING PAIRED — corrupting the TRF's game
  # history and (confirmed by hitting it) crashing JaVaFo. Only once every
  # category's pairing decision is known does `insert_category_round/3`
  # open ONE transaction and write the Round + every category's pairings,
  # in category-list order, boards numbered continuously — the single
  # combined pairing sheet that's the whole point of doing this natively.
  defp do_pair_by_category(tournament, players, next_number, round_absentees) do
    groups = category_groups(tournament, players)

    # Tournament-wide history (every round/pairing, every bye, the full
    # roster) is identical for every category — computed once here and
    # threaded through, rather than each category's TRF build re-running
    # the same three queries (see `games_per_player/2`'s doc). Safe to
    # compute now: no DB round row exists yet at this point (see this
    # function's own moduledoc above for why that ordering matters).
    shared_history = build_shared_history(tournament.id)

    # The local contiguous rank map (and the row set that goes with it) now
    # spans the FULL frozen roster, exactly as in `do_pair_single/4` — every
    # category's TRF carries every player, so a category-A player's historical
    # opponent in category B (or now ineligible) always resolves to a real
    # rank with a real row, instead of being bye-rewritten and losing its
    # colour history. `shared_history.full_roster` is already `%{id =>
    # player}`, so reuse it rather than re-querying.
    full_roster =
      shared_history.full_roster |> Map.values() |> Enum.sort_by(& &1.pairing_number)

    local_rank_by_player_id =
      full_roster |> Enum.with_index(1) |> Map.new(fn {p, i} -> {p.id, i} end)

    case compute_category_pairs(
           tournament,
           groups,
           next_number,
           shared_history,
           full_roster,
           local_rank_by_player_id
         ) do
      {:ok, group_results} ->
        insert_category_round(tournament, group_results, next_number, round_absentees)

      {:error, _reason} = error ->
        error
    end
  end

  # Runs (or synthesizes) each category group's pairing decision in turn,
  # stopping at the first failure — no DB writes happen here at all (see
  # `do_pair_by_category/3`'s doc for why). A `{:error, reason}` from any
  # category short-circuits the whole round: `do_pair_by_category/3` never
  # reaches `insert_category_round/3`, so nothing is written for ANY
  # category — the round-level "all or nothing" guarantee, established here
  # rather than via `Repo.rollback/1` since no transaction is open yet at
  # this point.
  defp compute_category_pairs(
         tournament,
         groups,
         next_number,
         shared_history,
         full_roster,
         local_rank_by_player_id
       ) do
    result =
      groups
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {{category_name, group_players}, index}, {:ok, acc} ->
        case compute_category_group(
               tournament,
               category_name,
               index,
               group_players,
               next_number,
               shared_history,
               full_roster,
               local_rank_by_player_id
             ) do
          {:ok, group_result} -> {:cont, {:ok, [group_result | acc]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)

    case result do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  # A 1-player group can't go through JaVaFo at all — it's given a
  # pairing-allocated bye directly once `insert_category_round/3` writes it.
  defp compute_category_group(
         _tournament,
         category_name,
         _index,
         [player],
         _next_number,
         _shared_history,
         _full_roster,
         _local_rank_by_player_id
       ) do
    {:ok, {category_name, :bye, player}}
  end

  defp compute_category_group(
         tournament,
         category_name,
         index,
         group_players,
         next_number,
         shared_history,
         full_roster,
         local_rank_by_player_id
       ) do
    eligible_ids = MapSet.new(group_players, & &1.id)
    by_id = Map.new(full_roster, &{&1.id, &1})

    player_by_local_rank =
      Map.new(local_rank_by_player_id, fn {id, rank} -> {rank, Map.fetch!(by_id, id)} end)

    trf =
      build_category_trf(
        tournament,
        full_roster,
        eligible_ids,
        local_rank_by_player_id,
        shared_history
      )

    dir = Path.join(System.tmp_dir!(), "pairingsengine")
    File.mkdir_p!(dir)
    slug = category_file_slug(category_name, index)
    input = Path.join(dir, "t#{tournament.id}_r#{next_number}_cat_#{slug}.trf")
    output = Path.join(dir, "t#{tournament.id}_r#{next_number}_cat_#{slug}_pairs.txt")
    File.write!(input, trf)

    case System.cmd("java", ["-jar", javafo_jar(), input, "-p", output], stderr_to_stdout: true) do
      {_out, 0} ->
        case output |> File.read!() |> parse_pairs() do
          {:ok, pairs} ->
            {:ok, {category_name, :javafo, pairs, player_by_local_rank}}

          {:error, message} ->
            Logger.error(
              "JaVaFo produced no pairings output for tournament #{tournament.id} round #{next_number} category #{category_name} (exit 0, empty output file)"
            )

            {:error, "#{message} (category \"#{category_name}\")"}
        end

      {out, code} ->
        Logger.error(
          "JaVaFo failed for tournament #{tournament.id} round #{next_number} category #{category_name} (exit #{code}):\n#{out}"
        )

        {:error, "JaVaFo failed for category \"#{category_name}\" (exit #{code}):\n#{out}"}
    end
  end

  # Writes the Round and every category's pairings in ONE transaction, board
  # numbers running continuously across `group_results` (already in
  # `tournament.categories` list order — see `category_groups/2`). Only
  # reached once every category's pairing decision succeeded (see
  # `do_pair_by_category/3`), so this itself can no longer fail on a
  # category's JaVaFo call — the `Repo.transaction/1` wrapper here exists
  # for ordinary DB-write atomicity (Round + N Pairings as one unit), not to
  # guard against a JaVaFo failure (that's already been ruled out).
  defp insert_category_round(tournament, group_results, next_number, round_absentees) do
    Repo.transaction(fn ->
      round =
        Repo.insert!(%Round{
          tournament_id: tournament.id,
          number: next_number,
          status: "playing"
        })

      insert_round_absentee_byes(tournament, next_number, round_absentees)

      {_final_board, any_bye?} =
        Enum.reduce(group_results, {1, false}, fn group_result, {board_offset, any_bye?} ->
          case group_result do
            {_category_name, :bye, player} ->
              Repo.insert!(%Pairing{
                round_id: round.id,
                board: board_offset,
                white_player_id: player.id,
                black_player_id: nil,
                result: "bye"
              })

              {board_offset + 1, true}

            {_category_name, :javafo, pairs, player_by_local_rank} ->
              {:ok, boards_used, bye?} =
                insert_category_pairings(round, pairs, player_by_local_rank, board_offset)

              {board_offset + boards_used, any_bye? or bye?}
          end
        end)

      # A pairing-allocated bye (from any category's JaVaFo output, or a
      # 1-player group's automatic bye) awards points immediately without
      # ever going through Tournaments.update_pairing_result/2 — same
      # point-changing-write gap as elsewhere in this module. See
      # docs/manual-standings.md (Fix 3).
      if any_bye?, do: Tournaments.invalidate_manual_ranking(tournament.id)

      round
    end)
  end

  defp category_groups(tournament, players) do
    named_categories = tournament.categories || []
    named_set = MapSet.new(named_categories)

    named_groups =
      Enum.map(named_categories, fn cat_name ->
        {cat_name, Enum.filter(players, &(&1.category == cat_name))}
      end)

    # Blank/unlisted category players still get paired — as their own
    # "Uncategorized" pool, deliberately not excluded from pairing.
    uncategorized =
      Enum.filter(players, fn p ->
        p.category in [nil, ""] or not MapSet.member?(named_set, p.category)
      end)

    (named_groups ++ [{"Uncategorized", uncategorized}])
    |> Enum.reject(fn {_name, group} -> group == [] end)
  end

  # A category-safe filename: category names are free text, so they're
  # slugified (and index-prefixed, to avoid collisions between categories
  # that slugify identically) before landing in a temp file path — each
  # category's TRF input/output pair gets a distinct filename so parallel
  # or sequential category runs within one round never collide.
  defp category_file_slug(category_name, index) do
    slug =
      category_name
      |> to_string()
      |> String.replace(~r/[^A-Za-z0-9_-]+/, "_")

    slug = if slug in ["", "_"], do: "cat", else: slug
    "#{index}_#{slug}"
  end

  # Builds one category's TRF input. Unlike the earlier design, this is NOT
  # scoped to just the category's players: every category's TRF now carries
  # the FULL frozen roster (`full_roster` — every category, every historical
  # opponent), remapped to one shared local 1..M numbering, with only THIS
  # category's players (`eligible_ids`) left un-marked as pairing candidates.
  # Everyone else — other categories, now-ineligible players — gets an
  # explicit `0000 - Z` line via `mark_ineligible_for_round/2` so JaVaFo
  # keeps their real history (needed so a past opponent's colour/result
  # resolves via `remap_trf_rows_to_local_ranks/2` instead of being
  # bye-rewritten) while still not pairing them this run. Same reasoning as
  # `do_pair_single/4`'s doc comment.
  #
  # `forbidden_pairs_lines/3`/`exclusion_pairs_lines/3`/`acceleration_lines/4`
  # now also see the full roster rather than just this category — intentional
  # and harmless: a forbidden/exclusion line naming a player who's
  # ineligible-this-round is inert to JaVaFo, and this incidentally widens
  # `acceleration_lines`' roster scope too (a direction a separate Baku
  # acceleration audit finding wants; not verified here). `shared_history`
  # (see `build_shared_history/1`) is computed once by
  # `do_pair_by_category/4` and passed straight through.
  defp build_category_trf(
         tournament,
         full_roster,
         eligible_ids,
         local_rank_by_player_id,
         shared_history
       ) do
    trf_rows =
      tournament
      |> trf_player_rows(full_roster, shared_history)
      |> mark_ineligible_for_round(eligible_ids)
      |> remap_trf_rows_to_local_ranks(local_rank_by_player_id)

    trf =
      Trf.serialize(%{
        tournament: %{
          name: tournament.name,
          city: tournament.city,
          federation: tournament.federation,
          type: tournament.type,
          chief_arbiter: tournament.chief_arbiter
        },
        players: trf_rows
      })

    trf = trf <> "XXR #{tournament.rounds_count}\r\n"

    trf =
      trf <>
        acceleration_lines(
          tournament,
          full_roster,
          paired_rounds_count(tournament.id) + 1,
          local_rank_by_player_id
        )

    trf <>
      forbidden_pairs_lines(tournament.id, full_roster, local_rank_by_player_id) <>
      exclusion_pairs_lines(tournament, full_roster, local_rank_by_player_id)
  end

  # JaVaFo/TRF16 convention: a player row that already carries a result for
  # the round about to be paired is treated as already decided for that
  # round and excluded from pairing this run. Used so a round-specific
  # absentee or a permanently withdrawn/forfeited player can still be SENT a
  # row (needed so their past opponents' colour/result history resolves
  # correctly via `remap_trf_rows_to_local_ranks/2` below) while JaVaFo still
  # leaves them unpaired this round. `rows`' games lists never include the
  # round about to be paired in the first place (`games_per_player/3` only
  # ever iterates already-paired rounds), so appending one more entry always
  # lands in exactly that round's TRF column.
  defp mark_ineligible_for_round(rows, eligible_ids) do
    Enum.map(rows, fn row ->
      if MapSet.member?(eligible_ids, row.id) do
        row
      else
        zero_bye = %{opponent_rank: nil, opponent_id: nil, colour: nil, result: "Z", points_kind: "zero"}
        %{row | games: row.games ++ [zero_bye]}
      end
    end)
  end

  # Remaps `trf_player_rows/2`'s output (global `pairing_number`-based ranks)
  # to a local 1..M numbering (a category's own pool, or — since this fix —
  # a single-pool pairing run's round-specific eligible subset, see
  # `do_pair_single/4`): each row's own `rank`, and each of its games'
  # `opponent_rank` (looked up via the `opponent_id` `trf_game/3` now carries
  # alongside it — see that function).
  #
  # An opponent not present in `local_rank_by_player_id` at all — a game
  # against a player outside this run's local pool (category or, for
  # `do_pair_single/4`, a player excluded from THIS round only, e.g. a
  # different round's `absent_rounds` entry, or someone who's since gone
  # permanently absent/forfeited) — resolves `opponent_rank` to `nil`, same
  # as a genuinely opponentless game already does upstream. But unlike a
  # genuinely opponentless game, `game.result` here can still be a real
  # PLAYED-game code (the game against that historical opponent really was
  # played and scored) — pairing a nil rank with a played-game code is
  # exactly the illegal "0000 - 1"-style TRF row `bye_safe_result/2` exists
  # to prevent (see `trf_game/3`), so the same reinterpretation is reapplied
  # here for this second way a played game can end up with no resolvable
  # rank for its opponent.
  defp remap_trf_rows_to_local_ranks(rows, local_rank_by_player_id) do
    Enum.map(rows, fn row ->
      local_rank = Map.fetch!(local_rank_by_player_id, row.id)

      remapped_games =
        Enum.map(row.games, fn game ->
          local_opponent_rank =
            game[:opponent_id] && Map.get(local_rank_by_player_id, game.opponent_id)

          result =
            if game[:opponent_id] != nil and is_nil(local_opponent_rank) do
              bye_safe_result(game.result, nil)
            else
              game.result
            end

          game
          |> Map.put(:opponent_rank, local_opponent_rank)
          |> Map.put(:result, result)
        end)

      %{row | rank: local_rank, games: remapped_games}
    end)
  end

  # Translates one category's parsed JaVaFo output (local starting ranks)
  # back to real players via `player_by_local_rank`, inserting each pairing
  # at a board number continuing from `board_offset` — the mechanism that
  # merges every category's pairs into one continuously-numbered board
  # sequence within the shared Round. Mirrors `create_round/5`'s row shape
  # exactly (including the `b == 0` pairing-allocated bye shape).
  defp insert_category_pairings(round, pairs, player_by_local_rank, board_offset) do
    bye? = Enum.any?(pairs, fn {_w, b} -> b == 0 end)

    pairs
    |> Enum.with_index(board_offset)
    |> Enum.each(fn {{w, b}, board} ->
      white = Map.fetch!(player_by_local_rank, w)
      black = if b == 0, do: nil, else: Map.fetch!(player_by_local_rank, b)

      Repo.insert!(%Pairing{
        round_id: round.id,
        board: board,
        white_player_id: white.id,
        black_player_id: black && black.id,
        result: if(b == 0, do: "bye", else: "")
      })
    end)

    {:ok, length(pairs), bye?}
  end

  defp insert_round_absentee_byes(_tournament, _round_number, []), do: :ok

  defp insert_round_absentee_byes(tournament, round_number, round_absentees) do
    rows =
      Enum.map(round_absentees, fn p ->
        %{
          tournament_id: tournament.id,
          player_id: p.id,
          round: round_number,
          type: "requested-zero"
        }
      end)

    Repo.insert_all("byes", rows, on_conflict: :nothing)

    # A "requested-zero" bye immediately awards points (see
    # PairingsEngine.Standings) without ever going through
    # Tournaments.update_pairing_result/2 — a hand-set manual standings
    # order must be marked stale here too, same as any other point-changing
    # write. See docs/manual-standings.md (Fix 3).
    Tournaments.invalidate_manual_ranking(tournament.id)
    :ok
  end

  # JaVaFo pairing output: first line = number of pairs, then "white black"
  # per line as TRF starting ranks; 0 = pairing-allocated bye. Returns
  # `{:ok, pairs}`, or `{:error, message}` when the output file is entirely
  # empty — JaVaFo has been observed to exit 0 having written nothing, and
  # the old bare `[_count | lines] = ...` match crashed the whole
  # `pair_next_round/1` call with an opaque MatchError instead of the same
  # tidy `{:error, ...}` shape the nonzero-exit path already returns. A
  # present-but-"0" count line with no pair lines still parses as
  # `{:ok, []}`, exactly as before.
  #
  # `@doc false` and `def` (not `defp`) purely so tests can drive this
  # parsing edge case directly — same precedent as
  # `PairingsEngine.Fide.Sync`/`PairingsEngine.Kbsb.Sync`.
  @doc false
  def parse_pairs(text) do
    case text |> String.split(~r/\r?\n/) |> Enum.reject(&(String.trim(&1) == "")) do
      [] ->
        {:error,
         "JaVaFo produced no pairings output (it exited successfully but wrote an empty pairings file)"}

      [_count | lines] ->
        {:ok, parse_pair_lines(lines)}
    end
  end

  defp parse_pair_lines(lines) do
    Enum.map(lines, fn line ->
      [w, b] = line |> String.split() |> Enum.map(&String.to_integer/1)
      {w, b}
    end)
  end

  # `player_by_local_rank` is `do_pair_single/4`'s local 1..M rank map
  # (inverse of `local_rank_by_player_id`), NOT global `pairing_number` — see
  # that function's doc comment for why. JaVaFo's output pairs are starting
  # ranks in whatever numbering it was given, so the lookup here must use
  # the exact same map that was fed into `javafo_input/3`.
  defp create_round(pairs, tournament, player_by_local_rank, next_number, round_absentees) do
    pairing_allocated_bye? = Enum.any?(pairs, fn {_w, b} -> b == 0 end)

    Repo.transaction(fn ->
      round =
        Repo.insert!(%Round{
          tournament_id: tournament.id,
          number: next_number,
          status: "playing"
        })

      leg1_pairings =
        pairs
        |> Enum.with_index(1)
        |> Enum.map(fn {{w, b}, board} ->
          white = Map.fetch!(player_by_local_rank, w)
          black = if b == 0, do: nil, else: Map.fetch!(player_by_local_rank, b)

          Repo.insert!(%Pairing{
            round_id: round.id,
            board: board,
            white_player_id: white.id,
            black_player_id: black && black.id,
            result: if(b == 0, do: "bye", else: "")
          })
        end)

      insert_round_absentee_byes(tournament, next_number, round_absentees)

      # A pairing-allocated bye's pairing row is created with its result
      # ("bye") already set, awarding points immediately without ever going
      # through Tournaments.update_pairing_result/2 — the same
      # point-changing-write gap as insert_round_absentee_byes/3 above. See
      # docs/manual-standings.md (Fix 3).
      if pairing_allocated_bye?, do: Tournaments.invalidate_manual_ranking(tournament.id)

      if tournament.swiss_match_format do
        create_mirrored_leg(tournament, leg1_pairings, round_absentees, next_number + 1)
      else
        round
      end
    end)
  end

  # `swiss_match_format`'s second leg: same match, same boards, colours
  # reversed — an exact mirror of leg 1's freshly-inserted pairings, built
  # from Elixir data (no second JaVaFo call, no new TRF file). See the
  # field's doc comment on PairingsEngine.Tournaments.Tournament and the
  # module doc above `do_pair/2`.
  #
  # No extra `Tournaments.invalidate_manual_ranking/1` call is needed here:
  # every bye-type row leg 2 introduces (pairing-allocated or
  # requested-zero) is a mirror of a leg-1 event that already triggered its
  # own invalidation call above (pairing-allocated) or in
  # `insert_round_absentee_byes/3` (requested-zero, called by `do_pair/2`
  # before this transaction even starts) — `manual_ranking_stale` is a
  # single boolean flag, not per-round, so re-firing it for the mirrored
  # row would be a harmless but redundant broadcast-adjacent write.
  defp create_mirrored_leg(tournament, leg1_pairings, round_absentees, leg2_number) do
    leg2 =
      Repo.insert!(%Round{
        tournament_id: tournament.id,
        number: leg2_number,
        status: "playing"
      })

    Enum.each(leg1_pairings, fn p ->
      {white_id, black_id} =
        if p.black_player_id do
          # Ordinary pairing — same board, colours swapped.
          {p.black_player_id, p.white_player_id}
        else
          # Pairing-allocated bye — no colour to swap, same player earns
          # `bye_value` again for this leg (deliberate: a match-format bye
          # is two bye-legs, not one).
          {p.white_player_id, nil}
        end

      Repo.insert!(%Pairing{
        round_id: leg2.id,
        board: p.board,
        white_player_id: white_id,
        black_player_id: black_id,
        result: if(black_id, do: "", else: "bye")
      })
    end)

    # Round-specific absentees sit out both legs identically — see the
    # module doc above `do_pair/2` for the deliberate scope limitation
    # (leg 2's absentee set is leg 1's, not independently re-evaluated).
    unless round_absentees == [] do
      rows =
        Enum.map(round_absentees, fn player ->
          %{
            tournament_id: tournament.id,
            player_id: player.id,
            round: leg2_number,
            type: "requested-zero"
          }
        end)

      Repo.insert_all("byes", rows, on_conflict: :nothing)
    end

    leg2
  end

  ## ---------- JaVaFo TRF input ----------

  @doc """
  Builds the TRF text JaVaFo takes as input (TRF16 + XXR/XXA/XXP extensions).

  `rank_by_player_id` is an optional override, same idea as
  `forbidden_pairs_lines/3`/`exclusion_pairs_lines/3`'s own override: when
  `nil` (every existing caller's behaviour, unaffected), player rows/games
  keep using each player's raw global `pairing_number` exactly as before.
  `do_pair_single/4` passes a local contiguous 1..M rank map instead (built
  over the full frozen roster), so a gap in the middle of the global
  `pairing_number` range — an absent player excluded from THIS round only,
  not from the tournament's frozen numbering — never reaches JaVaFo as a gap
  in the TRF's starting-rank sequence, which is confirmed to crash it with a
  bare NullPointerException. See the `do_pair_single/4` doc comment for the
  full story.

  `eligible_ids`, when given, is a `MapSet` of the player ids that are
  actual pairing candidates for the round about to be paired. Every other
  player in `players` gets a `0000 - Z` line appended via
  `mark_ineligible_for_round/2` instead — the JaVaFo-native way to keep a
  player's real history in the file while excluding them from pairing this
  run. The pairing path (`do_pair_single/4`/`build_category_trf/5`) uses this
  to send JaVaFo the full roster while still only offering the actually-
  eligible players as candidates. `nil` (every existing caller, including
  tests and `PairingsEngine.TrfExport`-adjacent callers) skips this step
  entirely, so behaviour is byte-identical when omitted.
  """
  def javafo_input(tournament, players \\ nil, rank_by_player_id \\ nil, eligible_ids \\ nil) do
    players = players || active_players(tournament.id)
    trf_players = trf_player_rows(tournament, players)

    trf_players =
      if eligible_ids do
        mark_ineligible_for_round(trf_players, eligible_ids)
      else
        trf_players
      end

    trf_players =
      if rank_by_player_id do
        remap_trf_rows_to_local_ranks(trf_players, rank_by_player_id)
      else
        trf_players
      end

    trf =
      Trf.serialize(%{
        tournament: %{
          name: tournament.name,
          city: tournament.city,
          federation: tournament.federation,
          type: tournament.type,
          chief_arbiter: tournament.chief_arbiter
        },
        players: trf_players
      })

    # XXR: total number of rounds — required by JaVaFo to plan the pairing.
    trf = trf <> "XXR #{tournament.rounds_count}\r\n"

    # XXA: Baku acceleration virtual points (see acceleration_lines/4) — must
    # come before the pairing-engine invocation cares about standings, same
    # section as XXR.
    trf =
      trf <>
        acceleration_lines(
          tournament,
          players,
          paired_rounds_count(tournament.id) + 1,
          rank_by_player_id
        )

    # XXP: one line per forbidden pairing (see
    # PairingsEngine.Tournaments.list_forbidden_pairings/1 and
    # docs/forbidden-pairings.md) — JaVaFo's TRF extension for "these
    # starting ranks must never be paired against each other". Club/federation
    # exclusion rules (PairingsEngine.Exclusions) add further XXP lines the
    # same way, deduplicated against the explicit ones above.
    trf <>
      forbidden_pairs_lines(tournament.id, players, rank_by_player_id) <>
      exclusion_pairs_lines(tournament, players, rank_by_player_id)
  end

  @doc """
  Builds one `"XXP a b\\r\\n"` TRF extension line per forbidden pairing of
  `tournament_id`, translating each pair's player ids to their starting rank
  (`pairing_number`) among `players` for this pairing run. A pair is
  skipped silently if either player isn't in `players` at all, or hasn't
  been assigned a `pairing_number` yet — JaVaFo only needs to hear about
  players it's actually being asked to pair.

  `rank_by_player_id` defaults to `players`' own global `pairing_number`
  (every existing caller's behaviour, unaffected). Per-category Swiss
  pairing (`do_pair_by_category/3`) passes a category's local 1..M rank map
  instead — a pair naming a player outside the category (which can't
  resolve to a local rank) is dropped by the same nil-rejection below, with
  zero extra logic: they could never be paired against each other anyway.
  """
  def forbidden_pairs_lines(tournament_id, players, rank_by_player_id \\ nil) do
    rank_by_player_id = rank_by_player_id || Map.new(players, &{&1.id, &1.pairing_number})

    tournament_id
    |> Tournaments.list_forbidden_pairings()
    |> Enum.map(fn fp ->
      {rank_by_player_id[fp.player_a_id], rank_by_player_id[fp.player_b_id]}
    end)
    |> Enum.reject(fn {a, b} -> is_nil(a) or is_nil(b) end)
    |> Enum.map_join(fn {a, b} -> "XXP #{a} #{b}\r\n" end)
  end

  @doc """
  Builds one `"XXP a b\\r\\n"` TRF extension line per pair excluded by
  `tournament`'s club/federation exclusion rules (see
  `PairingsEngine.Exclusions.excluded_pairs/2`), translated to starting
  ranks the same way `forbidden_pairs_lines/3` does (see that function's doc
  for the optional `rank_by_player_id` override, used by per-category Swiss
  pairing). A pair already covered by an explicit forbidden pairing is
  skipped — JaVaFo doesn't need to hear the same rule twice — as is any pair
  where a player isn't in `players` or hasn't been assigned a rank yet.
  """
  def exclusion_pairs_lines(tournament, players, rank_by_player_id \\ nil) do
    rank_by_player_id = rank_by_player_id || Map.new(players, &{&1.id, &1.pairing_number})

    explicit_rank_pairs =
      tournament.id
      |> Tournaments.list_forbidden_pairings()
      |> Enum.map(fn fp ->
        {rank_by_player_id[fp.player_a_id], rank_by_player_id[fp.player_b_id]}
      end)
      |> Enum.reject(fn {a, b} -> is_nil(a) or is_nil(b) end)
      |> MapSet.new(&normalize_rank_pair/1)

    tournament
    |> Exclusions.excluded_pairs(players)
    |> Enum.map(fn {a, b} -> {rank_by_player_id[a.id], rank_by_player_id[b.id]} end)
    |> Enum.reject(fn {a, b} -> is_nil(a) or is_nil(b) end)
    |> Enum.map(&normalize_rank_pair/1)
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(explicit_rank_pairs, &1))
    |> Enum.map_join(fn {a, b} -> "XXP #{a} #{b}\r\n" end)
  end

  defp normalize_rank_pair({a, b}) when a <= b, do: {a, b}
  defp normalize_rank_pair({a, b}), do: {b, a}

  @doc """
  Builds one fixed-column `"XXA"` TRF extension line per Group-A player, per
  FIDE C.04.5.1 Baku Acceleration — JaVaFo's own "acceleration" TRF
  extension. Returns `""` unless `tournament.acceleration == "baku"` *and*
  `tournament.pairing_system == "swiss"`: round robin's fixed Berger
  schedule ignores acceleration entirely, and Keizer never goes through
  JaVaFo at all.

  ## Verified mechanism (do not re-guess this — see below)

  Per the JaVaFo 2.2 Advanced User Manual
  (rrweb.org/javafo/aum/JaVaFo2_AUM.htm): JaVaFo does **not** compute Baku
  acceleration on its own from a single flag. Its own words: *"JaVaFo can be
  informed of the fictitious points that are assigned to each player, using
  the extension code XXA"* and *"It is mandatory to keep the full record of
  the fictitious points assigned round by round, because this record is
  used to determine the floaters history of each player"*. So **we**
  compute every Group-A player's virtual points for every round played so
  far ourselves, straight from the FIDE C.04.5.1 text, and hand JaVaFo the
  full history — one column per round.

  The manual's format spec: `"XXA NNNN pp.p pp.p ..."`, where `XXA` starts
  at column 1, `NNNN` (the player's starting rank) starts at column 5, and
  each `pp.p` starts at column `10 + 5*(r-1)` (`r` = round). This is a
  **fixed-column** format, unlike this file's other free-form `XXR`/`XXP`
  extension lines — confirmed by direct experiment against the real
  `javafo.jar`: a free-form space-separated `"XXA 1 1.0 1.0\\r\\n"` line
  crashes JaVaFo with a bare `NullPointerException`
  (`B.A.B.D.J`/`B.A.B.I.K`/...), while the fixed-column form below runs
  clean. The same experiment (8 players, round 2, Group A = ranks 1-4 given
  a flat +1.0/+1.0 virtual-point history) also confirmed the values are not
  silently ignored: JaVaFo's round-2 pairing genuinely changed shape between
  the unaccelerated and accelerated runs, matching the FIDE description
  (Group-A players effectively face each other/tougher opposition sooner)
  — see `PairingsEngine.PairingTest` for the same assertion as an
  automated, `:javafo`-tagged end-to-end test.

  ## FIDE C.04.5.1 Baku Acceleration, as implemented here

  Group A (the group that receives virtual points) is the top half of the
  field by starting rank (`pairing_number`), rounded up to the nearest even
  number of players — FIDE's `2 * ceil(n/4)` — computed once from the
  *whole* roster passed in (not just this round's active subset), since
  starting rank is frozen for the tournament. Group B never receives
  points.

  "Accelerated rounds" are the first `ceil(rounds_count/2)` rounds. Within
  those, Group A gets 1.0 virtual point per round for the first half
  (rounded up) of the accelerated span, then 0.5 for the remainder, then 0
  forever after — this is the FIDE worked example verbatim: *"In a
  nine-round tournament, the accelerated rounds are five. The players in GA
  are assigned one virtual point in the first three rounds, and half
  virtual point in the next two rounds."*
  """
  def acceleration_lines(tournament, players, current_round, rank_by_player_id \\ nil)

  def acceleration_lines(
        %Tournament{acceleration: "baku", pairing_system: "swiss"} = tournament,
        players,
        current_round,
        rank_by_player_id
      )
      when is_integer(current_round) and current_round > 0 do
    ranked =
      players
      |> Enum.filter(&(&1.pairing_number != nil))
      |> Enum.sort_by(& &1.pairing_number)

    # Group-A membership is a tournament-wide FIDE concept computed from
    # GLOBAL starting rank (frozen for the tournament) — deliberately
    # unaffected by `rank_by_player_id`, which only changes how a Group-A
    # player's rank is *labelled* in the emitted XXA line below (see next
    # comment), not who's in Group A to begin with.
    group_a_size = 2 * ceil_div(length(ranked), 4)
    group_a_ranks = ranked |> Enum.take(group_a_size) |> MapSet.new(& &1.pairing_number)

    accelerated_rounds = ceil_div(tournament.rounds_count, 2)
    first_stage_rounds = ceil_div(accelerated_rounds, 2)

    ranked
    |> Enum.filter(&MapSet.member?(group_a_ranks, &1.pairing_number))
    |> Enum.map(fn player ->
      # `rank_by_player_id` given (do_pair_single/4's local rank map, or a
      # category's) means the XXP/player rows in this same run are keyed by
      # local rank, not global pairing_number — the XXA line's rank column
      # must match that same numbering, or it silently references a rank
      # that doesn't exist in this run's TRF16 player list. A Group-A player
      # not in `rank_by_player_id` at all (excluded from THIS run's pool —
      # e.g. a round-specific absentee) has nothing to place a line at, so
      # they're dropped rather than emitted with a stale/wrong rank.
      emitted_rank =
        if rank_by_player_id,
          do: Map.get(rank_by_player_id, player.id),
          else: player.pairing_number

      {emitted_rank, player}
    end)
    |> Enum.reject(fn {rank, _player} -> is_nil(rank) end)
    |> Enum.map_join(fn {rank, _player} ->
      points =
        Enum.map(1..current_round, &virtual_points(&1, accelerated_rounds, first_stage_rounds))

      xxa_line(rank, points)
    end)
  end

  def acceleration_lines(_tournament, _players, _current_round, _rank_by_player_id), do: ""

  defp virtual_points(round, accelerated_rounds, _first_stage_rounds)
       when round > accelerated_rounds,
       do: 0.0

  defp virtual_points(round, _accelerated_rounds, first_stage_rounds)
       when round <= first_stage_rounds,
       do: 1.0

  defp virtual_points(_round, _accelerated_rounds, _first_stage_rounds), do: 0.5

  # Fixed-column TRF extension line: "XXA" (cols 1-3), rank right-aligned in
  # cols 5-9, then one right-aligned pp.p per round in 5-column slots from
  # col 10 on — exactly the JaVaFo AUM's column spec. Free-form
  # space-separated XXA crashes JaVaFo (verified), unlike this file's other
  # XXR/XXP extension lines.
  defp xxa_line(rank, points) do
    id_field = String.pad_leading(to_string(rank), 5)

    points_fields =
      Enum.map_join(points, fn p ->
        String.pad_leading(:erlang.float_to_binary(p / 1, decimals: 1), 5)
      end)

    "XXA " <> id_field <> points_fields <> "\r\n"
  end

  defp ceil_div(a, b), do: div(a + b - 1, b)

  @doc """
  Builds the `PairingsEngine.Trf.serialize/1`-shaped player list (rank,
  identity fields, points, full-history games) for `players`, covering every
  paired round of `tournament` with no filtering. Shared by `javafo_input/2`
  (active players only, feeding the pairing engine) and
  `PairingsEngine.TrfExport` (the full roster, for the user-facing TRF
  download, which additionally trims each player's `:games` down to a
  chosen round subset — see that module).

  Players without a `pairing_number` yet (never included in a paired round)
  are dropped: TRF16 requires every player row to carry a numeric starting
  rank, and a player who was never actually paired has nothing meaningful
  to report anyway.

  Each row also carries an `:id` (the player's id) and each game an
  `:opponent_id` alongside the usual `:opponent_rank` — extra keys
  `PairingsEngine.Trf.serialize/1` and `PairingsEngine.TrfExport` both
  ignore (they only read the specific keys they need), but that
  per-category Swiss pairing's `remap_trf_rows_to_local_ranks/2` uses to
  translate global `pairing_number`-based ranks to a category's own local
  numbering — see `build_category_trf/5`.

  `shared_history`, when given, is a precomputed `build_shared_history/1`
  result — passed by `do_pair_by_category/3` so every category's call
  reuses the same tournament-wide query results instead of each one
  re-fetching identical data (see `games_per_player/2`). `nil` (every
  other caller) means "compute it fresh" — the original, unchanged
  behaviour.
  """
  def trf_player_rows(tournament, players, shared_history \\ nil) do
    players = Enum.filter(players, &(&1.pairing_number != nil))
    by_id = Map.new(players, &{&1.id, &1})
    games = games_per_player(tournament, by_id, shared_history)

    players
    |> Enum.sort_by(& &1.pairing_number)
    |> Enum.map(fn p ->
      player_games = Map.get(games, p.id, [])

      %{
        id: p.id,
        rank: p.pairing_number,
        sex: p.sex,
        title: p.title,
        name: p.name,
        # TRF16 is a FIDE report — always the FIDE rating, never a fallback
        # to the national rating (SWAR itself emits 0 for an unrated
        # player rather than substituting the national figure).
        fide_rating: p.fide_rating,
        federation: p.federation,
        fide_number: p.fide_id,
        birth_date: player_birth_date(p),
        points: player_points(player_games, tournament),
        games: player_games
      }
    end)
  end

  # Full date of birth (YYYY/MM/DD, via Trf's slash_date) when known,
  # otherwise the year-only fallback ("YYYY/00/00"), otherwise blank.
  defp player_birth_date(%{birth_date: %Date{} = date}), do: Date.to_iso8601(date)
  defp player_birth_date(%{birth_year: year}) when is_integer(year), do: "#{year}/00/00"
  defp player_birth_date(_), do: nil

  @doc "Sums `games`' TRF result codes into game points, per `tournament`'s point values."
  def player_points(games, t) do
    games
    |> Enum.map(fn g ->
      case g.result do
        "1" -> t.points_win
        "+" -> t.points_win
        "=" -> t.points_draw
        "H" -> t.points_draw
        "F" -> t.points_win
        "U" -> t.bye_value
        _ -> t.points_loss
      end
    end)
    |> Enum.sum()
  end

  # Every player who ever received a pairing_number, regardless of current
  # active/absent/forfeit/withdrawn status — the full frozen roster. Used to
  # scope the local rank map fed to JaVaFo (see `do_pair_single/4` and
  # `build_category_trf/5`): every possible historical opponent must resolve
  # to a real rank with a real row in the TRF, or `remap_trf_rows_to_local_ranks/2`
  # silently destroys that game's colour history — see that function's doc.
  defp full_roster_players(tournament_id) do
    Repo.all(
      from p in Player,
        where: p.tournament_id == ^tournament_id and not is_nil(p.pairing_number),
        order_by: p.pairing_number
    )
  end

  @doc """
  Players who are candidates for pairing at all: active status, neither
  permanently absent nor forfeited (SWAR Absent/Forfeit checkboxes). This is
  the full pool `ensure_pairing_numbers/2` freezes numbers over — round-
  specific absences (`eligible_players/2`'s extra filter) don't shrink it,
  so a player sitting out one round still gets/keeps a pairing number.

  Exposed so `PairingsEngine.Keizer` can freeze pairing numbers over the
  same player set Swiss does.
  """
  def active_players(tournament_id) do
    Repo.all(
      from p in Player,
        where:
          p.tournament_id == ^tournament_id and p.status == "active" and
            p.absent == false and p.forfeit == false
    )
  end

  @doc """
  Players eligible to be paired for `round_number`: active, not permanently
  absent/forfeited (see `active_players/1`), not requesting an absence for
  this specific round via `absent_rounds` (SWAR "Absent at the rounds
  x,y,z"), and not a late entrant whose `start_round` hasn't been reached
  yet (Keizer). Pure with respect to round-specific filtering — safe to
  unit-test without invoking JaVaFo.
  """
  def eligible_players(tournament_id, round_number) do
    tournament_id
    |> active_players()
    |> Enum.reject(&absent_for_round?(&1, round_number))
    |> Enum.reject(&not_yet_started?(&1, round_number))
  end

  @doc "True if `player`'s `absent_rounds` list includes `round_number`."
  def absent_for_round?(%Player{} = player, round_number) do
    round_number in parse_absent_rounds(player.absent_rounds)
  end

  @doc "True if `player.start_round` is set and later than `round_number` — a late entrant not yet eligible to be paired."
  def not_yet_started?(%Player{start_round: nil}, _round_number), do: false

  def not_yet_started?(%Player{start_round: start}, round_number),
    do: round_number < start

  defp parse_absent_rounds(nil), do: []
  defp parse_absent_rounds(""), do: []

  defp parse_absent_rounds(rounds) when is_binary(rounds) do
    rounds
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.to_integer/1)
  end

  # Games in TRF terms for every paired round: opponent pairing number,
  # colour, TRF result code. Rounds without a record become Z (zero-point bye).
  #
  # `by_id` scopes WHICH players' rows we build (the current round's target
  # set — e.g. `active_players/1`'s result, or a category's local group for
  # the per-category path) and must stay narrow. Historical opponent
  # identity is a different concern: a player paired in an earlier round may
  # since have gone absent/forfeited and dropped out of `by_id`, but the
  # game they played is still real and needs its opponent's true rank, not
  # a blank one. `build_shared_history/1`'s `full_roster` (every player who
  # ever received a pairing_number) is used for that lookup instead, so
  # `trf_game/3` can resolve any past opponent regardless of their current
  # eligibility.
  #
  # `shared_history`, when given, is a precomputed
  # `%{rounds:, bye_map:, full_roster:}` (see `build_shared_history/1`) —
  # reused as-is instead of re-querying. This is tournament-wide data that
  # doesn't depend on `by_id` at all, so per-category Swiss pairing
  # (`do_pair_by_category/3`) computes it ONCE and threads it through every
  # category's `trf_player_rows/3` call, rather than re-running the same
  # three queries once per category (confirmed identical data every time —
  # `by_id` only scopes which players' rows get BUILT from it, not what the
  # queries themselves return).
  defp games_per_player(tournament, by_id, shared_history) do
    %{rounds: rounds, bye_map: bye_map, full_roster: full_roster} =
      shared_history || build_shared_history(tournament.id)

    for {player_id, _player} <- by_id, into: %{} do
      games =
        Enum.map(rounds, fn round ->
          pairing =
            Enum.find(round.pairings, fn pr ->
              pr.white_player_id == player_id or pr.black_player_id == player_id
            end)

          cond do
            pairing != nil ->
              trf_game(pairing, player_id, full_roster)

            bye_type = bye_map[{player_id, round.number}] ->
              %{
                opponent_rank: nil,
                opponent_id: nil,
                colour: nil,
                result: bye_code(bye_type),
                points_kind: bye_type
              }

            true ->
              %{opponent_rank: nil, opponent_id: nil, colour: nil, result: "Z", points_kind: "zero"}
          end
        end)

      {player_id, games}
    end
  end

  # The three tournament-wide queries `games_per_player/2` needs, bundled
  # so they can be run ONCE and reused across multiple calls (see that
  # function's doc) — none of this depends on which players a particular
  # call is building rows for.
  #
  #   * `rounds` — every paired Round with its pairings preloaded.
  #   * `bye_map` — every `"byes"`-table row for the tournament, keyed by
  #     `{player_id, round}`.
  #   * `full_roster` — every player who ever received a `pairing_number`,
  #     the widest set a HISTORICAL opponent could possibly be (a player
  #     never actually paired has nothing meaningful to report anyway,
  #     mirroring `trf_player_rows/2`'s own tolerance rule) — deliberately
  #     wider than the `active_players/1`/category-local sets used to
  #     decide who gets rows built or who gets paired THIS round.
  defp build_shared_history(tournament_id) do
    rounds =
      Repo.all(
        from r in Round,
          where: r.tournament_id == ^tournament_id,
          order_by: r.number,
          preload: [pairings: []]
      )

    byes =
      Repo.all(
        from b in "byes",
          where: b.tournament_id == ^tournament_id,
          select: %{player_id: b.player_id, round: b.round, type: b.type}
      )

    full_roster =
      Repo.all(
        from p in Player,
          where: p.tournament_id == ^tournament_id and not is_nil(p.pairing_number)
      )
      |> Map.new(&{&1.id, &1})

    %{
      rounds: rounds,
      bye_map: Map.new(byes, &{{&1.player_id, &1.round}, &1.type}),
      full_roster: full_roster
    }
  end

  defp trf_game(pairing, player_id, full_roster) do
    white? = pairing.white_player_id == player_id

    opponent_id = if white?, do: pairing.black_player_id, else: pairing.white_player_id
    # Looked up against the FULL tournament roster (every player who ever
    # got a pairing_number), not just whoever is eligible for the round
    # currently being paired — a past opponent may since have gone
    # absent/forfeited and dropped out of that narrower set, but the game
    # they played is still real and its rank must still resolve. See
    # `games_per_player/2`.
    opponent = opponent_id && Map.get(full_roster, opponent_id)

    # Played games use TRF codes 1/0/= ; forfeits use + (win) / - (loss),
    # per FIDE Art. 16 both sides of a forfeit count as unplayed. A played
    # "0-0" (both players lose, e.g. both defaulted after making moves) is
    # code '0' for BOTH sides — distinct from a "0-0FF" double forfeit,
    # which is '-' for both. "+--"/"--+" are the legacy forfeit notation,
    # kept for historical/SWAR-imported data (see PairingsEngine.Tournaments.Pairing).
    result =
      case {pairing.result, white?} do
        {"bye", _} -> "U"
        {"1-0", true} -> "1"
        {"1-0", false} -> "0"
        {"0-1", true} -> "0"
        {"0-1", false} -> "1"
        {"1/2-1/2", _} -> "="
        {"1-0FF", true} -> "+"
        {"1-0FF", false} -> "-"
        {"0-1FF", true} -> "-"
        {"0-1FF", false} -> "+"
        {"0-0FF", _} -> "-"
        {"0-0", _} -> "0"
        {"+--", true} -> "+"
        {"+--", false} -> "-"
        {"--+", true} -> "-"
        {"--+", false} -> "+"
        {"", _} -> nil
        _ -> nil
      end
      |> bye_safe_result(opponent_id)

    %{
      opponent_rank: opponent && opponent.pairing_number,
      # The opponent's raw id, carried alongside `opponent_rank`
      # so per-category Swiss pairing's `remap_trf_rows_to_local_ranks/2` can
      # translate it to a category's own local rank numbering (see
      # `build_category_trf/5`). `PairingsEngine.Trf.serialize/1` and
      # `PairingsEngine.TrfExport` both ignore this extra key.
      opponent_id: opponent_id,
      colour:
        cond do
          pairing.result == "bye" or opponent_id == nil -> nil
          white? -> "w"
          true -> "b"
        end,
      result: result,
      points_kind: "game"
    }
  end

  # JaVaFo/TRF16 rule: opponent 0000 may only ever carry a bye/unplayed code
  # (F/H/Z/U) — never a played-game code (1/=/0/+/-). Reported bug: a
  # SWAR-imported round could carry a played-game result on a game with no
  # real opponent (e.g. a bye's score recorded as if it were an ordinary
  # game), producing an illegal "0000 - 1" / "0000 - =" row that crashes
  # JaVaFo with "B.A.B.E: Unexpected format of player line". This is the
  # single choke point both `javafo_input/2` and `PairingsEngine.TrfExport`
  # go through (via `trf_player_rows/2`), so normalizing here fixes both.
  #
  # A playing code with no opponent is reinterpreted by the point value it
  # represents: a win or forfeit-win is a full-point bye (F), a draw is a
  # half-point bye (H), a loss or forfeit-loss is a zero-point bye (Z).
  # Already-legal codes (bye codes, or any code when a real opponent exists)
  # and a missing result (nil) pass through unchanged.
  defp bye_safe_result(result, opponent_id) when not is_nil(opponent_id), do: result

  defp bye_safe_result(result, nil) do
    case result do
      code when code in ["1", "+"] -> "F"
      "=" -> "H"
      code when code in ["0", "-"] -> "Z"
      other -> other
    end
  end

  defp bye_code("requested-half"), do: "H"
  defp bye_code("requested-zero"), do: "Z"
  defp bye_code("absent"), do: "Z"
  defp bye_code("pairing-allocated"), do: "U"
  defp bye_code(_), do: "Z"
end
