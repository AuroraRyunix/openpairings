defmodule PairingsEngine.TeamFlowValidationTest do
  @moduledoc """
  End-to-end validation of a TEAM tournament: teams and rosters -> pairing
  -> board results -> "Send" -> TRF for rating. The team engine itself is
  proven elsewhere (Ainalrami's whole-round references); this is the app
  path around it, the same lesson as the Baku order bug.

  Every event is driven only through the app's own context functions (the
  calls the LiveViews and the Export page make): `create_tournament/1`,
  `create_team/2`, `create_player/2`, `set_player_team/3`,
  `move_player_board/3`, `move_team/3`, `seed_teams_by_rating/1`,
  `update_player/2` (absences, withdrawals), `Pairing.pair_next_round/2`
  (team Swiss) and `RoundRobin.pair_all_rounds/1` (team round robin, the
  Pairings page's one click), `update_pairing_result/3`,
  `TeamMatches.forfeit_match/3` / `withdraw_forfeit/2`,
  `PostponedGames.send_rounds/4` with `TrfExport.export/2`, and
  `PostponedGames.send_late_games/3` with `TrfExport.postponed_export/2`.

  Generated: team Swiss (C.04.6) with 4-40 teams and team round robin
  (single and double) with 4-12, 2-8 boards, rosters with reserves, teams
  with too few players (board forfeits), players unavailable for rounds,
  late reserves and late teams (Swiss), withdrawals (a player, or a whole
  team), forfeits by decision (before and after play, sometimes withdrawn),
  board forfeits, unrated games, postponed games, odd fields (the team PAB,
  the Berger bye), several match-point systems and every initial colour.

  Checked, with this file's own fixed-column reading - never the app's
  builder:

    * every sent file: every stored board on both lines (opponent, colour,
      code), a seat only one team filled as the point without a game,
      nothing else; both sides mirror; the points column adds up from the
      file's `162`; `062`/`072`/`082`/`092`/`132`/`192`/`362`; one `310`
      per team listing exactly the file's players of that team, in roster
      order, every player who sat for the team in the file's rounds, its
      MP/GP adding up from the file; `320` naming the round's bye team;
    * across ALL files: every rated game exactly once, every late game
      once, resends refused;
    * the database: board colours alternate (the first team White on odd
      boards), board numbers run on through the round, each team's lineup
      is its roster in board order minus who could not play, cut to the
      match size; in a Swiss exactly the teams able to field a player are
      paired;
    * the team engine's input for every Swiss round (captured by swapping
      the app's `:team_pairing_module` for a recorder) against the history
      rebuilt from the final report: field, absent teams, MP, GP,
      opponents, colours, had the bye, won by forfeit, floated;
    * `ainalrami -c` on the full report, exit 0: a team Swiss re-paired
      round by round, a team round robin compared with the Berger tables,
      and the standings re-ranked.

  TEAM_FLOW_COUNT (unset: skipped), TEAM_FLOW_FIRST, TEAM_FLOW_DUMP=dir.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox

  alias PairingsEngine.{
    Pairing,
    PostponedGames,
    Repo,
    RoundRobin,
    TeamMatches,
    Tournaments,
    TrfExport
  }

  alias PairingsEngine.Tournaments.Match

  @moduletag :team_flow
  @moduletag capture_log: true

  if System.get_env("TEAM_FLOW_COUNT") in [nil, ""] do
    @moduletag skip: "set TEAM_FLOW_COUNT to run"
  end

  defmodule Recorder do
    @moduledoc false
    # Stands in for `Ainalrami.TeamPairing` (`:team_pairing_module`): keeps
    # what the app handed the engine for the round, then pairs exactly as
    # the engine would.
    def pair_round(teams, opts) do
      Process.put({:team_engine_input, Keyword.get(opts, :round)}, %{teams: teams, opts: opts})
      Ainalrami.TeamPairing.pair_round(teams, opts)
    end
  end

  setup do
    previous = Application.get_env(:pairings_engine, :team_pairing_module)
    Application.put_env(:pairings_engine, :team_pairing_module, Recorder)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:pairings_engine, :team_pairing_module, previous),
        else: Application.delete_env(:pairings_engine, :team_pairing_module)
    end)
  end

  @tag timeout: :infinity
  test "every team event's files say exactly what the tournament holds" do
    first = env_int("TEAM_FLOW_FIRST", 1)
    count = env_int("TEAM_FLOW_COUNT", 5)
    dump = System.get_env("TEAM_FLOW_DUMP")
    if dump, do: File.mkdir_p!(dump)

    results =
      for seed <- first..(first + count - 1) do
        fn -> run_seed(seed, dump) end |> Task.async() |> Task.await(:infinity)
      end

    totals =
      Enum.reduce(results, %{}, fn r, acc -> Map.merge(acc, r.stats, fn _, a, b -> a + b end) end)

    failures = Enum.flat_map(results, & &1.failures)

    if dump, do: File.write!(Path.join(dump, "failures.txt"), Enum.join(failures, "\n"))

    IO.puts(
      "\nTEAMFLOW events=#{count} " <>
        Enum.map_join(Enum.sort(totals), " ", fn {k, v} -> "#{k}=#{v}" end) <>
        " failures=#{length(failures)}"
    )

    assert failures == [], Enum.join(Enum.take(failures, 5), "\n\n")
  end

  defp env_int(name, default) do
    case Integer.parse(System.get_env(name) || "") do
      {v, ""} -> v
      _ -> default
    end
  end

  defp chance(pct), do: :rand.uniform(100) <= pct
  defp between(lo, hi) when hi <= lo, do: lo
  defp between(lo, hi), do: lo + :rand.uniform(hi - lo + 1) - 1

  ## ---------- one event ----------

  defp run_seed(seed, dump) do
    owner = Sandbox.start_owner!(Repo, shared: false, ownership_timeout: 3_600_000)

    try do
      :rand.seed(:exsss, {seed, seed * 7919, seed * 104_729})
      st = play(seed)
      st = validate(st, dump)
      %{stats: st.stats, failures: st.failures}
    rescue
      e ->
        %{
          stats: %{crashed: 1},
          failures: ["seed #{seed}: crashed\n" <> Exception.format(:error, e, __STACKTRACE__)]
        }
    after
      Sandbox.stop_owner(owner)
    end
  end

  # Match points {win, draw, loss}; FIDE's 2/1/0 most of the time.
  @mp_systems [
    {2.0, 1.0, 0.0},
    {2.0, 1.0, 0.0},
    {2.0, 1.0, 0.0},
    {3.0, 1.0, 0.0},
    {1.0, 0.5, 0.0}
  ]

  defp play(seed) do
    kind = if chance(65), do: :swiss, else: :rr
    boards = between(2, 8)

    n =
      case kind do
        :swiss -> Enum.random([between(4, 8), between(4, 14), between(9, 40)])
        :rr -> between(4, 12)
      end

    cycles = if kind == :rr and chance(20), do: 2, else: 1

    rounds =
      case kind do
        :swiss -> between(3, min(9, n - 1))
        :rr -> if(rem(n, 2) == 0, do: n - 1, else: n) * cycles
      end

    {mw, md, ml} = Enum.random(@mp_systems)
    {win, draw, loss} = if chance(90), do: {1.0, 0.5, 0.0}, else: {2.0, 1.0, 0.0}
    postponed? = chance(30)
    colour = Enum.random(~w(lot lot white black))

    start = Date.new!(2026, 8, between(1, 28))
    dates = for r <- 1..rounds, do: Date.add(start, (r - 1) * between(1, 8))

    {:ok, t} =
      Tournaments.create_tournament(%{
        "name" => "TeamFlow #{seed}",
        "type" => if(kind == :swiss, do: "team-swiss", else: "team-roundrobin"),
        "pairing_system" => if(kind == :swiss, do: "swiss", else: "round_robin"),
        "rr_cycles" => cycles,
        "city" => "Pelt",
        "federation" => "BEL",
        "chief_arbiter" => "Arbiter, Test",
        "rounds_count" => rounds,
        "pairing_engine" => "ainalrami",
        "team_boards" => boards,
        "team_match_points_win" => mw,
        "team_match_points_draw" => md,
        "team_match_points_loss" => ml,
        "points_win" => win,
        "points_draw" => draw,
        "points_loss" => loss,
        "bye_value" => win,
        "initial_colour" => colour,
        "postponed_games" => postponed?,
        "start_date" => Date.to_iso8601(hd(dates)),
        "end_date" => Date.to_iso8601(List.last(dates)),
        "round_dates" => Enum.map(dates, &Date.to_iso8601/1),
        "fide_tournament_id" => "#{800_000 + seed}"
      })

    st = %{
      seed: seed,
      tid: t.id,
      kind: kind,
      rounds: rounds,
      boards: boards,
      dates: dates,
      postponed?: postponed?,
      next_team: 1,
      next_player: 1,
      # team id => player ids, board order as this test keeps it
      roster: %{},
      team_order: [],
      # player id => %{start: r, absent: MapSet, withdrawn_from: r | nil}
      avail: %{},
      lineups: %{},
      open_at_pair: %{},
      paired_rounds: [],
      sent_files: [],
      late_files: [],
      stats: %{"kind_#{kind}": 1},
      failures: []
    }

    st = Enum.reduce(1..n, st, fn _, acc -> add_team(acc, 1) end)
    st = shuffle_boards(st)
    st = seed_teams(st)

    send_after = Enum.take_random(1..rounds, between(1, 3)) |> Enum.sort()

    st =
      case kind do
        :swiss -> play_swiss(st, send_after)
        :rr -> play_rr(st, send_after)
      end

    st = play_late_games(st, :all)
    send_late(st)
  end

  defp tournament(st), do: Tournaments.get_tournament!(st.tid)

  defp bump(st, key, by \\ 1), do: %{st | stats: Map.update(st.stats, key, by, &(&1 + by))}

  defp fail(st, message) do
    %{st | failures: st.failures ++ ["seed #{st.seed}: " <> message]} |> bump(:failed)
  end

  ## ---------- teams and players ----------

  defp add_team(st, start_round) do
    k = st.next_team
    {:ok, team} = Tournaments.create_team(tournament(st), %{"name" => "Team #{k} S#{st.seed}"})

    # Mostly a full side with reserves; now and then too few players.
    size =
      if chance(10),
        do: between(1, max(st.boards - 1, 1)),
        else: st.boards + between(0, 3)

    st = %{st | next_team: k + 1, roster: Map.put(st.roster, team.id, [])}
    st = %{st | team_order: st.team_order ++ [team.id]}
    Enum.reduce(1..size, st, fn _, acc -> add_player(acc, team.id, start_round) end)
  end

  defp add_player(st, team_id, start_round) do
    i = st.next_player
    fide = if chance(10), do: 0, else: between(1200, 2600)

    {:ok, p} =
      Tournaments.create_player(st.tid, %{
        "name" => "Player#{i}, S#{st.seed}",
        "fide_rating" => fide,
        "fide_id" => if(chance(85), do: 20_000_000 + st.seed * 1000 + i),
        "federation" => Enum.random(~w(BEL BEL NED FRA)),
        "sex" => Enum.random(~w(m m w)),
        "birth_year" => between(1950, 2015),
        "start_round" => start_round
      })

    team = Tournaments.get_team(st.tid, team_id)
    {:ok, _} = Tournaments.set_player_team(tournament(st), p, team)

    %{
      st
      | next_player: i + 1,
        roster: Map.update!(st.roster, team_id, &(&1 ++ [p.id])),
        avail:
          Map.put(st.avail, p.id, %{start: start_round, absent: MapSet.new(), withdrawn_from: nil})
    }
  end

  # The Teams page's arrows, before round 1.
  defp shuffle_boards(st) do
    Enum.reduce(st.roster, st, fn {team_id, _}, acc ->
      if chance(50) do
        Enum.reduce(1..between(1, 3), acc, fn _, acc2 ->
          ids = acc2.roster[team_id]
          id = Enum.random(ids)
          dir = Enum.random([:up, :down])
          p = Tournaments.get_player(acc2.tid, id)
          {:ok, _} = Tournaments.move_player_board(tournament(acc2), p, dir)
          i = Enum.find_index(ids, &(&1 == id))
          j = if dir == :up, do: i - 1, else: i + 1

          ids =
            if j < 0 or j >= length(ids),
              do: ids,
              else: ids |> List.replace_at(i, Enum.at(ids, j)) |> List.replace_at(j, id)

          %{acc2 | roster: Map.put(acc2.roster, team_id, ids)}
        end)
      else
        acc
      end
    end)
  end

  defp seed_teams(st) do
    cond do
      chance(40) ->
        {:ok, _} = Tournaments.seed_teams_by_rating(tournament(st))
        bump(st, :seeded_by_rating)

      chance(50) ->
        Enum.each(1..between(1, 4), fn _ ->
          team = Enum.random(Tournaments.list_teams(st.tid))
          {:ok, _} = Tournaments.move_team(tournament(st), team, Enum.random([:up, :down]))
        end)

        bump(st, :seeded_by_hand)

      true ->
        st
    end
  end

  defp available?(st, id, r) do
    a = Map.fetch!(st.avail, id)

    a.start <= r and not MapSet.member?(a.absent, r) and
      (a.withdrawn_from == nil or a.withdrawn_from > r)
  end

  defp lineup(st, team_id, r),
    do:
      st.roster
      |> Map.fetch!(team_id)
      |> Enum.filter(&available?(st, &1, r))
      |> Enum.take(st.boards)

  defp active_players(st, r) do
    for {id, a} <- st.avail, a.withdrawn_from == nil or a.withdrawn_from > r, do: id
  end

  defp mark_absent(st, id, r) do
    p = Tournaments.get_player(st.tid, id)
    kept = String.split(p.absent_rounds || "", ",", trim: true)

    {:ok, _} =
      Tournaments.update_player(p, %{"absent_rounds" => Enum.join(kept ++ ["#{r}"], ",")})

    %{st | avail: Map.update!(st.avail, id, &%{&1 | absent: MapSet.put(&1.absent, r)})}
  end

  defp withdraw(st, id, r) do
    p = Tournaments.get_player(st.tid, id)
    {:ok, _} = Tournaments.update_player(p, %{"status" => "withdrawn"})
    %{st | avail: Map.update!(st.avail, id, &%{&1 | withdrawn_from: r})}
  end

  ## ---------- team Swiss ----------

  defp play_swiss(st, send_after) do
    Enum.reduce_while(1..st.rounds, st, fn r, acc ->
      acc = before_swiss_round(acc, r)
      open = open_postponed_ids(acc)

      # Who can field a player, as this test sees it, before pairing.
      expected = Map.new(acc.roster, fn {id, _} -> {id, lineup(acc, id, r)} end)

      case Pairing.pair_next_round(tournament(acc),
             acknowledged: [:adjourned_older_round_open]
           ) do
        {:ok, round} ->
          acc = %{
            acc
            | lineups: Map.put(acc.lineups, r, expected),
              open_at_pair: Map.put(acc.open_at_pair, r, open),
              paired_rounds: acc.paired_rounds ++ [r]
          }

          acc = acc |> enter_results(round, r) |> play_late_games(r)
          acc = if r in send_after or r == acc.rounds, do: send_now(acc, r), else: acc
          {:cont, bump(acc, :rounds)}

        {:error, reason} ->
          acc = bump(acc, :"halted_#{halt_kind(reason)}")
          acc = send_now(acc, r - 1)
          {:halt, Map.merge(acc, %{halted_at: r, halt_reason: reason})}
      end
    end)
  end

  defp halt_kind({:team_pairing, reason, _}), do: reason
  defp halt_kind(reason) when is_binary(reason), do: "message"
  defp halt_kind(_), do: "other"

  defp before_swiss_round(st, r) do
    st =
      if r >= 2 and chance(25) do
        team_id = Enum.random(Map.keys(st.roster))
        bump(add_player(st, team_id, Tournaments.next_start_round(st.tid)), :late_players)
      else
        st
      end

    st =
      if r >= 2 and r < st.rounds and chance(10),
        do: bump(add_team(st, Tournaments.next_start_round(st.tid)), :late_teams),
        else: st

    st =
      if r >= 2 and chance(20) do
        case active_players(st, r) do
          [] -> st
          ids -> bump(withdraw(st, Enum.random(ids), r), :withdrawn_players)
        end
      else
        st
      end

    # A whole team withdraws: every one of its players.
    st =
      if r >= 2 and chance(6) do
        team_id = Enum.random(Map.keys(st.roster))

        st.roster[team_id]
        |> Enum.filter(&(st.avail[&1].withdrawn_from == nil))
        |> Enum.reduce(st, &withdraw(&2, &1, r))
        |> bump(:withdrawn_teams)
      else
        st
      end

    if chance(45) do
      ids = active_players(st, r)

      ids
      |> Enum.take_random(between(1, max(1, div(length(ids), 6))))
      |> Enum.reduce(st, &mark_absent(&2, &1, r))
      |> bump(:absence_rounds)
    else
      st
    end
  end

  ## ---------- team round robin ----------

  defp play_rr(st, send_after) do
    # Before the one-click pairing: late reserves and absences for later
    # rounds, which the lineups of every round are taken from.
    st =
      Enum.reduce(1..between(0, 3), st, fn _, acc ->
        if chance(50) do
          team_id = Enum.random(Map.keys(acc.roster))
          bump(add_player(acc, team_id, between(2, acc.rounds)), :late_players)
        else
          acc
        end
      end)

    st =
      Enum.reduce(Map.keys(st.avail), st, fn id, acc ->
        if chance(12),
          do: bump(mark_absent(acc, id, between(1, acc.rounds)), :absence_rounds),
          else: acc
      end)

    expected =
      Map.new(1..st.rounds, fn r ->
        {r, Map.new(st.roster, fn {id, _} -> {id, lineup(st, id, r)} end)}
      end)

    case RoundRobin.pair_all_rounds(tournament(st)) do
      {:ok, last} ->
        st = %{st | lineups: expected}

        st =
          if last != st.rounds,
            do: fail(st, "pair all: #{last} rounds, expected #{st.rounds}"),
            else: st

        Enum.reduce(1..last, st, fn r, acc ->
          # A player who drops out after the schedule: forfeits from now on.
          acc =
            if r >= 2 and chance(15) do
              case active_players(acc, r) do
                [] -> acc
                ids -> bump(withdraw(acc, Enum.random(ids), r), :withdrawn_players)
              end
            else
              acc
            end

          round = Tournaments.get_round(acc.tid, r)
          acc = %{acc | paired_rounds: acc.paired_rounds ++ [r]}
          acc = acc |> enter_results(round, r) |> play_late_games(r)
          acc = if r in send_after or r == last, do: send_now(acc, r), else: acc
          bump(acc, :rounds)
        end)

      {:error, reason} ->
        fail(st, "pair all refused: #{inspect(reason)}")
    end
  end

  ## ---------- results ----------

  @ack PostponedGames.acknowledgement_ids()

  @played_results ~w(1-0 0-1 1/2-1/2 1-0U 0-1U 1/2-1/2U 0-0 1/2-0 0-1/2)

  defp enter_results(st, round, r) do
    round = Repo.preload(round, :pairings, force: true)
    t = tournament(st)

    round.id
    |> Tournaments.list_matches()
    |> Enum.filter(& &1.team_b_id)
    |> Enum.reduce(st, fn match, acc ->
      winner = Enum.random([match.team_a_id, match.team_b_id])

      cond do
        chance(4) ->
          # Forfeited by decision before a game was played.
          decide(acc, t, match, winner, :before)

        true ->
          boards = Enum.filter(round.pairings, &(&1.match_id == match.id))
          acc = Enum.reduce(boards, acc, &enter_board(&2, &1, r))

          cond do
            chance(4) ->
              acc = decide(acc, t, Repo.reload!(match), winner, :after)

              if chance(25) do
                case TeamMatches.withdraw_forfeit(t, Repo.reload!(match)) do
                  {:ok, _} -> bump(acc, :decisions_withdrawn)
                  other -> fail(acc, "r#{r}: withdrawing a decision refused: #{inspect(other)}")
                end
              else
                acc
              end

            true ->
              acc
          end
      end
    end)
    |> then(fn acc ->
      # Boards outside every match (none expected) still get a result.
      round = Repo.preload(round, :pairings, force: true)

      round.pairings
      |> Enum.filter(&(&1.result in [nil, ""]))
      |> Enum.reduce(acc, &enter_board(&2, &1, r))
    end)
  end

  defp decide(st, t, match, winner, tag) do
    case TeamMatches.forfeit_match(t, match, winner) do
      {:ok, _} -> bump(st, :"decisions_#{tag}")
      {:error, :no_boards} -> bump(st, :decision_no_boards)
      other -> fail(st, "forfeit by decision refused: #{inspect(other)}")
    end
  end

  defp enter_board(st, p, r) do
    p = Repo.reload!(p)

    cond do
      p.result not in [nil, ""] ->
        st

      p.white_player_id == nil or p.black_player_id == nil ->
        fail(
          st,
          "r#{r}: a one-sided board with no result: #{inspect({p.white_player_id, p.black_player_id})}"
        )

      true ->
        gone = fn id -> not available?(st, id, r) end

        result =
          case {gone.(p.white_player_id), gone.(p.black_player_id)} do
            {true, true} -> "0-0FF"
            {true, false} -> "0-1FF"
            {false, true} -> "1-0FF"
            _ -> pick_result(st)
          end

        opts = [acknowledged: @ack, played_on: Enum.at(st.dates, r - 1)]

        case Tournaments.update_pairing_result(p, result, opts) do
          {:ok, _} ->
            st = bump(st, :boards)
            if result in ~w(* *W *B), do: Map.put(st, :had_postponed, true), else: st

          {:error, reason} ->
            fail(st, "r#{r}: result #{result} refused: #{inspect(reason)}")
        end
    end
  end

  defp pick_result(st) do
    cond do
      st.postponed? and chance(6) -> Enum.random(~w(* *W *B))
      chance(5) -> Enum.random(~w(1-0FF 0-1FF 0-0FF))
      chance(4) -> Enum.random(~w(1-0U 0-1U 1/2-1/2U))
      true -> Enum.random(~w(1-0 0-1 1/2-1/2 1-0 0-1))
    end
  end

  defp open_postponed_ids(%{postponed?: false}), do: MapSet.new()

  defp open_postponed_ids(st),
    do: st.tid |> PostponedGames.open_games() |> MapSet.new(& &1.pairing.id)

  defp play_late_games(%{postponed?: false} = st, _r), do: st

  defp play_late_games(st, r) do
    st.tid
    |> PostponedGames.open_games()
    |> Enum.filter(fn _ -> r == :all or chance(40) end)
    |> Enum.reduce(st, fn %{round: rn, pairing: p}, acc ->
      result = Enum.random(~w(1-0 0-1 1/2-1/2 1-0FF))
      played = Date.add(Enum.at(acc.dates, rn - 1), between(1, 30))
      opts = [acknowledged: @ack, played_on: played]

      case Tournaments.update_pairing_result(Repo.reload!(p), result, opts) do
        {:ok, _} -> bump(acc, :late_played)
        {:error, reason} -> fail(acc, "late game r#{rn}: #{result} refused: #{inspect(reason)}")
      end
    end)
  end

  ## ---------- sending ----------

  defp send_now(st, upto) when upto < 1, do: st

  defp send_now(st, upto) do
    t = tournament(st)
    sent = PostponedGames.sent_rounds(t)
    rounds = Enum.to_list(1..upto) -- sent

    if rounds == [] do
      st
    else
      meta = TrfExport.export_meta(t, Enum.join(rounds, ","))

      case PostponedGames.send_rounds(
             t,
             meta.rounds,
             fn fresh -> TrfExport.export(fresh, meta.rounds) end,
             acknowledged: [:round_sent_before]
           ) do
        {:ok, %{file: text}} ->
          # The teams as they stood when the file went out (a team may
          # arrive later).
          teams = Tournaments.list_teams(st.tid)
          st = %{st | sent_files: st.sent_files ++ [{meta.rounds, text, teams}]}

          case PostponedGames.send_rounds(t, meta.rounds, fn f ->
                 TrfExport.export(f, meta.rounds)
               end) do
            {:error, {:already_sent, _}} ->
              bump(st, :resend_refused)

            other ->
              fail(st, "rounds #{inspect(meta.rounds)} sent twice: #{inspect(other, limit: 3)}")
          end

        {:error, reason} ->
          fail(st, "send of rounds #{inspect(rounds)} refused: #{inspect(reason)}")
      end
    end
  end

  defp send_late(%{postponed?: false} = st), do: st

  defp send_late(st) do
    t = tournament(st)

    periods =
      t
      |> PostponedGames.sendable_late_games()
      |> Enum.map(&PostponedGames.late_period/1)
      |> Enum.uniq()
      |> Enum.reject(&is_nil/1)

    Enum.reduce(periods, st, fn period, acc ->
      build = &TrfExport.postponed_export(&1, period: period)

      case PostponedGames.send_late_games(t, build) do
        {:ok, text, games, _receipt} ->
          acc = %{acc | late_files: acc.late_files ++ [{period, text, length(games)}]}

          case PostponedGames.send_late_games(t, build) do
            {:error, :nothing_to_send} -> bump(acc, :late_resend_refused)
            other -> fail(acc, "late games of #{period} sent twice: #{inspect(other, limit: 3)}")
          end

        {:error, reason} ->
          fail(acc, "late send #{period} refused: #{inspect(reason)}")
      end
    end)
  end

  ## ---------- the checks ----------

  defp validate(st, dump) do
    t = tournament(st)
    players = Tournaments.list_players(st.tid)
    by_id = Map.new(players, &{&1.id, &1})
    games = stored_games(st.tid)
    matches = stored_matches(st.tid)
    st = check_database(st, t, games, matches)

    st =
      Enum.reduce(st.sent_files, st, fn {rounds, text, teams_then}, acc ->
        acc = maybe_dump(acc, dump, "r#{Enum.join(rounds, "-")}", text)
        check_report(acc, t, rounds, text, games, matches, teams_then, by_id)
      end)

    st =
      Enum.reduce(st.late_files, st, fn {period, text, n}, acc ->
        acc = maybe_dump(acc, dump, "late-#{period}", text)
        check_late(acc, text, n)
      end)

    st = check_once(st, games, by_id)
    {:ok, full} = TrfExport.export(t, nil, copy: true)
    st = maybe_dump(st, dump, "full", full)
    st = if st.kind == :swiss, do: check_engine_input(st, t, full, games, matches), else: st
    check_with_engine(st, t, full, dump, games, matches)
  end

  defp maybe_dump(st, nil, _tag, _text), do: st

  defp maybe_dump(st, dir, tag, text) do
    File.write!(Path.join(dir, "s#{st.seed}-#{tag}.trf"), text)
    st
  end

  defp stored_games(tid) do
    Repo.all(
      from p in PairingsEngine.Tournaments.Pairing,
        join: r in PairingsEngine.Tournaments.Round,
        on: p.round_id == r.id,
        where: r.tournament_id == ^tid,
        select: %{
          id: p.id,
          round: r.number,
          board: p.board,
          match_id: p.match_id,
          white: p.white_player_id,
          black: p.black_player_id,
          result: p.result,
          finalised_open: p.finalised_open,
          prov_white: p.provisional_white,
          prov_black: p.provisional_black
        }
    )
  end

  defp stored_matches(tid) do
    Repo.all(
      from m in Match,
        join: r in PairingsEngine.Tournaments.Round,
        on: m.round_id == r.id,
        where: r.tournament_id == ^tid,
        select: %{
          id: m.id,
          round: r.number,
          number: m.board,
          a: m.team_a_id,
          b: m.team_b_id,
          forfeited_to: m.forfeited_to_team_id,
          previous: m.forfeit_previous_results
        }
    )
  end

  # A decision taken after at least one game of the match was played.
  defp decided_after_play?(%{forfeited_to: nil}), do: false

  defp decided_after_play?(%{previous: previous}) when is_map(previous),
    do: Enum.any?(Map.values(previous), &(&1 in @played_results))

  defp decided_after_play?(_), do: false

  ## the database: colours, board numbers, lineups, the field

  defp check_database(st, t, games, matches) do
    boards = st.boards
    by_match = Enum.group_by(games, & &1.match_id)
    numbers = t.id |> Tournaments.list_teams() |> Map.new(&{&1.id, &1.pairing_number})

    # Roster order in the database is the order this test kept.
    st =
      Enum.reduce(st.roster, st, fn {team_id, ids}, acc ->
        db = t.id |> Tournaments.team_roster(team_id) |> Enum.map(& &1.id)

        if db == ids,
          do: acc,
          else: fail(acc, "team #{team_id}: roster #{inspect(db)} vs #{inspect(ids)}")
      end)

    st =
      Enum.reduce(matches, st, fn m, acc ->
        ms = Map.get(by_match, m.id, [])
        expected = get_in(acc.lineups, [m.round])

        cond do
          m.b == nil ->
            if ms == [],
              do: bump(acc, :bye_matches),
              else: fail(acc, "r#{m.round}: bye match with boards")

          expected == nil ->
            fail(acc, "r#{m.round}: a match in a round this test did not pair")

          true ->
            {acc, side_a, side_b} =
              Enum.reduce(Enum.sort_by(ms, & &1.board), {acc, %{}, %{}}, fn g, {a2, sa, sb} ->
                k = g.board - (m.number - 1) * boards

                if k < 1 or k > boards do
                  {fail(a2, "r#{m.round} match #{m.number}: board #{g.board} outside the match"),
                   sa, sb}
                else
                  {a_id, b_id} =
                    if rem(k, 2) == 1, do: {g.white, g.black}, else: {g.black, g.white}

                  {a2, if(a_id, do: Map.put(sa, k, a_id), else: sa),
                   if(b_id, do: Map.put(sb, k, b_id), else: sb)}
                end
              end)

            got_a = side_a |> Enum.sort() |> Enum.map(&elem(&1, 1))
            got_b = side_b |> Enum.sort() |> Enum.map(&elem(&1, 1))
            want_a = Map.get(expected, m.a, [])
            want_b = Map.get(expected, m.b, [])

            # Seats run 1..n with no gap on each side.
            gapless? =
              Enum.sort(Map.keys(side_a)) == Enum.to_list(1..map_size(side_a)//1) and
                Enum.sort(Map.keys(side_b)) == Enum.to_list(1..map_size(side_b)//1)

            acc =
              if got_a == want_a and got_b == want_b and gapless? and
                   length(ms) == max(length(want_a), length(want_b)),
                 do: bump(acc, :lineups_ok),
                 else:
                   fail(
                     acc,
                     "r#{m.round} match #{m.number} (T#{numbers[m.a]}-T#{numbers[m.b]}): lineups " <>
                       "#{inspect({got_a, got_b})} (seats #{inspect({Map.keys(side_a), Map.keys(side_b)})}), " <>
                       "expected #{inspect({want_a, want_b})}"
                   )

            # One-sided seats are the forfeit win of whoever is there,
            # unless a decision gave the match to the empty side.
            Enum.reduce(ms, acc, fn g, a2 ->
              cond do
                g.white && g.black ->
                  a2

                m.forfeited_to != nil ->
                  a2

                (g.white != nil and g.result == "1-0FF") or
                    (g.black != nil and g.result == "0-1FF") ->
                  bump(a2, :board_forfeit_seats)

                true ->
                  fail(
                    a2,
                    "r#{m.round} board #{g.board}: one-sided seat with #{inspect(g.result)}"
                  )
              end
            end)
        end
      end)

    # Swiss: exactly the teams able to field a player are paired.
    if st.kind == :swiss do
      Enum.reduce(st.paired_rounds, st, fn r, acc ->
        able = for {id, l} <- acc.lineups[r], l != [], into: MapSet.new(), do: id

        paired =
          for m <- matches, m.round == r, id <- [m.a, m.b], id != nil, into: MapSet.new(), do: id

        if able == paired,
          do: bump(acc, :field_ok),
          else:
            fail(
              acc,
              "r#{r}: paired teams #{inspect(Enum.map(paired, &numbers[&1]))}, " <>
                "teams able to play #{inspect(Enum.map(able, &numbers[&1]))}"
            )
      end)
    else
      st
    end
  end

  ## one sent file

  defp parse_001(text) do
    for line <- String.split(text, ["\r\n", "\n"]),
        String.starts_with?(line, "001 "),
        into: %{} do
      rank = line |> String.slice(4, 4) |> String.trim() |> String.to_integer()

      blocks =
        line
        |> String.slice(91..-1//1)
        |> then(&String.pad_trailing(&1, round_up(String.length(&1))))
        |> chunk10()
        |> Enum.with_index(1)
        |> Map.new(fn {b, col} ->
          opp = b |> String.slice(0, 4) |> String.trim()

          {col,
           %{
             opp: if(opp in ["", "0000"], do: nil, else: String.to_integer(opp)),
             colour: b |> String.slice(5, 1) |> String.trim(),
             code: b |> String.slice(7, 1) |> String.trim()
           }}
        end)

      {rank,
       %{
         name: line |> String.slice(14, 33) |> String.trim(),
         rating: line |> String.slice(48, 4) |> String.trim(),
         points: line |> String.slice(80, 4) |> String.trim() |> parse_float(),
         blocks: blocks
       }}
    end
  end

  defp round_up(len), do: div(len + 9, 10) * 10
  defp chunk10(""), do: []
  defp chunk10(s), do: [String.slice(s, 0, 10) | chunk10(String.slice(s, 10..-1//1))]

  defp parse_float(""), do: nil

  defp parse_float(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp lines(text, code),
    do: text |> String.split(["\r\n", "\n"]) |> Enum.filter(&String.starts_with?(&1, code <> " "))

  defp header(text, code) do
    case lines(text, code) do
      [line | _] -> String.slice(line, 4..-1//1)
      [] -> nil
    end
  end

  # TRF26 310: number 5-7, name 9-40, MP 55-60, GP 62-67, rank 69-71,
  # players from 74 in 4-wide slots every 5.
  defp parse_310(text) do
    for line <- lines(text, "310") do
      players =
        line
        |> String.slice(73..-1//1)
        |> then(&String.pad_trailing(&1, round_up5(String.length(&1))))
        |> chunk5()
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(&String.to_integer/1)

      %{
        number: line |> String.slice(4, 3) |> String.trim() |> String.to_integer(),
        name: line |> String.slice(8, 32) |> String.trim(),
        mp: line |> String.slice(54, 6) |> String.trim() |> parse_float(),
        gp: line |> String.slice(61, 6) |> String.trim() |> parse_float(),
        rank: line |> String.slice(68, 3) |> String.trim(),
        players: players
      }
    end
  end

  defp round_up5(len), do: div(len + 4, 5) * 5
  defp chunk5(""), do: []
  defp chunk5(s), do: [String.slice(s, 0, 5) | chunk5(String.slice(s, 5..-1//1))]

  # TRF26 320: MP 5-8, GP 10-13, the bye team of the file's i-th round in
  # 15+4i..17+4i.
  defp parse_320(text) do
    case lines(text, "320") do
      [] ->
        nil

      [line | _] ->
        teams =
          line
          |> String.slice(14..-1//1)
          |> then(fn s -> String.pad_trailing(s, div(String.length(s) + 3, 4) * 4) end)
          |> chunk4()
          |> Enum.map(fn c ->
            case c |> String.trim() |> Integer.parse() do
              {n, _} -> n
              :error -> 0
            end
          end)

        %{
          mp: line |> String.slice(4, 4) |> String.trim() |> parse_float(),
          gp: line |> String.slice(9, 4) |> String.trim() |> parse_float(),
          teams: teams
        }
    end
  end

  defp chunk4(""), do: []
  defp chunk4(s), do: [String.slice(s, 0, 4) | chunk4(String.slice(s, 4..-1//1))]

  defp parse_362(text) do
    case header(text, "362") do
      nil ->
        nil

      rest ->
        ~r/([WDLPAX])\s+(\d+(?:\.\d+)?)/
        |> Regex.scan(rest)
        |> Map.new(fn [_, s, v] -> {s, elem(Float.parse(v), 0)} end)
    end
  end

  # What this test expects on each side of a two-player board.
  @codes %{
    "1-0" => {"1", "0"},
    "0-1" => {"0", "1"},
    "1/2-1/2" => {"=", "="},
    "1-0FF" => {"+", "-"},
    "0-1FF" => {"-", "+"},
    "0-0FF" => {"-", "-"},
    "1-0U" => {"W", "L"},
    "0-1U" => {"L", "W"},
    "1/2-1/2U" => {"D", "D"},
    "0-0" => {"0", "0"},
    "1/2-0" => {"=", "0"},
    "0-1/2" => {"0", "="}
  }

  # A seat with no opponent: the point without a game, by what it is worth.
  @no_game %{
    "+" => "F",
    "1" => "F",
    "W" => "F",
    "=" => "H",
    "D" => "H",
    "-" => "Z",
    "0" => "Z",
    "L" => "Z"
  }

  @rated ~w(1 0 =)
  @mirror %{
    "1" => "0",
    "0" => "1",
    "=" => "=",
    "+" => "-",
    "-" => "+",
    "W" => "L",
    "L" => "W",
    "D" => "D",
    "?" => "?"
  }

  defp point_values(text) do
    base = %{
      "1" => 1.0,
      "=" => 0.5,
      "0" => 0.0,
      "W" => 1.0,
      "D" => 0.5,
      "L" => 0.0,
      "+" => 1.0,
      "-" => 0.0,
      "F" => 1.0,
      "H" => 0.5,
      "Z" => 0.0,
      "U" => 1.0,
      "?" => 0.5
    }

    case header(text, "162") do
      nil ->
        base

      line ->
        entries =
          line
          |> String.graphemes()
          |> Enum.drop(1)
          |> Enum.chunk_every(9)
          |> Enum.map(&Enum.join/1)
          |> Enum.reject(&(String.trim(&1) == ""))
          |> Enum.map(fn e ->
            {String.slice(e, 0, 1), e |> String.slice(1, 4) |> String.trim() |> parse_float()}
          end)

        pinned_p? = Enum.any?(entries, &(elem(&1, 0) == "P"))

        Enum.reduce(entries, base, fn
          {_, nil}, acc ->
            acc

          {"W", v}, acc ->
            acc = Map.merge(acc, %{"1" => v, "W" => v, "+" => v, "F" => v})
            if pinned_p?, do: acc, else: Map.put(acc, "U", v)

          {"D", v}, acc ->
            Map.merge(acc, %{"=" => v, "D" => v, "H" => v})

          {"L", v}, acc ->
            Map.merge(acc, %{"0" => v, "L" => v})

          {k, v}, acc when k in ["Z", "A"] ->
            Map.merge(acc, %{"Z" => v, "-" => v})

          {"P", v}, acc ->
            Map.put(acc, "U", v)

          {"X", v}, acc ->
            Map.put(acc, "?", v)

          _, acc ->
            acc
        end)
    end
  end

  defp expected_codes(%{finalised_open: true}), do: {"?", "?"}
  defp expected_codes(%{result: r}) when r in ["*", "*W", "*B"], do: {"?", "?"}
  defp expected_codes(%{result: r}), do: Map.get(@codes, r, {"?unexpected #{r}", "?"})

  defp check_report(st, t, rounds, text, games, matches, teams, by_id) do
    st = bump(st, :files)

    st =
      case parse_ok(text) do
        :ok ->
          st

        {:error, e} ->
          fail(st, "rounds #{inspect(rounds)}: Ainalrami.Trf.parse refuses the file: #{e}")
      end

    rows = parse_001(text)
    rank_of = Map.new(Map.values(by_id), &{&1.id, &1.pairing_number})
    col_of = rounds |> Enum.with_index(1) |> Map.new()
    in_file = Enum.filter(games, &(&1.round in rounds))
    tag = "rounds #{inspect(rounds, charlists: :as_lists)}"

    # 1. Every stored board is on its players' lines, right.
    {st, expected} =
      Enum.reduce(in_file, {st, MapSet.new()}, fn g, {acc, seen} ->
        col = Map.fetch!(col_of, g.round)

        cond do
          g.white && g.black ->
            {wc, bc} = expected_codes(g)
            wr = rank_of[g.white]
            br = rank_of[g.black]
            wb = get_in(rows, [wr, :blocks, col])
            bb = get_in(rows, [br, :blocks, col])

            ok? =
              wb != nil and bb != nil and wb.opp == br and bb.opp == wr and wb.colour == "w" and
                bb.colour == "b" and wb.code == wc and bb.code == bc

            acc =
              if ok?,
                do: bump(acc, if(wc in @rated, do: :rated_games_ok, else: :other_games_ok)),
                else:
                  fail(
                    acc,
                    "#{tag}: r#{g.round}: #{wr}-#{br} #{g.result} expected #{wc}/#{bc}, " <>
                      "file has #{inspect(wb)} / #{inspect(bb)}"
                  )

            {acc, seen |> MapSet.put({wr, col}) |> MapSet.put({br, col})}

          true ->
            # A seat only one team filled.
            {id, side} = if g.white, do: {g.white, 0}, else: {g.black, 1}
            code = @codes |> Map.get(g.result, {"?", "?"}) |> elem(side)
            want = Map.get(@no_game, code, "?unexpected #{g.result}")
            b = get_in(rows, [rank_of[id], :blocks, col])

            if (b && b.opp == nil) and b.code == want,
              do: {bump(acc, :seat_forfeits_ok), MapSet.put(seen, {rank_of[id], col})},
              else:
                {fail(
                   acc,
                   "#{tag}: r#{g.round}: seat of #{rank_of[id]} (#{g.result}) written #{inspect(b)}, want #{want}"
                 ), seen}
        end
      end)

    # 2. Nothing else carries an opponent or a code with a value of its own.
    st =
      Enum.reduce(rows, st, fn {rank, row}, acc ->
        Enum.reduce(row.blocks, acc, fn {col, b}, acc2 ->
          cond do
            MapSet.member?(expected, {rank, col}) ->
              acc2

            b.opp != nil ->
              fail(
                acc2,
                "#{tag}: rank #{rank} col #{col}: a game the database does not hold: #{inspect(b)}"
              )

            b.code in ~w(1 0 = + - W D L ? F H U) ->
              fail(acc2, "#{tag}: rank #{rank} col #{col}: #{inspect(b)} with no board")

            true ->
              acc2
          end
        end)
      end)

    # 3. Mirror symmetry, from the file alone.
    st =
      Enum.reduce(rows, st, fn {rank, row}, acc ->
        Enum.reduce(row.blocks, acc, fn {col, b}, acc2 ->
          with %{opp: opp} when opp != nil <- b,
               other when not is_nil(other) <- get_in(rows, [opp, :blocks, col]) do
            cond do
              other.opp != rank ->
                fail(acc2, "#{tag}: rank #{rank} col #{col}: opponent #{opp} does not point back")

              Map.get(@mirror, b.code) == other.code ->
                acc2

              {b.code, other.code} == {"-", "-"} ->
                acc2

              {b.code, other.code} in [{"0", "0"}, {"=", "0"}, {"0", "="}] ->
                bump(acc2, :asymmetric_sides)

              true ->
                fail(acc2, "#{tag}: rank #{rank} col #{col}: #{b.code} against #{other.code}")
            end
          else
            _ -> acc2
          end
        end)
      end)

    # 4. Points add up from the file's own point system.
    values = point_values(text)

    st =
      Enum.reduce(rows, st, fn {rank, row}, acc ->
        sum = row.blocks |> Map.values() |> Enum.map(&Map.get(values, &1.code, 0.0)) |> Enum.sum()

        if row.points != nil and abs(sum - row.points) < 0.001,
          do: acc,
          else:
            fail(
              acc,
              "#{tag}: rank #{rank}: points column #{inspect(row.points)}, its games add to #{sum}"
            )
      end)

    # 5. Headers.
    n_lines = map_size(rows)
    rated = Enum.count(rows, fn {_, r} -> r.rating not in ["", "0"] end)
    dates = (header(text, "132") || "") |> String.split(~r/\s+/, trim: true)
    type_label = if st.kind == :swiss, do: "Team: Swiss System", else: "Team: Round Robin System"

    code192 =
      if st.kind == :swiss,
        do: "FIDE_TEAM_TYPEA_MP_GP",
        else: "BERGER_TEAM_ROUNDROBIN_G#{t.rr_cycles || 1}"

    trimmed = fn c -> (header(text, c) || "") |> String.trim() end

    st =
      cond do
        trimmed.("062") != "#{n_lines}" ->
          fail(st, "#{tag}: 062 #{trimmed.("062")} but #{n_lines} lines")

        trimmed.("072") != "#{rated}" ->
          fail(st, "#{tag}: 072 #{trimmed.("072")} but #{rated} rated lines")

        trimmed.("082") != "#{length(teams)}" ->
          fail(st, "#{tag}: 082 #{trimmed.("082")} but #{length(teams)} teams")

        trimmed.("092") != type_label ->
          fail(st, "#{tag}: 092 #{inspect(trimmed.("092"))}")

        trimmed.("192") != code192 ->
          fail(st, "#{tag}: 192 #{inspect(trimmed.("192"))}")

        length(dates) < length(rounds) ->
          fail(st, "#{tag}: 132 has #{length(dates)} dates for #{length(rounds)} rounds")

        true ->
          bump(st, :headers_ok)
      end

    # 6. 362: the match points.
    want362 = %{
      "W" => t.team_match_points_win,
      "D" => t.team_match_points_draw,
      "L" => t.team_match_points_loss
    }

    got362 = parse_362(text)

    st =
      if got362 != nil and Map.take(got362, ~w(W D L)) == want362,
        do: bump(st, :mp362_ok),
        else: fail(st, "#{tag}: 362 #{inspect(got362)}, settings #{inspect(want362)}")

    # 7. 310: one per team, exactly the file's players of that team.
    check_310(st, t, rounds, text, rows, games, matches, teams, by_id, values)
  end

  defp check_310(st, t, rounds, text, rows, games, matches, teams, by_id, values) do
    tag = "rounds #{inspect(rounds, charlists: :as_lists)}"
    recs = parse_310(text)
    team_by_number = Map.new(teams, &{&1.pairing_number, &1})
    rank_of = Map.new(Map.values(by_id), &{&1.id, &1.pairing_number})
    in_file = MapSet.new(Map.keys(rows))
    match_by_id = Map.new(matches, &{&1.id, &1})

    # Who sat for which team in the file's rounds, from the database.
    sat_for =
      for g <- games,
          g.round in rounds,
          m = Map.get(match_by_id, g.match_id),
          m != nil,
          {id, k_white?} <- [{g.white, true}, {g.black, false}],
          id != nil,
          reduce: %{} do
        acc ->
          k = g.board - (m.number - 1) * st.boards
          a_side? = rem(k, 2) == 1 == k_white?
          team_id = if a_side?, do: m.a, else: m.b
          Map.update(acc, team_id, MapSet.new([rank_of[id]]), &MapSet.put(&1, rank_of[id]))
      end

    pab = if st.kind == :swiss, do: parse_320(text), else: nil

    st =
      if length(recs) == length(teams) and
           Enum.sort(Enum.map(recs, & &1.number)) ==
             Enum.sort(Enum.map(teams, & &1.pairing_number)),
         do: bump(st, :teams310_ok),
         else:
           fail(
             st,
             "#{tag}: 310 numbers #{inspect(Enum.map(recs, & &1.number))} for #{length(teams)} teams"
           )

    st =
      Enum.reduce(recs, st, fn rec, acc ->
        team = Map.get(team_by_number, rec.number)

        if team == nil do
          fail(acc, "#{tag}: 310 #{rec.number}: no such team")
        else
          want =
            st.roster
            |> Map.get(team.id, [])
            |> Enum.map(&rank_of[&1])
            |> Enum.filter(&MapSet.member?(in_file, &1))

          sat = Map.get(sat_for, team.id, MapSet.new())

          acc =
            cond do
              rec.name != team.name ->
                fail(acc, "#{tag}: 310 #{rec.number}: name #{inspect(rec.name)}")

              rec.players != want ->
                fail(
                  acc,
                  "#{tag}: 310 #{rec.number}: players #{inspect(rec.players)}, roster order of the file's players #{inspect(want)}"
                )

              not MapSet.subset?(sat, MapSet.new(rec.players)) ->
                fail(
                  acc,
                  "#{tag}: 310 #{rec.number}: #{inspect(MapSet.to_list(MapSet.difference(sat, MapSet.new(rec.players))))} played for it but are not listed"
                )

              true ->
                idle = length(rec.players) - MapSet.size(sat)
                acc |> bump(:rosters310_ok) |> bump(:listed_without_game_in_file, idle)
            end

          # MP / GP add up from the file: the members' points over the
          # file's rounds, the bye's from 320, match points from 362.
          gp_games =
            rec.players
            |> Enum.flat_map(&Map.values(get_in(rows, [&1, :blocks]) || %{}))
            |> Enum.map(&Map.get(values, &1.code, 0.0))
            |> Enum.sum()

          byes = if pab, do: Enum.count(pab.teams, &(&1 == rec.number)), else: 0
          gp = gp_games + byes * ((pab && pab.gp) || 0.0)

          if rec.gp != nil and abs(rec.gp - gp) < 0.001,
            do: bump(acc, :gp310_ok),
            else:
              (fn ->
                 x =
                   "GP T#{rec.number} #{inspect(rec.gp)}/#{gp} " <>
                     inspect(gp_by_round(t, team, rec, rows, rounds, values, pab))

                 Map.update(acc, :mism, [x], &[x | &1])
               end).()
        end
      end)

    st = check_310_mp(st, tag, rows, recs, pab, values, text)

    # One line per file: the 310 totals (file / the file's own games).
    {mism, st} = Map.pop(st, :mism, [])

    st =
      if mism == [],
        do: st,
        else:
          fail(
            st,
            "#{tag}: 310 MP/GP are not the file's games " <>
              "(#{if rounds == Enum.to_list(1..Enum.max(rounds)), do: "from round 1", else: "partial"}, " <>
              "#{length(mism)}, 310/file [{round, app, file}]): " <>
              Enum.join(Enum.take(Enum.reverse(mism), 4), ", ")
          )

    # 320: the round's bye team, by the file's round order.
    case st.kind do
      :rr ->
        if pab == nil, do: st, else: fail(st, "#{tag}: a 320 in a round robin")

      :swiss ->
        numbers = Map.new(teams, &{&1.id, &1.pairing_number})

        want =
          Enum.map(rounds, fn r ->
            case Enum.find(matches, &(&1.round == r and &1.b == nil)) do
              nil -> 0
              m -> numbers[m.a]
            end
          end)

        cond do
          Enum.all?(want, &(&1 == 0)) and pab == nil ->
            st

          pab == nil ->
            fail(st, "#{tag}: no 320, byes #{inspect(want)}")

          (pab.teams ++ List.duplicate(0, length(want))) |> Enum.take(length(want)) != want or
              length(pab.teams) > length(want) ->
            fail(st, "#{tag}: 320 #{inspect(pab.teams)}, byes #{inspect(want)}")

          pab.mp != t.team_match_points_draw or abs(pab.gp - st.boards * t.points_draw) > 0.001 ->
            fail(st, "#{tag}: 320 pays #{pab.mp} MP / #{pab.gp} GP")

          true ->
            bump(st, :pab320_ok)
        end
    end
  end

  # A team's game points round by round, the app's (`TeamStandings`) and
  # the file's, where they differ.
  defp gp_by_round(t, team, rec, rows, rounds, values, pab) do
    ms =
      for m <- PairingsEngine.TeamStandings.matches(t, through_round: Enum.max(rounds)),
          m.round in rounds,
          team.id in [m.team_a_id, m.team_b_id],
          into: %{},
          do: {m.round, m}

    app = Map.new(ms, fn {r, m} -> {r, if(m.team_a_id == team.id, do: m.gp_a, else: m.gp_b)} end)

    rounds
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {r, col} ->
      file =
        rec.players
        |> Enum.map(&get_in(rows, [&1, :blocks, col]))
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&Map.get(values, &1.code, 0.0))
        |> Enum.sum()

      file = if pab && Enum.at(pab.teams, col - 1) == rec.number, do: file + pab.gp, else: file
      a = Map.get(app, r, 0.0)

      boards =
        case ms[r] do
          nil ->
            []

          m ->
            for b <- m.boards,
                do:
                  {b.board, b.pairing.result, b.pairing.provisional_white, b.a_points, b.b_points}
        end

      codes =
        Enum.map(rec.players, &((get_in(rows, [&1, :blocks, col]) || %{}) |> Map.get(:code)))

      side = if ms[r] && ms[r].team_a_id == team.id, do: :a, else: :b

      if abs(a - file) < 0.001,
        do: [],
        else: [{r, a, file, side, boards, codes, ms[r] && ms[r].forfeited_to}]
    end)
  end

  # Each team's match points, worked out from the file's boards: per round,
  # its game points against its opponent's (both teams' players' points),
  # 362's win/draw/loss; the bye 320's.
  defp check_310_mp(st, _tag, rows, recs, pab, values, text) do
    mp = parse_362(text) || %{}
    team_of = for rec <- recs, r <- rec.players, into: %{}, do: {r, rec.number}
    cols = rows |> Enum.flat_map(fn {_, row} -> Map.keys(row.blocks) end) |> Enum.uniq()

    per_round =
      for col <- cols, rec <- recs, into: %{} do
        blocks = for r <- rec.players, b = get_in(rows, [r, :blocks, col]), b != nil, do: b
        opps = blocks |> Enum.filter(& &1.opp) |> Enum.map(&team_of[&1.opp]) |> Enum.uniq()
        gp = blocks |> Enum.map(&Map.get(values, &1.code, 0.0)) |> Enum.sum()
        unknown? = Enum.any?(blocks, &(&1.code == "?"))
        {{col, rec.number}, %{opps: opps, gp: gp, unknown?: unknown?}}
      end

    Enum.reduce(recs, st, fn rec, acc ->
      total =
        Enum.reduce(cols, {0.0, false}, fn col, {sum, unk} ->
          me = per_round[{col, rec.number}]
          bye? = pab != nil and Enum.at(pab.teams, col - 1) == rec.number

          cond do
            bye? ->
              {sum + pab.mp, unk}

            match?([_], me.opps) ->
              [o] = me.opps
              them = per_round[{col, o}]
              unk = unk or me.unknown? or them.unknown?

              add =
                cond do
                  me.gp > them.gp -> mp["W"]
                  me.gp < them.gp -> mp["L"]
                  true -> mp["D"]
                end

              {sum + add, unk}

            me.opps == [] and me.gp > 0 ->
              # Every board a seat only this team filled: the other side
              # fielded nobody - this file cannot see who it was.
              {sum, true}

            true ->
              {sum, unk}
          end
        end)

      case total do
        {_, true} ->
          bump(acc, :mp310_not_checked)

        {sum, false} ->
          if rec.mp != nil and abs(rec.mp - sum) < 0.001,
            do: bump(acc, :mp310_ok),
            else:
              Map.update(
                acc,
                :mism,
                ["MP T#{rec.number} #{inspect(rec.mp)}/#{sum}"],
                &["MP T#{rec.number} #{inspect(rec.mp)}/#{sum}" | &1]
              )
      end
    end)
  end

  defp parse_ok(text) do
    case Ainalrami.Trf.parse(text) do
      {:error, e} -> {:error, inspect(e)}
      _ -> :ok
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp check_late(st, text, n) do
    st = bump(st, :late_files)
    rows = parse_001(text)

    played =
      for {_rank, row} <- rows, {_c, b} <- row.blocks, b.opp != nil, reduce: 0 do
        acc -> acc + 1
      end

    st =
      case parse_ok(text) do
        :ok -> st
        {:error, e} -> fail(st, "late file refused by Ainalrami.Trf.parse: #{e}")
      end

    if div(played, 2) == n,
      do: bump(st, :late_games_in_files, n),
      else: fail(st, "late file carries #{div(played, 2)} games, the send recorded #{n}")
  end

  # Across every file sent: each rated game once, each late game once.
  defp check_once(st, games, by_id) do
    name = fn id -> Map.fetch!(by_id, id).name end

    from_reports =
      for {rounds, text, _teams} <- st.sent_files,
          rows = parse_001(text),
          names = Map.new(rows, fn {rank, row} -> {rank, row.name} end),
          {rank, row} <- rows,
          {col, b} <- row.blocks,
          b.colour == "w",
          b.opp != nil,
          b.code in (@rated ++ ~w(+ - W L D)) do
        {Enum.at(rounds, col - 1), names[rank], names[b.opp], b.code}
      end

    from_late =
      for {_p, text, _n} <- st.late_files,
          rows = parse_001(text),
          names = Map.new(rows, fn {rank, row} -> {rank, row.name} end),
          {rank, row} <- rows,
          {_col, b} <- row.blocks,
          b.colour == "w",
          b.opp != nil do
        {:late, names[rank], names[b.opp], b.code}
      end

    st =
      Enum.reduce(games, st, fn g, acc ->
        if g.white && g.black do
          {wc, _} = Map.get(@codes, g.result, {nil, nil})
          w = name.(g.white)
          b = name.(g.black)

          in_reports =
            Enum.count(from_reports, fn {round, ww, bb, code} ->
              round == g.round and ww == w and bb == b and code != "?"
            end)

          cond do
            g.result in ["*", "*W", "*B"] ->
              fail(acc, "r#{g.round} #{w}-#{b} still open after the event")

            g.finalised_open ->
              if in_reports == 0,
                do: bump(acc, :late_not_in_reports),
                else:
                  fail(
                    acc,
                    "late game r#{g.round} #{w}-#{b}: also #{in_reports} time(s) in a round report"
                  )

            wc == nil ->
              acc

            true ->
              if in_reports == 1,
                do: bump(acc, if(wc in @rated, do: :rated_once, else: :unrated_once)),
                else:
                  fail(
                    acc,
                    "r#{g.round} #{w}-#{b} #{g.result}: #{in_reports} times in round reports"
                  )
          end
        else
          acc
        end
      end)

    pair = fn a, b -> Enum.sort([a, b]) end

    expected =
      games
      |> Enum.filter(&(&1.white && &1.black && &1.finalised_open))
      |> Enum.frequencies_by(&pair.(name.(&1.white), name.(&1.black)))

    actual = Enum.frequencies_by(from_late, fn {_, w, b, _} -> pair.(w, b) end)

    if expected == actual,
      do: bump(st, :late_once, Enum.sum(Map.values(actual))),
      else:
        fail(
          st,
          "postponed-games files: expected per pair #{inspect(expected)}, files hold #{inspect(actual)}"
        )
  end

  ## the engine's input, round by round, against the final report

  defp check_engine_input(st, t, full, games, matches) do
    rows = parse_001(full)
    recs = parse_310(full)
    pab = parse_320(full)
    mpv = parse_362(full) || %{}
    values = point_values(full)
    team_of = for rec <- recs, r <- rec.players, into: %{}, do: {r, rec.number}
    numbers = t.id |> Tournaments.list_teams() |> Map.new(&{&1.id, &1.pairing_number})
    players = Tournaments.list_players(t.id) |> Map.new(&{&1.id, &1.pairing_number})

    # Decisions taken after play: the file shows only forfeits, the app
    # (rightly) still counts the match as played.
    after_play =
      for m <- matches, decided_after_play?(m), into: MapSet.new() do
        {m.round, Enum.sort([numbers[m.a], numbers[m.b]])}
      end

    paired = st.paired_rounds
    last = Enum.max(paired, fn -> 0 end)
    Process.put(:team_flow_debug, {games, players, st.open_at_pair})

    # Per round and team, read from the file, as it stood when round
    # `at` was paired: boards still open (postponed) then count as the
    # draws the engine was given.
    history_at = fn at ->
      open = Map.get(st.open_at_pair, at, MapSet.new())

      for r <- 1..last//1, into: %{} do
        # A game the report writes as `?` (sent before it was played) was
        # its real result for the engine once played; while still open,
        # the provisional outcome frozen on the board.
        override =
          for g <- games,
              g.round == r,
              g.white && g.black,
              MapSet.member?(open, g.id) or g.finalised_open,
              {side, prov, i} <- [{g.white, g.prov_white, 0}, {g.black, g.prov_black, 1}],
              into: %{} do
            code =
              if MapSet.member?(open, g.id),
                do: Map.get(%{"win" => "1", "loss" => "0"}, prov, "="),
                else: @codes |> Map.get(g.result, {"=", "="}) |> elem(i)

            {players[side], code}
          end

        per_team =
          for rec <- recs, into: %{} do
            blocks =
              for rank <- rec.players,
                  b = get_in(rows, [rank, :blocks, r]),
                  b != nil,
                  do: {rank, %{b | code: Map.get(override, rank, b.code)}}

            met = Enum.filter(blocks, fn {_, b} -> b.opp end)
            opps = met |> Enum.map(fn {_, b} -> team_of[b.opp] end) |> Enum.uniq()
            gp = blocks |> Enum.map(fn {_, b} -> Map.get(values, b.code, 0.0) end) |> Enum.sum()
            played? = Enum.any?(blocks, fn {_, b} -> b.code in ~w(1 0 = W L D ?) end)
            seat_only? = met == [] and Enum.any?(blocks, fn {_, b} -> b.code == "F" end)

            colour =
              case met do
                [{_, b} | _] -> if b.colour == "w", do: :white, else: :black
                [] -> nil
              end

            bye? = pab != nil and Enum.at(pab.teams, r - 1) == rec.number

            entry =
              cond do
                bye? -> %{kind: :bye, gp: pab.gp, mp: pab.mp}
                seat_only? -> %{kind: :anomaly, why: "only seats without opponents"}
                opps == [] -> %{kind: :out}
                length(opps) > 1 -> %{kind: :anomaly, why: "boards against #{inspect(opps)}"}
                true -> %{kind: :match, opp: hd(opps), gp: gp, played?: played?, colour: colour}
              end

            {rec.number, entry}
          end

        per_team =
          Map.new(per_team, fn
            {n, %{kind: :match} = e} ->
              o = per_team[e.opp]
              ap? = MapSet.member?(after_play, {r, Enum.sort([n, e.opp])})

              mp =
                cond do
                  e.gp > o.gp -> mpv["W"]
                  e.gp < o.gp -> mpv["L"]
                  true -> mpv["D"]
                end

              {n,
               Map.merge(e, %{mp: mp, opp_gp: o.gp, played?: e.played? or ap?, after_play?: ap?})}

            other ->
              other
          end)

        {r, per_team}
      end
    end

    Enum.reduce(paired, st, fn r, acc ->
      case Process.get({:team_engine_input, r}) do
        nil ->
          fail(acc, "r#{r}: no engine input was recorded")

        %{teams: given, opts: opts} ->
          acc
          |> compare_input(r, given, opts, history_at.(r), recs)
          |> compare_output(r, given, opts, matches, numbers)
      end
    end)
  end

  defp compare_input(st, r, given, opts, history, recs) do
    anomalies =
      for {rr, per} <- history,
          rr <= r,
          {n, %{kind: :anomaly, why: why}} <- per,
          do: "r#{rr} T#{n}: #{why}"

    field =
      for {n, e} <- history[r], e.kind in [:match, :bye], do: n

    seen_before =
      for {rr, per} <- history,
          rr < r,
          {n, e} <- per,
          e.kind in [:match, :bye],
          into: MapSet.new(),
          do: n

    want_absent =
      for rec <- recs, rec.number not in field, rec.number in seen_before, do: rec.number

    want =
      for n <- Enum.sort(field) do
        past = for rr <- 1..(r - 1)//1, e = history[rr][n], do: {rr, e}
        matches = for {rr, %{kind: :match} = e} <- past, do: {rr, e}
        played = for {rr, e} <- matches, e.played?, do: {rr, e}

        prev =
          case history[r - 1] do
            nil -> nil
            per -> per[n]
          end

        floated? =
          case prev do
            %{kind: :match, opp: o} ->
              score_before(history, n, r - 1) != score_before(history, o, r - 1)

            _ ->
              false
          end

        %{
          tpn: n,
          match_points: past |> Enum.map(fn {_, e} -> Map.get(e, :mp) || 0.0 end) |> sum1(),
          game_points: past |> Enum.map(fn {_, e} -> Map.get(e, :gp) || 0.0 end) |> sum1(),
          opponents: Enum.map(played, fn {_, e} -> e.opp end),
          colours: Enum.map(played, fn {_, e} -> e.colour end),
          had_pab?: Enum.any?(past, fn {_, e} -> e.kind == :bye end),
          won_by_forfeit?:
            Enum.any?(matches, fn {_, e} ->
              (not e.played? or e.after_play?) and e.gp > e.opp_gp
            end),
          floated_last_round?: floated?
        }
      end

    got =
      given
      |> Enum.sort_by(& &1.tpn)
      |> Enum.map(fn tm ->
        %{
          tpn: tm.tpn,
          match_points: Float.round(tm.match_points / 1, 1),
          game_points: Float.round(tm.game_points / 1, 1),
          opponents: tm.opponents,
          colours: tm.colours,
          had_pab?: tm.had_pab?,
          won_by_forfeit?: tm.won_by_forfeit?,
          floated_last_round?: tm.floated_last_round?
        }
      end)

    got_absent = opts |> Keyword.get(:absent, []) |> Enum.sort()

    cond do
      anomalies != [] ->
        fail(
          st,
          "r#{r}: the file's rounds cannot be read as matches: #{inspect(Enum.take(anomalies, 3))}"
        )

      got == want and got_absent == Enum.sort(want_absent) ->
        bump(st, :engine_input_same)

      true ->
        diffs =
          got
          |> Enum.zip(want)
          |> Enum.flat_map(fn {g, w} ->
            if g == w,
              do: [],
              else: [
                {g.tpn,
                 for(
                   k <- Map.keys(g),
                   Map.get(g, k) != Map.get(w, k),
                   into: %{},
                   do: {k, {Map.get(g, k), Map.get(w, k)}}
                 )}
              ]
          end)

        fail(
          st,
          "r#{r}: engine input differs from the report: field #{inspect(Enum.map(got, & &1.tpn))} vs " <>
            "#{inspect(Enum.map(want, & &1.tpn))}, absent #{inspect(got_absent)} vs #{inspect(want_absent)}, " <>
            "teams (engine, file) #{inspect(Enum.take(diffs, 4))}" <> debug_boards(r, diffs, recs)
        )
    end
  end

  # The boards before round `r` of the first team that differs, as the
  # database holds them now: {round, result, sent as ?, provisional, open
  # when round r was paired}.
  defp debug_boards(_r, [], _recs), do: ""

  defp debug_boards(r, [{tpn, _} | _], recs) do
    case Process.get(:team_flow_debug) do
      {games, players, open_at_pair} ->
        ranks = recs |> Enum.find(%{players: []}, &(&1.number == tpn)) |> Map.get(:players)
        open = Map.get(open_at_pair, r, MapSet.new())

        rows =
          for g <- games,
              g.round < r,
              players[g.white] in ranks or players[g.black] in ranks,
              do:
                {g.round, players[g.white], players[g.black], g.result, g.finalised_open,
                 {g.prov_white, g.prov_black}, MapSet.member?(open, g.id)}

        " boards of T#{tpn}: " <> inspect(Enum.sort(rows), limit: :infinity)

      _ ->
        ""
    end
  end

  # What the engine returns for the input it was given (it is
  # deterministic) against the matches the app wrote: who meets whom, the
  # team with White on board 1 as team A, the bye.
  defp compare_output(st, r, given, opts, matches, numbers) do
    case Ainalrami.TeamPairing.pair_round(given, opts) do
      {:ok, result} ->
        want =
          Enum.sort(Enum.map(result.pairs, &{&1.white, &1.black})) ++
            if(result.bye, do: [{result.bye, nil}], else: [])

        got =
          matches
          |> Enum.filter(&(&1.round == r))
          |> Enum.map(&{numbers[&1.a], &1.b && numbers[&1.b]})
          |> Enum.split_with(&(elem(&1, 1) != nil))
          |> then(fn {pairs, byes} -> Enum.sort(pairs) ++ byes end)

        if got == want,
          do: bump(st, :engine_output_written),
          else:
            fail(st, "r#{r}: the engine pairs #{inspect(want)}, the app wrote #{inspect(got)}")

      other ->
        fail(st, "r#{r}: re-pairing the recorded input gives #{inspect(other, limit: 5)}")
    end
  end

  defp score_before(history, n, round),
    do: sum1(for rr <- 1..(round - 1)//1, e = history[rr][n], do: Map.get(e, :mp) || 0.0)

  defp sum1(values), do: values |> Enum.sum() |> Kernel./(1) |> Float.round(1)

  ## ainalrami -c on the full report

  # The team tie-breaks in C.07's (Ainalrami's) spelling -
  # `TeamStandings`' own mapping. The report's 202 carries the app's codes
  # (MP,GP,DE,BB,SB), which the checker cannot rank by ("MP is not a
  # tie-break code"); the file is checked with them translated, and the
  # untranslated line is counted.
  @c07_team %{
    "MP" => "MPTS",
    "GP" => "GPTS",
    "DE" => "DE",
    "BH" => "BH:MP",
    "SB" => "SB:MP",
    "EMGSB" => "EMGSB",
    "BB" => "BC"
  }

  defp check_with_engine(%{had_postponed: true} = st, _t, _full, _dump, _games, _matches),
    do: bump(st, :engine_check_skipped_postponed)

  defp check_with_engine(st, _t, full, dump, games, matches) do
    st = if header(full, "152") == nil, do: bump(st, :report_without_152), else: st
    codes = (header(full, "202") || "") |> String.trim() |> String.split(",", trim: true)
    mapped = Enum.map(codes, &Map.get(@c07_team, &1, &1))

    {st, text} =
      if mapped != codes do
        patched =
          full
          |> String.split("\r\n")
          |> Enum.map(fn line ->
            if String.starts_with?(line, "202 "), do: "202 " <> Enum.join(mapped, ","), else: line
          end)
          |> Enum.join("\r\n")

        {bump(st, :report_202_not_c07), patched}
      else
        {st, full}
      end

    path =
      Path.join(
        System.tmp_dir!(),
        "teamflow-#{st.seed}-#{System.unique_integer([:positive])}.trf"
      )

    File.write!(path, text)

    output =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        out =
          ExUnit.CaptureIO.capture_io(fn ->
            Process.put(:check_code, Ainalrami.CLI.run(["-c", path]))
          end)

        IO.write(:stderr, out)
      end)

    code = Process.get(:check_code)
    File.rm(path)

    # Both kinds are replayed since Ainalrami's integrate-037: a team round
    # robin against the Berger tables (C.05 Annex 1), colours included.
    if code == 0 do
      bump(st, :"engine_check_ok_#{st.kind}")
    else
      limits = checker_limits(st, games, matches)

      first_diff =
        case Regex.run(~r/round (\d+): (DIFFERS|this engine)/, output) do
          [_, n | _] -> String.to_integer(n)
          nil -> nil
        end

      # A round is re-paired from the rounds before it; the standings from
      # them all.
      upto = first_diff || 1_000
      reasons = for {kind, rounds} <- limits, Enum.any?(rounds, &(&1 < upto)), do: kind

      if reasons != [] do
        Enum.reduce(reasons, st, &bump(&2, :"checker_limited_#{&1}"))
      else
        if dump,
          do: File.write!(Path.join(dump, "s#{st.seed}-check.txt"), text <> "\n\n" <> output)

        fail(
          st,
          "ainalrami -c exit #{inspect(code)} on the full #{st.kind} report: " <>
            (output
             |> String.split("\n")
             |> Enum.filter(&(&1 =~ ~r/DIFFERS|differ|standings|engine:|file:|team \d+:/))
             |> Enum.take(8)
             |> Enum.join(" | "))
        )
      end
    end
  end

  # What `ainalrami -c` reads differently from the app, by round:
  #   * :seat - a board one team could not fill. The file writes it as
  #     the point without a game (`F`, no opponent); the checker's team
  #     reading (`Tiebreaks.Team.from_trf/2`) counts only boards with an
  #     opponent, so the team present loses that game point;
  #   * :decision - a match forfeited by decision after games were played:
  #     the file shows only forfeits, so the checker sees an unplayed match;
  #   * :bye - a team Swiss pairing-allocated bye: the bye team's players
  #     carry no `U`, only the `320` names it, and `from_trf/2` scores such a
  #     round as a zero-point bye (C.04.6 1.4 pays a draw).
  defp checker_limits(st, games, matches) do
    by_match = Map.new(matches, &{&1.id, &1})

    seat =
      for g <- games,
          Map.has_key?(by_match, g.match_id),
          is_nil(g.white) or is_nil(g.black),
          uniq: true,
          do: g.round

    decision = for m <- matches, decided_after_play?(m), uniq: true, do: m.round

    bye =
      if st.kind == :swiss, do: for(m <- matches, m.b == nil, uniq: true, do: m.round), else: []

    [seat: seat, decision: decision, bye: bye]
  end
end
