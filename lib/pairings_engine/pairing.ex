defmodule PairingsEngine.Pairing do
  @moduledoc """
  Round lifecycle: builds the TRF input for the Swiss engine, runs it, and
  creates the round with its pairings.

  Ainalrami (github.com/AuroraRyunix/Ainalrami), a from-scratch Dutch-system
  engine in pure Elixir, is the default. It implements C.04.3 as it stands
  in the edition effective 1 February 2026.

  A tournament may instead select `pairing_engine: "javafo"` - JaVaFo
  (© Roberto Ricca), invoked as `java -jar javafo.jar input.trf -p
  output.txt`, whose output lists one "white black" pair of TRF starting
  ranks per line with 0 meaning the pairing-allocated bye. It carries FIDE's
  endorsement, and implements the 2022 rules. Everything up to and including the TRF text is
  **identical** for both engines: `run_engine/5` is handed the very same
  bytes `javafo_input/4` built, so the two are directly comparable on real
  tournament data rather than only on synthetic input, and only the last
  step - how those bytes become `[{white_rank, black_rank}]` - differs.
  Everything downstream (`create_round/5`, board freezing, absentee byes) is
  common to both.

  See `docs/pairing-systems.md` for the arbiter-facing description, and
  `docs/fide-endorsement.md` for what running a rated event on Ainalrami
  does to the "Internal engine: NO - thru JaVaFo" answer on FE1. It is no
  longer refused, but it is not free either.
  """

  import Ecto.Query
  require Logger
  alias PairingsEngine.{Repo, Standings, Trf, Tournaments, Exclusions}
  alias PairingsEngine.Tournaments.{Player, Round, Pairing, Tournament}

  def javafo_jar do
    Path.join(:code.priv_dir(:pairings_engine), "javafo/javafo.jar")
  end

  # A private scratch directory for one JaVaFo run, removed again when that
  # run finishes.
  #
  # These files hold the tournament's whole roster, and the previous fixed
  # path (`$TMPDIR/pairingsengine/t<id>_r<n>.trf`) was entirely predictable:
  # on a shared host any other local account could read the players out of it,
  # or pre-create the path as a symlink and have `File.write!/2` follow it and
  # clobber a file of their choosing under this app's user. A random directory
  # name can't be guessed ahead of the write, and 0700 keeps its contents to
  # this user even where $TMPDIR is world-readable.
  defp workdir! do
    suffix = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
    dir = Path.join(System.tmp_dir!(), "pairingsengine-#{suffix}")

    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)

    dir
  end

  # Fires with the exact TRF text about to be sent to JaVaFo, before it ever
  # touches disk - the scratch file itself is deleted right after each run
  # (see `workdir!/0`'s doc), so this is the only way to observe it
  # afterward. Exists purely for test observability (see the `:javafo`-tagged
  # tests in pairing_test.exs that attach a handler to this event to inspect
  # the generated TRF's colour/rank content) - nothing in the app itself
  # subscribes to it.
  defp emit_trf_built(tournament_id, round_number, category_name, trf) do
    :telemetry.execute(
      [:pairings_engine, :pairing, :trf_built],
      %{},
      %{tournament_id: tournament_id, round: round_number, category: category_name, trf: trf}
    )
  end

  @doc """
  Pairs the next round. Dispatches on `tournament.pairing_system`:

    * `"swiss"` (default) - the JaVaFo/Dutch path below, unchanged.
    * `"round_robin"` - delegates to `PairingsEngine.RoundRobin.pair_next_round/1`.
    * `"keizer"` - delegates to `PairingsEngine.Keizer.pair_next_round/1`.

  Returns `{:ok, round}` or `{:error, reason}`. This is the single public
  entry point the UI calls (see `PairingsEngineWeb.PairingsLive`'s "pair"
  event) - it never crashes on an unimplemented pairing system, it just
  returns a plain-string error the caller already renders as-is.
  """
  # Archived tournaments are frozen read-only (see
  # `Tournaments.ensure_writable/1`). Matched before the pairing-system
  # dispatch below so it covers Swiss, round robin and Keizer in one place.
  # Returns a plain-string error like every other refusal here, since the
  # caller renders these as-is.
  def pair_next_round(%Tournament{archived_at: archived_at}) when not is_nil(archived_at) do
    {:error, "This tournament is archived - unarchive it before pairing."}
  end

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
  # and `next_number + 1`) in one `do_pair/2` call - see that function -
  # so the pairing boundary must leave room for both legs of the *next*
  # match, not just the next single round: with 2 rounds left, pairing
  # must still be allowed (it fills the final match); with 1 round left,
  # it must not (there's no room for a second leg). Hence `rounds_count -
  # 1` rather than `rounds_count`. As a consequence, `paired_rounds_count/1`
  # always lands on an even number after a successful match-format pairing
  # (each call adds exactly 2 rounds), so `next_number = paired + 1` is
  # always odd the next time `pair_next_round/1` runs - every match-format
  # pairing run always starts a fresh match at its first leg, never lands
  # mid-match.
  defp max_pairable_round(%Tournament{swiss_match_format: true, rounds_count: n}), do: n - 1
  defp max_pairable_round(%Tournament{rounds_count: n}), do: n

  # Calls `module.pair_next_round(tournament)` (module dispatched at runtime
  # so the compiler doesn't over-narrow the result type to today's single
  # `{:error, :not_implemented}` stub return value - once RoundRobin/Keizer
  # are actually implemented this same function keeps working unchanged)
  # and turns a not-implemented stub result into a friendly, user-facing
  # string. PairingsLive's "pair" handler just does `to_string(reason)` on
  # any non-changeset error, so a plain string here is what ends up on
  # screen - no atom formatting, no crash.
  #
  # On success, refreshes the tournament's derived status the same way the
  # Swiss path below does - RoundRobin/Keizer pair a round and broadcast
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
  BOTH legs of a match (rounds N and N+1 - see `create_mirrored_leg/4` and
  the comment above `max_pairable_round/1`, which documents that
  `paired_rounds_count/1` always lands on an even number after a
  match-format pairing run). Deleting only one leg would break that
  invariant - orphaning leg 1, or stranding the tournament with a
  `next_number` `max_pairable_round/1` can never reach again - so both legs
  of the match are deleted together here.

  Also deletes the round's `byes` rows: the `byes` table has no `round_id`
  foreign key (see the migration), so a plain `Round` delete would otherwise
  leave orphaned bye rows behind that collide (`UNIQUE(player_id, round)`)
  the next time this round number is paired.
  """
  def delete_round(tournament_id, number) do
    if Tournaments.ensure_writable(tournament_id) != :ok do
      {:error, "This tournament is archived - unarchive it before unpairing."}
    else
      do_delete_round(tournament_id, number)
    end
  end

  defp do_delete_round(tournament_id, number) do
    if number == paired_rounds_count(tournament_id) do
      match_format? =
        Repo.one(
          from t in Tournament, where: t.id == ^tournament_id, select: t.swiss_match_format
        )

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
  one yet - highest rating first, name ascending as the tie-break (FIDE
  C.04.2.B), continuing from the current max existing number - then leaves
  them frozen forever (never reassigned once set). Returns `tournament`
  unchanged, so it composes in a pipe the same way the Swiss path above
  uses it.

  Exposed (not private) so `PairingsEngine.Keizer` can freeze pairing
  numbers at its own first pairing exactly the same way, rather than
  duplicating this logic - see that module's `do_pair/4`.
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
  # transaction, an exact colour-reversed mirror of leg 1 - no second
  # JaVaFo call, no new TRF file (see `create_mirrored_leg/4`). Round-
  # specific absentees for `next_number` (`round_absentees` below) are
  # threaded through so leg 2 can mirror their requested-bye rows too,
  # rather than independently re-evaluating `absent_for_round?/2` for
  # `next_number + 1` - a deliberate scope limitation, see
  # `create_mirrored_leg/4`.
  defp do_pair(tournament, next_number) do
    # A late entrant is dropped here, before the absent/present split, and
    # so lands in NEITHER list: not sent to the engine, and not given an
    # absentee bye row either. They are not absent - they have not joined
    # yet, and a round before `start_round` is a round the tournament did
    # not have them for.
    #
    # `pair_next_round/1` has always computed this filter (that is what
    # `eligible_players/2` is), but only ever used the result to count
    # heads for the "at least two players" guard. The roster handed to the
    # engine was rebuilt here from `active_players/1` and never had the
    # filter applied, so a Swiss tournament restored from a backup with a
    # player at `start_round: 3` paired them in rounds 1 and 2. Keizer read
    # `start_round` correctly all along; only this path did not.
    active =
      tournament.id
      |> active_players()
      |> Enum.reject(&not_yet_started?(&1, next_number))

    {players, round_specific} =
      Enum.split_with(active, &(not absent_for_round?(&1, next_number)))

    # A player marked absent for the whole tournament never reached this
    # function at all: `active_players/1` filters them out in SQL, so they
    # were not in `active`, not in the split above, and got no bye row for
    # any round. No board, no forfeit, no row - they simply vanished from
    # the round, scoring zero no matter what the tournament's absence value
    # said. Keizer had always recorded them; Swiss never did.
    #
    # Both kinds are the same event. You only ever know somebody is absent
    # BEFORE the round is paired because they told you - an unannounced
    # no-show gets paired and forfeits - so "requested a bye" and "marked
    # absent" are one thing wearing two names, and they score through one
    # value and one allowance.
    round_absentees = round_specific ++ absent_players(tournament.id)

    # Players requesting an absence for this specific round get a bye row
    # instead of being sent to the engine, so the
    # pairing engine never considers them for this round. Computed once over
    # the whole active/round_absentees split, before any category
    # partitioning happens below - unaffected by `pair_by_category`.
    #
    # The actual `insert_round_absentee_byes/3` call happens later, inside
    # `create_round/5`'s or `insert_category_round/3`'s `Repo.transaction`
    # (after JaVaFo has already succeeded) rather than here - see those
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
  # frozen `pairing_number` pool - `active_players/1` covers permanent
  # absentees/forfeits/inactive status, but a player sitting out only THIS
  # round (`absent_rounds`) still holds their global `pairing_number` and
  # still appears in `active_players/1`, just not here.
  #
  # We still need a LOCAL contiguous 1..M rank map: sending JaVaFo a TRF
  # whose starting ranks aren't contiguous 1..N crashes it with a bare
  # NullPointerException - confirmed against the real jar (see
  # `test/pairings_engine/swar_import_test.exs`'s "pairing a new round after
  # import doesn't crash when a historical opponent is now excluded").
  #
  # Crucially, that local map is now built over the FULL frozen roster
  # (`full_roster_players/1` - every player who ever held a `pairing_number`,
  # regardless of current active/absent/forfeit/withdrawn status), NOT just
  # `players`. If it were scoped to `players`, any historical opponent now
  # outside that subset - a withdrawn/forfeited player, a round-specific
  # absentee - would miss the rank map, and
  # `remap_trf_rows_to_local_ranks/2` would rewrite that genuinely-played
  # game into a synthetic bye code, silently destroying its colour history
  # and letting JaVaFo violate FIDE colour alternation. Scoping the map to
  # the full roster guarantees every possible historical opponent resolves
  # to a real rank with a real TRF row.
  #
  # A row is sent for every full-roster player (a rank column with no
  # matching row is meaningless to JaVaFo). Players who aren't actually
  # candidates for THIS round - everyone not in `players` - are still marked
  # with an explicit `0000 - Z` line via `javafo_input/4`'s `eligible_ids`
  # (`mark_ineligible_for_round/2`), the verified-safe JaVaFo-native way to
  # keep a player's real history while excluding them from pairing this run.
  #
  # JaVaFo's output pairs (local ranks) are translated back to real players
  # via the inverse map in `create_round/5`. Board numbering (JaVaFo's output
  # *order*, not its rank values) is completely unaffected by this.
  defp do_pair_single(tournament, players, next_number, round_absentees) do
    full_roster = full_roster_players(tournament.id) |> order_for_pairing(tournament)
    eligible_ids = MapSet.new(players, & &1.id)

    local_rank_by_player_id =
      full_roster |> Enum.with_index(1) |> Map.new(fn {p, i} -> {p.id, i} end)

    by_id = Map.new(full_roster, &{&1.id, &1})

    player_by_local_rank =
      Map.new(local_rank_by_player_id, fn {id, rank} -> {rank, Map.fetch!(by_id, id)} end)

    trf = javafo_input(tournament, full_roster, local_rank_by_player_id, eligible_ids)
    emit_trf_built(tournament.id, next_number, nil, trf)

    case run_engine(tournament, trf, next_number, nil) do
      {:ok, pairs, explanation} ->
        create_round(
          pairs,
          tournament,
          player_by_local_rank,
          next_number,
          round_absentees,
          explanation_payload([{nil, explanation, player_by_local_rank}])
        )

      {:error, _message} = error ->
        error
    end
  end

  ## ---------- native per-category Swiss pairing (SWAR-parity #24) ----------

  # Partitions `players` by `player.category`, in `tournament.categories`
  # list order, plus a trailing "Uncategorized" pool for players whose
  # category is blank or doesn't match any listed category - a deliberate
  # product decision to still pair these players together as their own
  # pool, rather than excluding them from pairing entirely. Runs every
  # category's independent JaVaFo call (or synthesizes a 1-player group's
  # automatic bye) FIRST, entirely before any DB round/pairing row exists -
  # deliberately mirroring `do_pair_single/4`'s own ordering (build TRF /
  # run JaVaFo, only touch the DB once every pairing decision is known).
  # This isn't just style parity: `games_per_player/2` (used while building
  # each category's TRF input) queries "every paired Round of this
  # tournament" with no round-number filter, so if the `next_number` Round
  # row already existed (even pairing-less) while a later category's TRF
  # was being built, every player would pick up a phantom "Z" (zero-point
  # bye) game for the round STILL BEING PAIRED - corrupting the TRF's game
  # history and (confirmed by hitting it) crashing JaVaFo. Only once every
  # category's pairing decision is known does `insert_category_round/3`
  # open ONE transaction and write the Round + every category's pairings,
  # in category-list order, boards numbered continuously - the single
  # combined pairing sheet that's the whole point of doing this natively.
  defp do_pair_by_category(tournament, players, next_number, round_absentees) do
    groups = category_groups(tournament, players)

    # Tournament-wide history (every round/pairing, every bye, the full
    # roster) is identical for every category - computed once here and
    # threaded through, rather than each category's TRF build re-running
    # the same three queries (see `games_per_player/2`'s doc). Safe to
    # compute now: no DB round row exists yet at this point (see this
    # function's own moduledoc above for why that ordering matters).
    shared_history = build_shared_history(tournament.id)

    # The local contiguous rank map (and the row set that goes with it) now
    # spans the FULL frozen roster, exactly as in `do_pair_single/4` - every
    # category's TRF carries every player, so a category-A player's historical
    # opponent in category B (or now ineligible) always resolves to a real
    # rank with a real row, instead of being bye-rewritten and losing its
    # colour history. `shared_history.full_roster` is already `%{id =>
    # player}`, so reuse it rather than re-querying.
    full_roster =
      shared_history.full_roster
      |> Map.values()
      |> order_for_pairing(tournament, shared_history)

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
  # stopping at the first failure - no DB writes happen here at all (see
  # `do_pair_by_category/3`'s doc for why). A `{:error, reason}` from any
  # category short-circuits the whole round: `do_pair_by_category/3` never
  # reaches `insert_category_round/3`, so nothing is written for ANY
  # category - the round-level "all or nothing" guarantee, established here
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

  # A 1-player group can't go through JaVaFo at all - it's given a
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

    emit_trf_built(tournament.id, next_number, category_name, trf)

    case run_engine(tournament, trf, next_number, category_name, index) do
      {:ok, pairs, explanation} ->
        {:ok, {category_name, :paired, pairs, player_by_local_rank, explanation}}

      {:error, _message} = error ->
        error
    end
  end

  # Writes the Round and every category's pairings in ONE transaction, board
  # numbers running continuously across `group_results` (already in
  # `tournament.categories` list order - see `category_groups/2`). Only
  # reached once every category's pairing decision succeeded (see
  # `do_pair_by_category/3`), so this itself can no longer fail on a
  # category's JaVaFo call - the `Repo.transaction/1` wrapper here exists
  # for ordinary DB-write atomicity (Round + N Pairings as one unit), not to
  # guard against a JaVaFo failure (that's already been ruled out).
  defp insert_category_round(tournament, group_results, next_number, round_absentees) do
    # One section per category that the engine actually paired. A 1-player
    # group's automatic bye never reaches an engine, so it contributes none.
    explanation =
      group_results
      |> Enum.flat_map(fn
        {category_name, :paired, _pairs, by_rank, bracket_report} ->
          [{category_name, bracket_report, by_rank}]

        _bye ->
          []
      end)
      |> explanation_payload()

    Repo.transaction(fn ->
      round =
        Repo.insert!(%Round{
          tournament_id: tournament.id,
          number: next_number,
          status: "playing",
          published_at: Tournaments.compute_published_at(tournament, next_number),
          explanation: explanation
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

            {_category_name, :paired, pairs, player_by_local_rank, _explanation} ->
              {:ok, boards_used, bye?} =
                insert_category_pairings(round, pairs, player_by_local_rank, board_offset)

              {board_offset + boards_used, any_bye? or bye?}
          end
        end)

      # A pairing-allocated bye (from any category's JaVaFo output, or a
      # 1-player group's automatic bye) awards points immediately without
      # ever going through Tournaments.update_pairing_result/2 - same
      # point-changing-write gap as elsewhere in this module. See
      # docs/manual-standings.md (Fix 3).
      if any_bye?, do: Tournaments.invalidate_manual_ranking(tournament.id)

      Tournaments.freeze_round_display_boards!(round.id)

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

    # Blank/unlisted category players still get paired - as their own
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
  # that slugify identically) before landing in a temp file path - each
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
  # the FULL frozen roster (`full_roster` - every category, every historical
  # opponent), remapped to one shared local 1..M numbering, with only THIS
  # category's players (`eligible_ids`) left un-marked as pairing candidates.
  # Everyone else - other categories, now-ineligible players - gets an
  # explicit `0000 - Z` line via `mark_ineligible_for_round/2` so JaVaFo
  # keeps their real history (needed so a past opponent's colour/result
  # resolves via `remap_trf_rows_to_local_ranks/2` instead of being
  # bye-rewritten) while still not pairing them this run. Same reasoning as
  # `do_pair_single/4`'s doc comment.
  #
  # `forbidden_pairs_lines/3`/`exclusion_pairs_lines/3`/`acceleration_lines/4`
  # now also see the full roster rather than just this category - intentional
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
      # Physical row order, not just the `:rank` field - see the identical
      # re-sort (and its full rationale) in `javafo_input/4`.
      |> Enum.sort_by(& &1.rank)

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
        zero_bye = %{
          opponent_rank: nil,
          opponent_id: nil,
          colour: nil,
          result: "Z",
          points_kind: "zero"
        }

        %{row | games: row.games ++ [zero_bye]}
      end
    end)
  end

  # Remaps `trf_player_rows/2`'s output (global `pairing_number`-based ranks)
  # to a local 1..M numbering (a category's own pool, or - since this fix -
  # a single-pool pairing run's round-specific eligible subset, see
  # `do_pair_single/4`): each row's own `rank`, and each of its games'
  # `opponent_rank` (looked up via the `opponent_id` `trf_game/3` now carries
  # alongside it - see that function).
  #
  # An opponent not present in `local_rank_by_player_id` at all - a game
  # against a player outside this run's local pool (category or, for
  # `do_pair_single/4`, a player excluded from THIS round only, e.g. a
  # different round's `absent_rounds` entry, or someone who's since gone
  # permanently absent/forfeited) - resolves `opponent_rank` to `nil`, same
  # as a genuinely opponentless game already does upstream. But unlike a
  # genuinely opponentless game, `game.result` here can still be a real
  # PLAYED-game code (the game against that historical opponent really was
  # played and scored) - pairing a nil rank with a played-game code is
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
  # at a board number continuing from `board_offset` - the mechanism that
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
          type: "absent"
        }
      end)

    Repo.insert_all("byes", rows, on_conflict: :nothing)

    # A requested bye immediately awards points (see
    # PairingsEngine.Standings) without ever going through
    # Tournaments.update_pairing_result/2 - a hand-set manual standings
    # order must be marked stale here too, same as any other point-changing
    # write. See docs/manual-standings.md (Fix 3).
    Tournaments.invalidate_manual_ranking(tournament.id)
    :ok
  end

  ## ---------- pairing engines ----------
  #
  # The single seam where a TRF becomes a list of pairs. Both Swiss pairing
  # paths (`do_pair_single/4` and the per-category
  # `compute_category_group/8`) funnel through here, so a new engine is added
  # in exactly one place and neither path can drift from the other.
  #
  # The contract in both directions is deliberately identical to what the
  # JaVaFo-only code already had:
  #
  #   * IN - the exact TRF text `javafo_input/4` produced, unmodified. Not a
  #     re-serialization, not a restructured intermediate: the same bytes.
  #     That is what makes the two engines comparable on real tournament
  #     data (feed one round to both, diff the answers) and it is why
  #     `emit_trf_built/4` still fires exactly once per engine run, engine
  #     choice notwithstanding.
  #   * OUT - `{:ok, [{white_rank, black_rank}]}` in the LOCAL contiguous
  #     rank numbering the TRF was built in, `0` for the pairing-allocated
  #     bye (`parse_pairs/1`'s long-standing shape), or `{:error, message}`
  #     with a plain user-facing string. `create_round/5` and
  #     `insert_category_pairings/4` are untouched and cannot tell which
  #     engine answered.

  defp run_engine(tournament, trf, round_number, category_name, category_index \\ 0)

  defp run_engine(
         %Tournament{pairing_engine: "ainalrami"} = tournament,
         trf,
         round_number,
         category_name,
         _category_index
       ) do
    run_ainalrami(tournament, trf, round_number, category_name)
  end

  defp run_engine(tournament, trf, round_number, category_name, category_index) do
    case run_javafo(tournament, trf, round_number, category_name, category_index) do
      {:ok, pairs} -> {:ok, pairs, nil}
      {:error, _message} = error -> error
    end
  end

  # Unchanged from the two copies this replaced, down to the scratch-file
  # names and the exact error strings - see `workdir!/0` for why the
  # directory is randomized, 0700 and deleted in an `after`.
  defp run_javafo(tournament, trf, round_number, category_name, category_index) do
    dir = workdir!()
    stem = javafo_file_stem(tournament, round_number, category_name, category_index)
    input = Path.join(dir, stem <> ".trf")
    output = Path.join(dir, stem <> "_pairs.txt")

    try do
      File.write!(input, trf)

      case System.cmd("java", ["-jar", javafo_jar(), input, "-p", output], stderr_to_stdout: true) do
        {_out, 0} ->
          case output |> File.read!() |> parse_pairs() do
            {:ok, pairs} ->
              {:ok, pairs}

            {:error, message} ->
              Logger.error(
                "JaVaFo produced no pairings output for #{engine_log_scope(tournament, round_number, category_name)} (exit 0, empty output file)"
              )

              {:error, javafo_empty_output_message(message, category_name)}
          end

        {out, code} ->
          Logger.error(
            "JaVaFo failed for #{engine_log_scope(tournament, round_number, category_name)} (exit #{code}):\n#{out}"
          )

          {:error, javafo_failure_message(code, out, category_name)}
      end
    after
      File.rm_rf(dir)
    end
  end

  defp javafo_file_stem(tournament, round_number, nil, _index),
    do: "t#{tournament.id}_r#{round_number}"

  defp javafo_file_stem(tournament, round_number, category_name, index),
    do: "t#{tournament.id}_r#{round_number}_cat_#{category_file_slug(category_name, index)}"

  defp engine_log_scope(tournament, round_number, nil),
    do: "tournament #{tournament.id} round #{round_number}"

  defp engine_log_scope(tournament, round_number, category_name),
    do: "tournament #{tournament.id} round #{round_number} category #{category_name}"

  defp javafo_empty_output_message(message, nil), do: message

  defp javafo_empty_output_message(message, category_name),
    do: "#{message} (category \"#{category_name}\")"

  defp javafo_failure_message(code, out, nil), do: "JaVaFo failed (exit #{code}):\n#{out}"

  defp javafo_failure_message(code, out, category_name),
    do: "JaVaFo failed for category \"#{category_name}\" (exit #{code}):\n#{out}"

  # Ainalrami runs IN THIS BEAM - no subprocess, no JVM, no temp file, so
  # none of `run_javafo/5`'s scratch-directory machinery applies. It reads
  # the same TRF text through its own `Ainalrami.Trf.parse/1` and returns
  # pairs in the same local-rank convention, differing only in spelling the
  # pairing-allocated bye `nil` where JaVaFo's text output spells it `0`;
  # `ainalrami_bye_to_zero/1` normalizes that so `create_round/5` sees the
  # shape it has always seen.
  #
  # `expected_rounds` is read back out of the TRF rather than off the
  # tournament struct on purpose: it must be whatever the FILE says, since
  # that is what JaVaFo would have been told (`XXR`), and Ainalrami's
  # final-round colour exception keys off it. Taking it from the struct
  # would silently diverge the two engines on the last round if the two ever
  # disagreed.
  defp run_ainalrami(tournament, trf, round_number, category_name) do
    case ainalrami_unsupported_extensions(trf) do
      [] ->
        parsed = Ainalrami.Trf.parse(trf)

        engine_opts = [
          expected_rounds: parsed.tournament[:number_of_rounds],
          # `Ainalrami.Trf.parse/1` lifts every `XXP` line into
          # `tournament[:forbidden_pairs]`, but the engine takes them as an
          # OPTION rather than reading them off the parsed struct - so
          # omitting this parsed them and threw them away. Every explicit
          # forbidden pairing and every club/federation exclusion was
          # silently ignored, which is the exact failure the extension guard
          # below exists to prevent: a complete, legal-looking round that
          # happens to seat two players the arbiter separated.
          forbidden_pairs: parsed.tournament[:forbidden_pairs],
          # What a result is WORTH. Omitting this paired every tournament on
          # the standard 1/half/0 system regardless of what the arbiter had
          # configured, so a 3-1-0 event was scored one way and bracketed
          # another. The TRF carries each player's TOTAL, which the engine
          # reconciles, but not the values behind it.
          point_system: Tournament.engine_point_system(tournament)
        ]

        # `engine_opts` verbatim, NOT a second list spelling out the same
        # three keys. They were written out twice and happened to agree; the
        # next option added to one of them would not have, and the failure
        # mode is quiet - `explain_round/3` would describe a pairing that is
        # not the one the arbiter is looking at.
        raw_pairs = Ainalrami.Pairing.pair_next_round(parsed.players, engine_opts)

        # Ground truth, taken while the decision is fresh. `explain_round/3`
        # analyses a pairing it is GIVEN rather than emitting one as it
        # works, so it is a second call - but it is one call per round, on a
        # click the arbiter is already waiting on, not per page view.
        #
        # Deliberately not allowed to fail the round: an explanation is
        # commentary, and losing it must never cost an arbiter a pairing
        # that the engine has already computed correctly.
        explanation =
          try do
            Ainalrami.Pairing.explain_round(parsed.players, raw_pairs, engine_opts)
          rescue
            e ->
              Logger.warning(
                "Ainalrami could not explain #{engine_log_scope(tournament, round_number, category_name)}: #{Exception.message(e)}"
              )

              nil
          end

        {:ok, Enum.map(raw_pairs, &ainalrami_bye_to_zero/1), explanation}

      codes ->
        {:error, ainalrami_unsupported_message(codes, category_name)}
    end
  rescue
    # Ainalrami raises where JaVaFo writes an empty file - a proven
    # structural deadlock, not a search that gave up (see the exception's own
    # doc). Mapped onto the same `{:error, string}` shape so
    # `pair_next_round/1`'s callers, which just render the reason as-is,
    # cannot tell which engine refused.
    e in Ainalrami.Pairing.NoValidPairingError ->
      Logger.error(
        "Ainalrami found no legal pairing for #{engine_log_scope(tournament, round_number, category_name)}: #{Exception.message(e)}"
      )

      {:error,
       ainalrami_scoped(
         "Ainalrami found no legal pairing for this round - every remaining player would have to repeat an opponent or take a forbidden colour. #{Exception.message(e)}",
         category_name
       )}

    # The TRF we just built is our own, so this should be unreachable; it is
    # caught rather than allowed to escape because an unhandled raise here
    # would take down the whole LiveView instead of showing the arbiter a
    # message, and because Ainalrami validates result-code combinations more
    # eagerly than JaVaFo does.
    e in Ainalrami.Trf.ValidationError ->
      Logger.error(
        "Ainalrami rejected the generated TRF for #{engine_log_scope(tournament, round_number, category_name)}: #{Exception.message(e)}"
      )

      {:error,
       ainalrami_scoped(
         "Ainalrami could not read the generated pairing file: #{Exception.message(e)}",
         category_name
       )}
  end

  defp ainalrami_bye_to_zero({white, nil}), do: {white, 0}
  defp ainalrami_bye_to_zero({white, black}), do: {white, black}

  defp ainalrami_scoped(message, nil), do: message
  defp ainalrami_scoped(message, category_name), do: "#{message} (category \"#{category_name}\")"

  # Which TRF extension lines Ainalrami actually reads. All three this app
  # emits, as of ainalrami `451c749`: `XXR` (total rounds), `XXP` (forbidden
  # pairings and club/federation exclusions) and `XXA` (Baku acceleration).
  #
  # `XXP`/`XXA` were added upstream precisely because this integration
  # surfaced their absence. Before that, Ainalrami's parser discarded them as
  # unknown header codes - measured on its own fuzz corpus, a 20% forbidden
  # rate meant 27.72% of rounds seated a pair the arbiter had excluded, and
  # that figure was its ENTIRE disagreement with bbpPairings on that axis.
  # Kept as a list, and kept checked against the generated TRF below, so the
  # next extension this pipeline learns to emit is caught automatically
  # rather than silently ignored by whichever engine is selected.
  @ainalrami_supported_extensions ~w(XXR XXP XXA)

  # The extension codes in `trf` that Ainalrami would ignore. Checked against
  # the generated TRF itself rather than against the tournament's settings,
  # so it stays true by construction: any extension line this pipeline
  # learns to emit in future is caught here without anyone remembering to
  # update a second list.
  #
  # This guard is not tidiness, and it stays even though every extension the
  # app currently emits is now supported. An extension line carries a RULE -
  # `XXP` the arbiter's forbidden pairings, `XXA` the acceleration's virtual
  # points - and an engine that ignores one still returns a complete,
  # entirely legal-looking pairing that just happens to break it. There is
  # nothing downstream that could notice the difference, so refusing to pair
  # is the only safe answer, and it has to be the DEFAULT for anything not
  # explicitly known to work.
  defp ainalrami_unsupported_extensions(trf) do
    trf
    |> String.split(~r/\r?\n/)
    |> Enum.filter(&String.starts_with?(&1, "XX"))
    |> Enum.map(&String.slice(&1, 0, 3))
    |> Enum.reject(&(&1 in @ainalrami_supported_extensions))
    |> Enum.uniq()
  end

  defp ainalrami_unsupported_message(codes, category_name) do
    reasons = Enum.map_join(codes, "; ", &"the TRF extension #{&1}")

    ainalrami_scoped(
      "Ainalrami does not implement #{reasons}. Nothing was paired - Ainalrami would have ignored the rule rather than applied it. Use JaVaFo for this tournament.",
      category_name
    )
  end

  # JaVaFo pairing output: first line = number of pairs, then "white black"
  # per line as TRF starting ranks; 0 = pairing-allocated bye. Returns
  # `{:ok, pairs}`, or `{:error, message}` when the output file is entirely
  # empty - JaVaFo has been observed to exit 0 having written nothing, and
  # the old bare `[_count | lines] = ...` match crashed the whole
  # `pair_next_round/1` call with an opaque MatchError instead of the same
  # tidy `{:error, ...}` shape the nonzero-exit path already returns. A
  # present-but-"0" count line with no pair lines still parses as
  # `{:ok, []}`, exactly as before.
  #
  # `@doc false` and `def` (not `defp`) purely so tests can drive this
  # parsing edge case directly - same precedent as
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
  # (inverse of `local_rank_by_player_id`), NOT global `pairing_number` - see
  # that function's doc comment for why. JaVaFo's output pairs are starting
  # ranks in whatever numbering it was given, so the lookup here must use
  # the exact same map that was fed into `javafo_input/3`.
  ## ---------- the engine's own account of the round ----------

  # Turns what `Ainalrami.Pairing.explain_round/3` reports into something a
  # round row can hold and a page can read years later.
  #
  # Two translations matter. First, RANKS: the engine speaks in the local
  # contiguous numbering the TRF was built in, which is an artefact of who
  # was in the field that day and means nothing once the roster changes.
  # Everything is stored as player ids instead. Second, SHAPE: the report is
  # full of tuples (`{a, b}` pairs, `{label, value}` rungs) and a `:map`
  # column is JSON, where tuples do not exist - so pairs become two-element
  # lists and rungs become labelled maps.
  #
  # Returns nil when no section has anything to report, so a JaVaFo round
  # stores nothing at all rather than an empty husk that reads, to the page,
  # like an explanation that came back blank.
  defp explanation_payload(sections) do
    built =
      sections
      |> Enum.flat_map(fn
        {_category_name, nil, _by_rank} ->
          []

        {category_name, brackets, by_rank} ->
          [
            %{
              "category" => category_name,
              "brackets" => Enum.map(brackets, &bracket_json(&1, by_rank))
            }
          ]
      end)

    case built do
      [] -> nil
      sections -> %{"engine" => "ainalrami", "version" => 1, "sections" => sections}
    end
  end

  defp bracket_json(bracket, by_rank) do
    %{
      "group" => bracket.group,
      "mdps" => player_ids(bracket.mdps, by_rank),
      "residents" => player_ids(bracket.residents, by_rank),
      "floats" => player_ids(bracket.floats, by_rank),
      "pairs" =>
        Enum.map(bracket.pairs, fn {a, b} -> [player_id(a, by_rank), player_id(b, by_rank)] end),
      "edge_count" => Map.get(bracket, :edge_count),
      # Per-board attribution: which pair carries which criterion's cost.
      # The engine reports one rung vector per edge, in `pairs` order and
      # then the cross edges the floats leave on, and the bracket's own
      # rungs are their column-wise sum.
      #
      # The cross edges are kept rather than dropped, tagged "float". They
      # are a lower bracket's boards, so they will appear again there - but
      # without them the per-board rows would not add up to the bracket
      # total sitting right above them, and a reader checking the arithmetic
      # would be right to distrust the whole panel.
      "edges" => edges_json(bracket, by_rank),
      # Only the criteria that actually scored. A bracket reports every rung
      # on the ladder and most are zero; keeping them all would triple the
      # stored size to say "this criterion did not come into it".
      "rungs" =>
        bracket.rungs
        |> Enum.reject(fn {_label, value} -> value == 0 end)
        |> Enum.map(fn {label, value} -> %{"label" => label, "value" => value} end)
    }
  end

  # The six criteria whose value can be read as a verdict about ONE board,
  # kept even when zero because zero is the whole point: every one of these
  # is phrased so that higher is better, so a 0 is the board where something
  # was given up, and a filtered-out 0 is indistinguishable from a criterion
  # the engine never reported.
  #
  # The rest of the ladder is deliberately NOT in here. C7, C8 and C19-C21
  # are score-scale magnitudes the matcher ranks candidates by, not
  # statements about a board, and C14/C16 REWARD pairing a recent
  # downfloater rather than penalising anything - a zero there means this
  # board did not happen to pair one, which is not a compromise and must
  # never be rendered as one.
  @board_verdicts [
    "C10 topscorer colour diff",
    "C11 topscorer same colour x3",
    "C12 colour preference",
    "C13 strong colour preference",
    "C15 upfloat repeat r-1",
    "C17 upfloat repeat r-2"
  ]

  defp edges_json(bracket, by_rank) do
    kept = length(bracket.pairs)

    bracket
    |> Map.get(:edge_rungs, [])
    |> Enum.with_index()
    |> Enum.map(fn {{{a, b}, rungs}, index} ->
      %{
        "players" => [player_id(a, by_rank), player_id(b, by_rank)],
        "kind" => if(index < kept, do: "pair", else: "float"),
        "rungs" =>
          rungs
          |> Enum.filter(fn {label, value} -> value != 0 or label in @board_verdicts end)
          |> Enum.map(fn {label, value} -> %{"label" => label, "value" => value} end)
      }
    end)
  end

  defp player_ids(ranks, by_rank), do: Enum.map(ranks, &player_id(&1, by_rank))

  # A rank with no player behind it should be impossible - the map is built
  # over the same roster the TRF was - but a nil here would be a crash on a
  # page rendering an explanation, so an unknown rank is simply dropped from
  # the account rather than taking the page down with it.
  defp player_id(0, _by_rank), do: nil

  defp player_id(rank, by_rank) do
    case Map.get(by_rank, rank) do
      nil -> nil
      player -> player.id
    end
  end

  defp create_round(
         pairs,
         tournament,
         player_by_local_rank,
         next_number,
         round_absentees,
         explanation
       ) do
    pairing_allocated_bye? = Enum.any?(pairs, fn {_w, b} -> b == 0 end)

    Repo.transaction(fn ->
      round =
        Repo.insert!(%Round{
          tournament_id: tournament.id,
          number: next_number,
          status: "playing",
          published_at: Tournaments.compute_published_at(tournament, next_number),
          explanation: explanation
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
      # through Tournaments.update_pairing_result/2 - the same
      # point-changing-write gap as insert_round_absentee_byes/3 above. See
      # docs/manual-standings.md (Fix 3).
      if pairing_allocated_bye?, do: Tournaments.invalidate_manual_ranking(tournament.id)

      Tournaments.freeze_round_display_boards!(round.id)

      if tournament.swiss_match_format do
        create_mirrored_leg(tournament, leg1_pairings, round_absentees, next_number + 1)
      else
        round
      end
    end)
  end

  # `swiss_match_format`'s second leg: same match, same boards, colours
  # reversed - an exact mirror of leg 1's freshly-inserted pairings, built
  # from Elixir data (no second JaVaFo call, no new TRF file). See the
  # field's doc comment on PairingsEngine.Tournaments.Tournament and the
  # module doc above `do_pair/2`.
  #
  # No extra `Tournaments.invalidate_manual_ranking/1` call is needed here:
  # every bye-type row leg 2 introduces (pairing-allocated or
  # requested-zero) is a mirror of a leg-1 event that already triggered its
  # own invalidation call above (pairing-allocated) or in
  # `insert_round_absentee_byes/3` (requested-zero, called by `do_pair/2`
  # before this transaction even starts) - `manual_ranking_stale` is a
  # single boolean flag, not per-round, so re-firing it for the mirrored
  # row would be a harmless but redundant broadcast-adjacent write.
  defp create_mirrored_leg(tournament, leg1_pairings, round_absentees, leg2_number) do
    leg2 =
      Repo.insert!(%Round{
        tournament_id: tournament.id,
        number: leg2_number,
        status: "playing",
        published_at: Tournaments.compute_published_at(tournament, leg2_number)
      })

    Enum.each(leg1_pairings, fn p ->
      {white_id, black_id} =
        if p.black_player_id do
          # Ordinary pairing - same board, colours swapped.
          {p.black_player_id, p.white_player_id}
        else
          # Pairing-allocated bye - no colour to swap, same player earns
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

    # Round-specific absentees sit out both legs identically - see the
    # module doc above `do_pair/2` for the deliberate scope limitation
    # (leg 2's absentee set is leg 1's, not independently re-evaluated).
    unless round_absentees == [] do
      rows =
        Enum.map(round_absentees, fn player ->
          %{
            tournament_id: tournament.id,
            player_id: player.id,
            round: leg2_number,
            type: "absent"
          }
        end)

      Repo.insert_all("byes", rows, on_conflict: :nothing)
    end

    Tournaments.freeze_round_display_boards!(leg2.id)

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
  `pairing_number` range - an absent player excluded from THIS round only,
  not from the tournament's frozen numbering - never reaches JaVaFo as a gap
  in the TRF's starting-rank sequence, which is confirmed to crash it with a
  bare NullPointerException. See the `do_pair_single/4` doc comment for the
  full story.

  `eligible_ids`, when given, is a `MapSet` of the player ids that are
  actual pairing candidates for the round about to be paired. Every other
  player in `players` gets a `0000 - Z` line appended via
  `mark_ineligible_for_round/2` instead - the JaVaFo-native way to keep a
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
        # `remap_trf_rows_to_local_ranks/2` only rewrites each row's `:rank`
        # field - it preserves `trf_players`' own list order (still whatever
        # `trf_player_rows/3` sorted by, the player's raw `pairing_number`).
        # `Trf.serialize/1` writes rows in list order verbatim, with no sort
        # of its own - so without this re-sort, the TRF's PHYSICAL row order
        # stays pairing_number-based even when the caller asked for a
        # different (e.g. current-standings) rank assignment via
        # `rank_by_player_id`. JaVaFo's Dutch-system pairing engine expects
        # its input in current-standings order (score desc, then rating
        # desc) - when a score bracket has more than one structurally-equal
        # way to pair, it falls back to input order as an implicit
        # tie-break, so a mismatched physical order can produce a
        # genuinely different (each still locally "valid") pairing.
        # Confirmed against a real tournament: SWAR (which also runs
        # JaVaFo, always re-sorting into standings order first) produced a
        # different round-2 pairing than this app from identical round-1
        # data; rebuilding the TRF input in standings order reproduced
        # SWAR's pairing exactly. See `do_pair_single/4`'s
        # `local_rank_by_player_id` for where that order is decided.
        trf_players
        |> remap_trf_rows_to_local_ranks(rank_by_player_id)
        |> Enum.sort_by(& &1.rank)
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

    # XXR: total number of rounds - required by JaVaFo to plan the pairing.
    trf = trf <> "XXR #{tournament.rounds_count}\r\n"

    # XXA: Baku acceleration virtual points (see acceleration_lines/4) - must
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
    # docs/forbidden-pairings.md) - JaVaFo's TRF extension for "these
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
  been assigned a `pairing_number` yet - JaVaFo only needs to hear about
  players it's actually being asked to pair.

  `rank_by_player_id` defaults to `players`' own global `pairing_number`
  (every existing caller's behaviour, unaffected). Per-category Swiss
  pairing (`do_pair_by_category/3`) passes a category's local 1..M rank map
  instead - a pair naming a player outside the category (which can't
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
  skipped - JaVaFo doesn't need to hear the same rule twice - as is any pair
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
  FIDE C.04.7 Baku Acceleration - JaVaFo's own "acceleration" TRF
  extension. Returns `""` unless `tournament.acceleration == "baku"` *and*
  `tournament.pairing_system == "swiss"`: round robin's fixed Berger
  schedule ignores acceleration entirely, and Keizer never goes through
  JaVaFo at all.

  ## Verified mechanism (do not re-guess this - see below)

  Per the JaVaFo 2.2 Advanced User Manual
  (rrweb.org/javafo/aum/JaVaFo2_AUM.htm): JaVaFo does **not** compute Baku
  acceleration on its own from a single flag. Its own words: *"JaVaFo can be
  informed of the fictitious points that are assigned to each player, using
  the extension code XXA"* and *"It is mandatory to keep the full record of
  the fictitious points assigned round by round, because this record is
  used to determine the floaters history of each player"*. So **we**
  compute every Group-A player's virtual points for every round played so
  far ourselves, straight from the FIDE C.04.7 text, and hand JaVaFo the
  full history - one column per round.

  The manual's format spec: `"XXA NNNN pp.p pp.p ..."`, where `XXA` starts
  at column 1, `NNNN` (the player's starting rank) starts at column 5, and
  each `pp.p` starts at column `10 + 5*(r-1)` (`r` = round). This is a
  **fixed-column** format, unlike this file's other free-form `XXR`/`XXP`
  extension lines - confirmed by direct experiment against the real
  `javafo.jar`: a free-form space-separated `"XXA 1 1.0 1.0\\r\\n"` line
  crashes JaVaFo with a bare `NullPointerException`
  (`B.A.B.D.J`/`B.A.B.I.K`/...), while the fixed-column form below runs
  clean. The same experiment (8 players, round 2, Group A = ranks 1-4 given
  a flat +1.0/+1.0 virtual-point history) also confirmed the values are not
  silently ignored: JaVaFo's round-2 pairing genuinely changed shape between
  the unaccelerated and accelerated runs, matching the FIDE description
  (Group-A players effectively face each other/tougher opposition sooner)
  - see `PairingsEngine.PairingTest` for the same assertion as an
  automated, `:javafo`-tagged end-to-end test.

  ## FIDE C.04.7 Baku Acceleration, as implemented here

  Group A (the group that receives virtual points) is the top half of the
  field by starting rank (`pairing_number`), rounded up to the nearest even
  number of players - FIDE's `2 * ceil(n/4)` - computed once from the
  *whole* roster passed in (not just this round's active subset), since
  starting rank is frozen for the tournament. Group B never receives
  points.

  "Accelerated rounds" are the first `ceil(rounds_count/2)` rounds. Within
  those, Group A gets 1.0 virtual point per round for the first half
  (rounded up) of the accelerated span, then 0.5 for the remainder, then 0
  forever after - this is the FIDE worked example verbatim: *"In a
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
    # GLOBAL starting rank (frozen for the tournament) - deliberately
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
      # local rank, not global pairing_number - the XXA line's rank column
      # must match that same numbering, or it silently references a rank
      # that doesn't exist in this run's TRF16 player list. A Group-A player
      # not in `rank_by_player_id` at all (excluded from THIS run's pool -
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
  # cols 5-8, then one right-aligned pp.p per round, 4 columns wide on a
  # 5-column stride from col 10 - the JaVaFo AUM's column spec. Free-form
  # space-separated XXA crashes JaVaFo (verified), unlike this file's other
  # XXR/XXP extension lines.
  #
  # The rank field used to be padded to FIVE, which put a single-digit rank
  # in col 9 and left cols 5-8 blank. JaVaFo accepts that, which is why it
  # went unnoticed for as long as JaVaFo was the only reader - but it is not
  # what the AUM specifies, and a stricter parser rejects the line outright.
  # Confirmed against the real bbpPairings binary, which reads the rank from
  # exactly `line[4]..line[8]` and each value as 4 chars from index 9 on a
  # stride of 5 (`readPlayerAccelerationsXxa`, trf.cpp:485-515): our old
  # output produced `Error parsing file: Invalid line "XXA     1  1.0  1.0"`,
  # i.e. every accelerated tournament this app exported was unreadable by
  # anything but JaVaFo. Found by pointing a second engine at our own TRF,
  # which is precisely the class of bug a second engine exists to catch.
  defp xxa_line(rank, points) do
    id_field = String.pad_leading(to_string(rank), 4)

    points_fields =
      Enum.map_join(points, " ", fn p ->
        String.pad_leading(:erlang.float_to_binary(p / 1, decimals: 1), 4)
      end)

    "XXA " <> id_field <> " " <> points_fields <> "\r\n"
  end

  defp ceil_div(a, b), do: div(a + b - 1, b)

  @doc """
  Builds the `PairingsEngine.Trf.serialize/1`-shaped player list (rank,
  identity fields, points, full-history games) for `players`, covering every
  paired round of `tournament` with no filtering. Shared by `javafo_input/2`
  (active players only, feeding the pairing engine) and
  `PairingsEngine.TrfExport` (the full roster, for the user-facing TRF
  download, which additionally trims each player's `:games` down to a
  chosen round subset - see that module).

  Players without a `pairing_number` yet (never included in a paired round)
  are dropped: TRF16 requires every player row to carry a numeric starting
  rank, and a player who was never actually paired has nothing meaningful
  to report anyway.

  Each row also carries an `:id` (the player's id) and each game an
  `:opponent_id` alongside the usual `:opponent_rank` - extra keys
  `PairingsEngine.Trf.serialize/1` and `PairingsEngine.TrfExport` both
  ignore (they only read the specific keys they need), but that
  per-category Swiss pairing's `remap_trf_rows_to_local_ranks/2` uses to
  translate global `pairing_number`-based ranks to a category's own local
  numbering - see `build_category_trf/5`.

  `shared_history`, when given, is a precomputed `build_shared_history/1`
  result - passed by `do_pair_by_category/3` so every category's call
  reuses the same tournament-wide query results instead of each one
  re-fetching identical data (see `games_per_player/2`). `nil` (every
  other caller) means "compute it fresh" - the original, unchanged
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
        # TRF16 is a FIDE report - always the FIDE rating, never a fallback
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

  @doc """
  Sums `games` into the score that goes in TRF columns 81-84, per
  `tournament`'s point values.

  That number is not decoration: it is what a pairing engine reads to decide
  which score bracket a player belongs in. It therefore has to equal what
  `PairingsEngine.Standings` puts in the crosstable, and for a long time it
  did not.

  Two ways it drifted. The result codes were matched by hand and everything
  unlisted fell through to `points_loss`, which silently swallowed `W` and
  `D` - a game that was PLAYED but is not rated, worth exactly what its
  rated twin is worth. An unrated win was banked as a zero, so the engine
  put that player a full point too low and paired them against the wrong
  people, while the crosstable next to it showed the point.

  And a bye was scored from its TRF LETTER rather than from what it was. The
  letter cannot carry the difference: `Z` is written both for a requested
  zero-point bye and for an absence, and an absence may be worth `abs_value`
  - half a point in most clubs that use it, capped by round and by count.
  Scoring the letter paid every absence `points_loss`, so exactly the
  tournaments that configure a half-point absence had a file disagreeing
  with their own standings.

  The rows built by `games_per_player/2` carry `points_kind` (the bye's real
  type) and `round`, so a bye is now scored by `Standings.bye_points/4` -
  the same function the crosstable calls, rather than a second opinion about
  the same rule. `cumulative_absences` is counted along the list instead of
  re-queried; the list is one entry per round in round order, which is what
  makes that equivalent.
  """
  def player_points(games, t) do
    {points, _absences} =
      Enum.reduce(games, {0.0, 0}, fn g, {sum, absences} ->
        absences = if Map.get(g, :points_kind) == "absent", do: absences + 1, else: absences
        {sum + game_points(g, t, absences), absences}
      end)

    points
  end

  # The bye kinds, and ONLY those. `points_kind` is also set to "game" on a
  # played board, and matching on the key alone sent every real game to
  # `bye_points/4`'s catch-all and scored the whole tournament as zeroes.
  # Listing the kinds rather than excluding "game" means a kind added later
  # falls back to the result code - today's behaviour - instead of silently
  # becoming a loss.
  @bye_kinds ~w(requested-half requested-zero absent pairing-allocated zero)

  # A bye knows what kind it is; ask the crosstable's own rule.
  defp game_points(%{points_kind: kind} = g, t, absences) when kind in @bye_kinds,
    do: Standings.bye_points(kind, t, Map.get(g, :round), absences)

  # Anything else is a game with a result code. `W`/`D`/`L` are TRF16's
  # letter spellings of `1`/`=`/`0` for a played but unrated game and belong
  # with their twins, not in the catch-all.
  defp game_points(g, t, _absences) do
    case g.result do
      r when r in ~w(1 + F W) -> t.points_win
      "U" -> t.bye_value
      r when r in ~w(= H D) -> t.points_draw
      _ -> t.points_loss
    end
  end

  # Orders `players` the way JaVaFo's Dutch-system engine expects its input:
  # current standings, score descending then rating descending - NOT
  # `pairing_number` (a fixed, initial-seed order `full_roster_players/1`'s
  # own DB query returns, correct for a downloadable/archival TRF file per
  # the TRF16 convention, but wrong for feeding a live pairing run). See the
  # re-sort in `javafo_input/4` for the other half of this fix (physical row
  # order in the generated TRF) and its full rationale.
  #
  # `shared_history`, when given, avoids re-querying rounds/byes/roster
  # `games_per_player/2` already fetched once for this pairing run - same
  # sharing `do_pair_by_category/3` already does elsewhere.
  # Feeds JaVaFo current-standings order (score desc, then rating desc -
  # see this function's own commit history for why that matters at all).
  # `pairing_number` as a third key is the fix a real SWAR export
  # comparison surfaced: two players tied on BOTH score and rating had no
  # tie-break here at all, so `Enum.sort_by/2`'s stability silently fell
  # through to whichever order the INPUT list happened to already be in.
  # For round 2+ that input is `build_shared_history/1`'s `full_roster`
  # `Map.values/1` - an unordered map with no `order_by` on its own
  # query - so the fallback order was essentially DB id / insertion
  # order: not wrong by any rule, but not a rule either, and not
  # reproducible the way a tie-break needs to be.
  #
  # Found by pairing the same real, in-progress tournament twice: once
  # live in OpenPairings, once by exporting to `.swar` (see
  # `PairingsEngine.SwarExport`) and continuing it in a real SWAR
  # install. 57 of 61 round-7 boards matched exactly; the 4 that didn't
  # were two clusters of players tied on BOTH score and rating (one pair
  # unrated 0 vs 0, one pair rated 1775 vs 1775) - precisely the case
  # this function left undefined. `SwarExport`'s own tie-break for the
  # identical situation is deliberately name-based (matching what real
  # SWAR does - see `SwarExport.assign_ranks/1`), which is principled but
  # different from whatever this function's silent fallback happened to
  # produce; two different-but-plausible tie-breaks for the same
  # genuinely-tied pair is exactly what a criss-cross mismatch looks
  # like. `pairing_number` is FIDE's own prescribed fallback (the
  # starting rank number, Art. 1.14) once score and rating are both
  # exhausted, so it's the fix here - not name, to keep this engine's own
  # rule independent of anyone's SWAR-export tie-break choice.
  defp order_for_pairing(players, tournament, shared_history \\ nil) do
    by_id = Map.new(players, &{&1.id, &1})
    games = games_per_player(tournament, by_id, shared_history)

    Enum.sort_by(players, fn p ->
      points = player_points(Map.get(games, p.id, []), tournament)
      {-points, -Player.rating(p), p.pairing_number}
    end)
  end

  # Every player who ever received a pairing_number, regardless of current
  # active/absent/forfeit/withdrawn status - the full frozen roster. Used to
  # scope the local rank map fed to JaVaFo (see `do_pair_single/4` and
  # `build_category_trf/5`): every possible historical opponent must resolve
  # to a real rank with a real row in the TRF, or `remap_trf_rows_to_local_ranks/2`
  # silently destroys that game's colour history - see that function's doc.
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
  the full pool `ensure_pairing_numbers/2` freezes numbers over - round-
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
  Players on the roster who are marked absent for the whole tournament.

  The exact complement of `active_players/1` on the `absent` flag, and
  deliberately still excluding `forfeit`: a forfeited player's rounds are
  scored as forfeit losses on their boards, not as absences, and paying
  them an absence award as well would count the same round twice.
  """
  def absent_players(tournament_id) do
    Repo.all(
      from p in Player,
        where:
          p.tournament_id == ^tournament_id and p.status == "active" and
            p.absent == true and p.forfeit == false
    )
  end

  @doc """
  Players eligible to be paired for `round_number`: active, not permanently
  absent/forfeited (see `active_players/1`), not requesting an absence for
  this specific round via `absent_rounds` (SWAR "Absent at the rounds
  x,y,z"), and not a late entrant whose `start_round` hasn't been reached
  yet (Keizer). Pure with respect to round-specific filtering - safe to
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

  @doc "True if `player.start_round` is set and later than `round_number` - a late entrant not yet eligible to be paired."
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
  # set - e.g. `active_players/1`'s result, or a category's local group for
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
  # `%{rounds:, bye_map:, full_roster:}` (see `build_shared_history/1`) -
  # reused as-is instead of re-querying. This is tournament-wide data that
  # doesn't depend on `by_id` at all, so per-category Swiss pairing
  # (`do_pair_by_category/3`) computes it ONCE and threads it through every
  # category's `trf_player_rows/3` call, rather than re-running the same
  # three queries once per category (confirmed identical data every time -
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
                points_kind: bye_type,
                # For `abs_jusque` - SWAR's "pay an absence only up to round
                # N". `player_points/2` reads it; nothing serialises it.
                round: round.number
              }

            true ->
              %{
                opponent_rank: nil,
                opponent_id: nil,
                colour: nil,
                result: "Z",
                points_kind: "zero",
                round: round.number
              }
          end
        end)

      {player_id, games}
    end
  end

  # The three tournament-wide queries `games_per_player/2` needs, bundled
  # so they can be run ONCE and reused across multiple calls (see that
  # function's doc) - none of this depends on which players a particular
  # call is building rows for.
  #
  #   * `rounds` - every paired Round with its pairings preloaded.
  #   * `bye_map` - every `"byes"`-table row for the tournament, keyed by
  #     `{player_id, round}`.
  #   * `full_roster` - every player who ever received a `pairing_number`,
  #     the widest set a HISTORICAL opponent could possibly be (a player
  #     never actually paired has nothing meaningful to report anyway,
  #     mirroring `trf_player_rows/2`'s own tolerance rule) - deliberately
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
    # currently being paired - a past opponent may since have gone
    # absent/forfeited and dropped out of that narrower set, but the game
    # they played is still real and its rank must still resolve. See
    # `games_per_player/2`.
    opponent = opponent_id && Map.get(full_roster, opponent_id)

    # Played games use TRF codes 1/0/= ; forfeits use + (win) / - (loss),
    # per FIDE Art. 16 both sides of a forfeit count as unplayed. A played
    # "0-0" (both players lose, e.g. both defaulted after making moves) is
    # code '0' for BOTH sides - distinct from a "0-0FF" double forfeit,
    # which is '-' for both. "1/2-0"/"0-1/2" (VCL.13's asymmetric result) is
    # '=' for the ½ side and '0' for the 0 side - the one case where the two
    # sides' TRF codes deliberately don't mirror each other, since the TRF16
    # spec has no dedicated code for it. "+--"/"--+" are the legacy forfeit
    # notation, kept for historical/SWAR-imported data (see
    # PairingsEngine.Tournaments.Pairing).
    result =
      case {pairing.result, white?} do
        {"bye", _} -> "U"
        {"1-0", true} -> "1"
        {"1-0", false} -> "0"
        {"0-1", true} -> "0"
        {"0-1", false} -> "1"
        {"1/2-1/2", _} -> "="
        {"1/2-0", true} -> "="
        {"1/2-0", false} -> "0"
        {"0-1/2", true} -> "0"
        {"0-1/2", false} -> "="
        {"1-0FF", true} -> "+"
        {"1-0FF", false} -> "-"
        {"0-1FF", true} -> "-"
        {"0-1FF", false} -> "+"
        {"0-0FF", _} -> "-"
        {"0-0", _} -> "0"
        # Unrated but PLAYED: W/D/L are the rated codes' twins, and every
        # pairing rule treats them as contested games.
        {"1-0U", true} -> "W"
        {"1-0U", false} -> "L"
        {"0-1U", true} -> "L"
        {"0-1U", false} -> "W"
        {"1/2-1/2U", _} -> "D"
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
  # (F/H/Z/U) - never a played-game code (1/=/0/+/-). Reported bug: a
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
      # `W`/`D`/`L` are TRF16's unrated twins of `1`/`=`/`0` and belong with
      # them. They were missing until 2026-08-26, so an opponentless unrated
      # result stayed a playing code with a nil opponent - precisely the
      # combination this function exists to make impossible.
      #
      # It did not degrade quietly: `Trf.validate_games!/2` raises on it, and
      # the raise happens while BUILDING the file, before `run_engine/5` is
      # called - so `run_ainalrami/4`'s ValidationError rescue could not see
      # it either. It escaped `pair_next_round/1` as an exception instead of
      # the `{:error, message}` every other refusal here returns, and took
      # the FIDE download down the same way.
      code when code in ["1", "+", "W"] -> "F"
      code when code in ["=", "D"] -> "H"
      code when code in ["0", "-", "L"] -> "Z"
      other -> other
    end
  end

  defp bye_code("requested-half"), do: "H"
  defp bye_code("requested-zero"), do: "Z"
  defp bye_code("absent"), do: "Z"
  defp bye_code("pairing-allocated"), do: "U"
  defp bye_code(_), do: "Z"
end
