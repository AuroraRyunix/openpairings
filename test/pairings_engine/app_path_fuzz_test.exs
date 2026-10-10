defmodule PairingsEngine.AppPathFuzzTest do
  @moduledoc """
  The engine is not the suspect here; the app around it is.

  Random individual Swiss events are driven through the app's own context
  functions - the calls the LiveViews make - with the things that have gone
  wrong before, and their cousins: late entrants, withdrawals and returns,
  announced absences (paid and unpaid, capped and not), forfeits, point
  systems, Baku, forbidden pairs, a round unpaired and paired again, an
  earlier result corrected after later rounds exist.

  After every round the app is asked the same question several ways and the
  answers have to agree:

    * nobody is paired who is not in the round; nobody is in a round twice;
      two players who PLAYED each other do not meet again;
    * a round that is unpaired and paired again, nothing else changed, is
      the same round;
    * with `late_entry_numbering` "rating" the pairing numbers follow the
      initial order (C.04.2 2.2-2.4);
    * the score the engine was handed for each player (the TRF's own points
      column, captured from the pairing run) is the score the standings show;
    * the standings' points are the sum of the standings' own per-round
      records, and the TRF export's points column says the same;
    * the OpenResults snapshot holds, for every player in its standings and
      every round up to `after_round`, exactly one figure, and those figures
      add up to the standings' number (the results site adds them up; a
      missing one is a dash for the rest of the event);
    * the tournament exported to TRF and imported again, and exported to
      JSON and imported again, pairs the same next round;
    * the file for rating passes the engine's own checker, as long as no
      earlier round was changed after a later one was paired.

  APP_PATH_FUZZ_COUNT (default 6), APP_PATH_FUZZ_FIRST (default 1).
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ainalrami.Trf
  alias Ecto.Adapters.SQL.Sandbox

  alias PairingsEngine.{
    Pairing,
    Repo,
    Snapshot,
    Standings,
    TournamentExport,
    TournamentImport,
    Tournaments,
    TrfExport,
    TrfImport
  }

  alias PairingsEngine.Tournaments.Player

  @moduletag :app_path_fuzz
  @moduletag capture_log: true

  setup do
    handler = "app-path-fuzz-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:pairings_engine, :pairing, :trf_built],
      &__MODULE__.capture/4,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  @doc false
  def capture(_event, _m, meta, _c), do: Process.put({:engine_trf, meta.round}, meta.trf)

  @tag timeout: :infinity
  test "what the app hands the engine, and what it says afterwards, agree" do
    first = env_int("APP_PATH_FUZZ_FIRST", 1)
    count = env_int("APP_PATH_FUZZ_COUNT", 6)

    results =
      for seed <- first..(first + count - 1)//1 do
        fn -> run_seed(seed) end |> Task.async() |> Task.await(:infinity)
      end

    totals =
      Enum.reduce(results, %{}, fn r, acc -> Map.merge(acc, r.stats, fn _, a, b -> a + b end) end)

    failures = Enum.flat_map(results, & &1.failures)

    IO.puts(
      "\nAPPPATH tournaments=#{count} " <>
        Enum.map_join(Enum.sort(totals), " ", fn {k, v} -> "#{k}=#{v}" end) <>
        " failures=#{length(failures)}"
    )

    if dump = System.get_env("APP_PATH_FUZZ_DUMP") do
      File.write!(dump, Enum.join(failures, "\n\n"))
    end

    assert failures == [], Enum.join(Enum.take(failures, 12), "\n\n")
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

  defp run_seed(seed) do
    owner = Sandbox.start_owner!(Repo, shared: false, ownership_timeout: 1_800_000)

    try do
      :rand.seed(:exsss, {seed, seed * 7919, seed * 104_729})
      st = play(seed)
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

  @systems [{1.0, 0.5, 0.0}, {1.0, 0.5, 0.0}, {3.0, 1.0, 0.0}, {2.0, 1.0, 0.0}]

  defp play(seed) do
    n = between(6, 18)
    rounds = between(4, 7) |> min(n - 1)
    {win, draw, loss} = Enum.random(@systems)

    # What an announced absence pays, and under which cap.
    {abs_value, abs_nbfois, abs_jusque} =
      Enum.random([
        {nil, nil, nil},
        {nil, nil, nil},
        {draw, nil, nil},
        {draw, 1, nil},
        {draw, nil, 2},
        {win, nil, nil}
      ])

    dates = for r <- 1..rounds, do: Date.add(~D[2026-08-01], (r - 1) * 7)

    attrs = %{
      "name" => "AppPath #{seed}",
      "type" => "swiss",
      "city" => "Pelt",
      "federation" => "BEL",
      "chief_arbiter" => "Arbiter, Test",
      "start_date" => Date.to_iso8601(hd(dates)),
      "end_date" => Date.to_iso8601(List.last(dates)),
      "round_dates" => Enum.map(dates, &Date.to_iso8601/1),
      "rounds_count" => rounds,
      "acceleration" => Enum.random(~w(none none none baku)),
      "points_win" => win,
      "points_draw" => draw,
      "points_loss" => loss,
      "bye_value" => Enum.random([win, win, draw]),
      "abs_value" => abs_value,
      "abs_nbfois" => abs_nbfois,
      "abs_jusque" => abs_jusque,
      "late_entry_absences" => chance(50),
      "late_entry_numbering" => Enum.random(~w(rating rating end)),
      "tiebreaks" => ~w(BH SB)
    }

    {:ok, t} = Tournaments.create_tournament(attrs)

    st = %{
      seed: seed,
      tid: t.id,
      rounds: rounds,
      next: 1,
      withdrawn: MapSet.new(),
      # An earlier round was changed after a later one was paired: the
      # rounds no longer follow from the file, and nobody claims they do.
      replayable?: true,
      stats: %{},
      failures: []
    }

    st = Enum.reduce(1..n, st, fn _, acc -> add_player(acc, 1) end)
    st = maybe_forbid(st)

    Enum.reduce_while(1..rounds, st, fn r, acc ->
      acc = before_round(acc, r)
      acc = round_trip(acc, r)

      case pair(acc) do
        {:ok, round} ->
          acc =
            acc
            |> check_round(round, r)
            |> check_engine_scores(r)
            |> check_numbering()
            |> maybe_repair(round, r)
            |> maybe_edit_by_hand(r)
            |> enter_results(r)
            |> maybe_edit_earlier(r)
            |> check_scores(r)
            |> check_snapshot(r)
            |> bump(:rounds)

          {:cont, acc}

        {:error, reason} ->
          {:halt,
           acc
           |> note("round #{r}: pairing stopped: #{inspect(reason, limit: 6)}")
           |> bump(:halted)}
      end
    end)
    |> check_with_engine()
  end

  defp tournament(st), do: Tournaments.get_tournament!(st.tid)
  defp pair(st), do: Pairing.pair_next_round(tournament(st))

  defp bump(st, key, by \\ 1), do: %{st | stats: Map.update(st.stats, key, by, &(&1 + by))}

  defp fail(st, message),
    do: %{st | failures: st.failures ++ ["seed #{st.seed}: " <> message]} |> bump(:failed)

  defp note(st, message) do
    if System.get_env("APP_PATH_FUZZ_VERBOSE"), do: IO.puts("seed #{st.seed}: #{message}")
    st
  end

  ## ---------- the event ----------

  defp add_player(st, start_round) do
    i = st.next

    {:ok, _p} =
      Tournaments.create_player(st.tid, %{
        "name" => "Player#{String.pad_leading("#{i}", 2, "0")}, S#{st.seed}",
        "fide_rating" => if(chance(12), do: 0, else: between(1200, 2500)),
        "federation" => Enum.random(~w(BEL BEL NED FRA)),
        "club" => Enum.random(~w(A B C D)),
        "start_round" => start_round
      })

    %{st | next: i + 1}
  end

  defp maybe_forbid(st) do
    if chance(30) do
      [a, b] = st.tid |> Tournaments.list_players() |> Enum.take_random(2)

      case Tournaments.add_forbidden_pairing(tournament(st), a.id, b.id) do
        {:ok, _} -> bump(st, :forbidden)
        _ -> st
      end
    else
      st
    end
  end

  defp players(st), do: Tournaments.list_players(st.tid)

  defp in_round?(p, r),
    do:
      p.status == "active" and not p.absent and not p.forfeit and (p.start_round || 1) <= r and
        r not in Player.parse_absent_rounds(p.absent_rounds)

  defp before_round(st, r) do
    st =
      if r >= 2 and chance(25),
        do: st |> add_player(Tournaments.next_start_round(st.tid)) |> bump(:late_entrants),
        else: st

    st =
      if r >= 2 and chance(20) and Enum.count(players(st), &in_round?(&1, r)) > 6 do
        p = players(st) |> Enum.filter(&in_round?(&1, r)) |> Enum.random()
        {:ok, _} = Tournaments.update_player(p, %{"status" => "withdrawn"})
        %{st | withdrawn: MapSet.put(st.withdrawn, p.id)} |> bump(:withdrawals)
      else
        st
      end

    # Somebody who left comes back.
    st =
      if MapSet.size(st.withdrawn) > 0 and chance(30) do
        id = Enum.random(st.withdrawn)

        {:ok, _} =
          Tournaments.update_player(Tournaments.get_player!(st.tid, id), %{"status" => "active"})

        %{st | withdrawn: MapSet.delete(st.withdrawn, id)} |> bump(:returns)
      else
        st
      end

    if chance(40) and Enum.count(players(st), &in_round?(&1, r)) > 6 do
      p = players(st) |> Enum.filter(&in_round?(&1, r)) |> Enum.random()
      kept = String.split(p.absent_rounds || "", ",", trim: true)

      {:ok, _} =
        Tournaments.update_player(p, %{"absent_rounds" => Enum.join(kept ++ ["#{r}"], ",")})

      bump(st, :absences)
    else
      st
    end
  end

  defp boards(st, r) do
    Repo.all(
      from p in PairingsEngine.Tournaments.Pairing,
        join: rd in PairingsEngine.Tournaments.Round,
        on: p.round_id == rd.id,
        where: rd.tournament_id == ^st.tid and rd.number == ^r,
        order_by: p.board
    )
  end

  # The arbiter's hand on a paired round: two players swapped, or one taken
  # off their board (with the absence that goes with it) and the opponent
  # given the bye or a forfeit win. From here on the round is not the
  # engine's, and nobody replays it.
  defp maybe_edit_by_hand(st, r) do
    if chance(18) do
      round = Tournaments.get_round(st.tid, r)
      full = Enum.filter(round.pairings, &(&1.white_player_id && &1.black_player_id))

      case {Enum.random(~w(swap vacate vacate)a), full} do
        {:swap, [_, _ | _]} ->
          [a, b] = Enum.take_random(full, 2)

          case Tournaments.swap_players_in_round(round, a.white_player_id, b.black_player_id) do
            {:ok, _} -> %{st | replayable?: false} |> bump(:hand_swaps)
            other -> note(st, "round #{r}: swap refused: #{inspect(other, limit: 4)}")
          end

        {:vacate, [_ | _]} ->
          board = Enum.random(full)
          leaver = Enum.random([board.white_player_id, board.black_player_id])
          type = Enum.random(~w(absent absent requested-half requested-zero))

          case Tournaments.vacate_seat(round, leaver, type, acknowledged: [:second_half_bye]) do
            {:ok, _} ->
              st = %{st | replayable?: false} |> bump(:hand_vacated)
              round = Tournaments.get_round(st.tid, r)
              board = Enum.find(round.pairings, &(&1.id == board.id))

              if chance(50) do
                case Tournaments.award_bye_for_vacancy(round, board) do
                  {:ok, _} -> bump(st, :hand_byes)
                  other -> note(st, "round #{r}: bye refused: #{inspect(other, limit: 4)}")
                end
              else
                result = if board.white_player_id, do: "1-0FF", else: "0-1FF"

                case Tournaments.update_pairing_result(board, result, []) do
                  {:ok, _} -> bump(st, :hand_forfeit_wins)
                  other -> note(st, "round #{r}: #{result} refused: #{inspect(other, limit: 4)}")
                end
              end

            other ->
              note(st, "round #{r}: vacate refused: #{inspect(other, limit: 4)}")
          end

        _ ->
          st
      end
    else
      st
    end
  end

  defp enter_results(st, r) do
    Enum.reduce(boards(st, r), st, fn p, acc ->
      if p.white_player_id && p.black_player_id && p.result in [nil, ""] do
        result =
          cond do
            chance(8) -> Enum.random(~w(1-0FF 0-1FF 0-0FF))
            true -> Enum.random(~w(1-0 0-1 1/2-1/2 1-0 0-1))
          end

        case Tournaments.update_pairing_result(p, result, []) do
          {:ok, _} -> bump(acc, :games)
          other -> fail(acc, "round #{r}: result #{result} refused: #{inspect(other, limit: 4)}")
        end
      else
        acc
      end
    end)
  end

  # A result of an earlier round is corrected once the next one exists.
  defp maybe_edit_earlier(st, r) when r < 2, do: st

  defp maybe_edit_earlier(st, r) do
    if chance(15) do
      case Enum.filter(boards(st, r - 1), &(&1.white_player_id && &1.black_player_id)) do
        [] ->
          st

        games ->
          p = Enum.random(games)
          result = Enum.random(~w(1-0 0-1 1/2-1/2 1-0FF) -- [p.result])

          case Tournaments.update_pairing_result(p, result, []) do
            {:ok, _} -> %{st | replayable?: false} |> bump(:earlier_edits)
            _refused -> st
          end
      end
    else
      st
    end
  end

  ## ---------- the round itself ----------

  defp check_round(st, _round, r) do
    by_id = Map.new(players(st), &{&1.id, &1})
    rows = boards(st, r)

    seated =
      Enum.flat_map(rows, &[&1.white_player_id, &1.black_player_id]) |> Enum.reject(&is_nil/1)

    st =
      if seated == Enum.uniq(seated),
        do: st,
        else: fail(st, "round #{r}: a player sits on two boards")

    st =
      Enum.reduce(seated, st, fn id, acc ->
        p = Map.fetch!(by_id, id)

        if in_round?(p, r),
          do: acc,
          else: fail(acc, "round #{r}: #{p.name} is paired but is not in the round")
      end)

    # Everybody in the round is on a board.
    st =
      Enum.reduce(Map.values(by_id), st, fn p, acc ->
        if in_round?(p, r) and p.id not in seated,
          do: fail(acc, "round #{r}: #{p.name} is in the round and was not paired"),
          else: acc
      end)

    st =
      case Enum.count(rows, &is_nil(&1.black_player_id)) do
        n when n <= 1 -> st
        n -> fail(st, "round #{r}: #{n} pairing-allocated byes")
      end

    # C.04.1: no two players play each other twice. Played, not seated.
    played =
      for rn <- 1..(r - 1)//1,
          b <- boards(st, rn),
          b.white_player_id && b.black_player_id,
          not PairingsEngine.Results.forfeit?(b.result),
          into: MapSet.new(),
          do: key(b.white_player_id, b.black_player_id)

    forbidden =
      for f <- Tournaments.list_forbidden_pairings(st.tid),
          not f.soft,
          into: MapSet.new(),
          do: key(f.player_a_id, f.player_b_id)

    Enum.reduce(rows, st, fn b, acc ->
      k = b.white_player_id && b.black_player_id && key(b.white_player_id, b.black_player_id)

      cond do
        is_nil(k) -> acc
        k in played -> fail(acc, "round #{r} board #{b.board}: the two already played")
        k in forbidden -> fail(acc, "round #{r} board #{b.board}: a forbidden pair")
        true -> acc
      end
    end)
  end

  defp key(a, b) when a <= b, do: {a, b}
  defp key(a, b), do: {b, a}

  # The score in the engine's own input, against the standings before the
  # round - the number the brackets are made of.
  defp check_engine_scores(st, r) do
    case Process.get({:engine_trf, r}) do
      nil ->
        st

      trf ->
        t = tournament(st)
        table = Standings.standings(t, through_round: r - 1)
        by_name = Map.new(table, &{&1.player.name, &1.points})

        Enum.reduce(Trf.parse(trf).players, st, fn row, acc ->
          shown = Map.get(by_name, row.name)

          if is_number(shown) and abs(shown - row.points) > 0.001,
            do:
              fail(
                acc,
                "round #{r}: #{row.name} was paired on #{row.points}, the standings say #{shown}"
              ),
            else: acc
        end)
    end
  end

  # C.04.2 2.2-2.4: with late entrants "accommodated in the pairing list",
  # the numbers are the initial order of whoever holds one.
  defp check_numbering(st) do
    t = tournament(st)

    numbered =
      players(st) |> Enum.filter(& &1.pairing_number) |> Enum.sort_by(& &1.pairing_number)

    numbers = Enum.map(numbered, & &1.pairing_number)

    st =
      if numbers == Enum.to_list(1..length(numbers)//1),
        do: st,
        else: fail(st, "pairing numbers are not 1..N: #{inspect(numbers)}")

    if t.late_entry_numbering == "rating" and
         Enum.map(numbered, & &1.id) != Enum.map(Pairing.initial_order(numbered, t), & &1.id) do
      fail(
        st,
        "pairing numbers do not follow the initial order: " <>
          Enum.map_join(numbered, " ", &"#{&1.pairing_number}:#{Player.rating(&1, t)}")
      )
    else
      st
    end
  end

  # Unpair, pair again, nothing else touched: the same round.
  defp maybe_repair(st, _round, r) do
    if chance(25) do
      before = shape(st, r)
      numbers_before = Map.new(players(st), &{&1.id, &1.pairing_number})

      case Pairing.delete_round(st.tid, r) do
        :ok ->
          case pair(st) do
            {:ok, _round} ->
              st = bump(st, :repaired)
              now = shape(st, r)

              st =
                if now == before,
                  do: st,
                  else:
                    fail(
                      st,
                      "round #{r}: unpaired and paired again, it is another round\n  was #{inspect(before)}\n  now #{inspect(now)}"
                    )

              numbers_now = Map.new(players(st), &{&1.id, &1.pairing_number})

              if numbers_now == numbers_before,
                do: st,
                else: fail(st, "round #{r}: unpaired and paired again, the pairing numbers moved")

            {:error, reason} ->
              fail(st, "round #{r}: could not be paired again: #{inspect(reason, limit: 6)}")
          end

        other ->
          fail(st, "round #{r}: could not be unpaired: #{inspect(other, limit: 6)}")
      end
    else
      st
    end
  end

  defp shape(st, r) do
    names = Map.new(players(st), &{&1.id, &1.name})

    byes =
      Repo.all(
        from b in "byes",
          where: b.tournament_id == ^st.tid and b.round == ^r,
          select: {b.player_id, b.type}
      )

    {for(b <- boards(st, r), do: {b.board, names[b.white_player_id], names[b.black_player_id]}),
     byes |> Enum.map(fn {id, type} -> {names[id], type} end) |> Enum.sort()}
  end

  ## ---------- the scores, asked several ways ----------

  defp check_scores(st, r) do
    t = tournament(st)
    table = Standings.standings(t)

    # The standings against their own per-round records.
    st =
      Enum.reduce(table, st, fn e, acc ->
        sum = e.games |> Enum.map(& &1.points) |> Enum.sum()

        if abs(sum - e.points) > 0.001,
          do:
            fail(
              acc,
              "after round #{r}: #{e.player.name} has #{e.points}, the rounds add up to #{sum}"
            ),
          else: acc
      end)

    # The TRF's points column against the standings.
    case TrfExport.export(t) do
      {:ok, text} ->
        by_name = Map.new(table, &{&1.player.name, &1.points})

        Enum.reduce(Trf.parse(text).players, st, fn row, acc ->
          shown = Map.get(by_name, row.name)

          if is_number(shown) and abs(shown - row.points) > 0.001,
            do:
              fail(
                acc,
                "after round #{r}: the TRF gives #{row.name} #{row.points}, the standings #{shown}"
              ),
            else: acc
        end)

      {:error, reason} ->
        fail(st, "after round #{r}: no TRF: #{inspect(reason, limit: 6)}")
    end
  end

  # What OpenResults is sent. It adds the per-round figures up; a round with
  # no figure for a player is "unknown" from there on.
  defp check_snapshot(st, r) do
    t = tournament(st)

    for n <- 1..r, do: {:ok, _} = Tournaments.publish_round_now(Tournaments.get_round(t.id, n))
    for n <- 1..r, do: Tournaments.publish_results(tournament(st), n)
    Tournaments.publish_standings_through(tournament(st), r)
    t = tournament(st)

    snapshot = Snapshot.build(t)
    after_round = get_in(snapshot, ["standings", "after_round"])
    names = Map.new(snapshot["players"], &{&1["no"], &1["name"]})

    if after_round != r do
      note(st, "snapshot standings after round #{inspect(after_round)}, not #{r}")
    else
      figures =
        for round <- snapshot["rounds"], round["number"] <= after_round, reduce: %{} do
          acc ->
            acc =
              Enum.reduce(round["boards"], acc, fn b, acc ->
                acc
                |> put_figure(b["white"], round["number"], get_in(b, ["points", "white"]))
                |> put_figure(b["black"], round["number"], get_in(b, ["points", "black"]))
              end)

            Enum.reduce(round["byes"], acc, fn b, acc ->
              put_figure(acc, b["player"], round["number"], b["points"])
            end)
        end

      Enum.reduce(snapshot["standings"]["rows"], st, fn row, acc ->
        no = row["player"]
        mine = for n <- 1..after_round, do: Map.get(figures, {no, n}, [])

        cond do
          Enum.any?(mine, &(length(&1) > 1)) ->
            fail(
              acc,
              "snapshot after round #{r}: #{names[no]} has two figures in one round: #{inspect(mine)}"
            )

          Enum.any?(mine, &(&1 == [] or &1 == [nil])) ->
            missing = for {f, n} <- Enum.with_index(mine, 1), f in [[], [nil]], do: n

            fail(
              acc,
              "snapshot after round #{r}: #{names[no]} (#{who(st, names[no])}) has no figure for round(s) #{inspect(missing)} - a dash on the results site from there on"
            )

          abs(Enum.sum(List.flatten(mine)) - row["points"]) > 0.001 ->
            fail(
              acc,
              "snapshot after round #{r}: #{names[no]}'s rounds add up to #{Enum.sum(List.flatten(mine))}, the standings say #{row["points"]}"
            )

          true ->
            acc
        end
      end)
    end
  end

  defp who(st, name) do
    case Enum.find(players(st), &(&1.name == name)) do
      nil ->
        "?"

      p ->
        "#{p.status}, no #{inspect(p.pairing_number)}, joins #{p.start_round}, absent #{inspect(p.absent_rounds)}"
    end
  end

  defp put_figure(acc, no, round, points),
    do: Map.update(acc, {no, round}, [points], &[points | &1])

  ## ---------- out and back in ----------

  # Before round `r` is paired: the tournament as a TRF and as a JSON export,
  # each imported as a new tournament, each paired - and then compared with
  # what the original pairs. Rolled back, so the original goes on untouched.
  defp round_trip(st, r) when r < 2, do: st

  defp round_trip(st, r) do
    if chance(35) do
      t = tournament(st)

      {st, outcomes} =
        Enum.reduce([:original, :json, :trf], {st, %{}}, fn kind, {acc, out} ->
          {:error, {:result, value}} =
            Repo.transaction(fn -> Repo.rollback({:result, pair_copy(kind, t, r)}) end)

          {acc, Map.put(out, kind, value)}
        end)

      original = outcomes.original

      Enum.reduce([:json, :trf], st, fn kind, acc ->
        case Map.fetch!(outcomes, kind) do
          ^original ->
            bump(acc, :"round_trip_#{kind}_same")

          {:skipped, why} ->
            note(acc, "round #{r}: #{kind} round trip skipped: #{why}")
            |> bump(:"round_trip_#{kind}_skipped")

          other when is_list(other) and is_list(original) ->
            # A TRF lists the players who hold a number; one who has not been
            # paired yet has none, and is not in the file to come back.
            unnumbered =
              for p <- players(acc), is_nil(p.pairing_number), into: MapSet.new(), do: p.name

            # And it has no record for a withdrawal (finding F6, open): the
            # file shows a player with nothing in the later rounds, and the
            # import brings them back as active.
            withdrawn =
              for p <- players(acc), p.status == "withdrawn", into: MapSet.new(), do: p.name

            lost = MapSet.difference(roster(original), roster(other))
            gained = MapSet.difference(roster(other), roster(original))

            if kind == :trf and roster(original) != roster(other) and
                 MapSet.subset?(lost, unnumbered) and MapSet.subset?(gained, withdrawn) do
              if MapSet.size(gained) > 0,
                do: bump(acc, :round_trip_trf_withdrawn_came_back),
                else: bump(acc, :round_trip_trf_unnumbered_left_out)
            else
              only_original = MapSet.difference(roster(original), roster(other))
              only_copy = MapSet.difference(roster(other), roster(original))

              fail(
                acc,
                "round #{r}: paired differently after a #{kind} round trip" <>
                  " [only in the original: #{Enum.map_join(only_original, "; ", &"#{&1} (#{who(acc, &1)})")}]" <>
                  " [only in the copy: #{Enum.map_join(only_copy, "; ", &"#{&1} (#{who(acc, &1)})")}]" <>
                  "
  original #{inspect(original, limit: 60)}
  #{kind}     #{inspect(other, limit: 60)}"
              )
            end

          other when kind == :trf and is_list(other) ->
            # The original cannot be paired and the copy can: the withdrawn
            # are back (F6 again).
            if Enum.any?(players(acc), &(&1.status == "withdrawn")),
              do: bump(acc, :round_trip_trf_withdrawn_came_back),
              else: fail(acc, "round #{r}: the trf copy pairs a round the original cannot")

          other ->
            fail(
              acc,
              "round #{r}: paired differently after a #{kind} round trip\n  original #{inspect(original, limit: 60)}\n  #{kind}     #{inspect(other, limit: 60)}"
            )
        end
      end)
    else
      st
    end
  end

  defp roster(boards) do
    for {_board, w, b} <- boards, name <- [w, b], not is_nil(name), into: MapSet.new(), do: name
  end

  defp pair_copy(:original, t, _r), do: pair_names(t)

  defp pair_copy(:json, t, _r) do
    scope = PairingsEngine.AccountsFixtures.user_scope_fixture()
    data = t |> TournamentExport.export_tournament() |> Jason.encode!() |> Jason.decode!()

    case TournamentImport.import(data, scope) do
      {:ok, [copy]} -> pair_names(copy)
      other -> {:skipped, inspect(other, limit: 6)}
    end
  end

  defp pair_copy(:trf, t, _r) do
    with {:ok, text} <- TrfExport.export(t),
         {:ok, copy, _warnings} <- TrfImport.import_text(text) do
      pair_names(copy)
    else
      other -> {:skipped, inspect(other, limit: 6)}
    end
  end

  defp pair_names(t) do
    case Pairing.pair_next_round(Tournaments.get_tournament!(t.id)) do
      {:ok, round} ->
        names = Map.new(Tournaments.list_players(t.id), &{&1.id, &1.name})

        Repo.all(
          from p in PairingsEngine.Tournaments.Pairing,
            where: p.round_id == ^round.id,
            order_by: p.board
        )
        |> Enum.map(&{&1.board, names[&1.white_player_id], names[&1.black_player_id]})

      {:error, reason} ->
        {:error, inspect(reason, limit: 6)}
    end
  end

  ## ---------- the engine's own checker ----------

  defp check_with_engine(%{replayable?: false} = st), do: bump(st, :engine_check_not_asked)

  defp check_with_engine(st) do
    t = tournament(st)

    case TrfExport.export(t) do
      {:ok, text} ->
        path =
          Path.join(
            System.tmp_dir!(),
            "apppath-#{st.seed}-#{System.unique_integer([:positive])}.trf"
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

        File.rm(path)

        rounds_differ? = Regex.match?(~r/round \d+: (?!matches)/, output)

        cond do
          Process.get(:check_code) == 0 ->
            bump(st, :engine_check_ok)

          # A bye granted for a round not yet paired travels as a `240`
          # record, and the checker credits it in the score it ranks by; the
          # file's rank column is the standings as they are. The rounds are
          # what is asked of it then. (Observation O1 in the audit.)
          String.contains?(text, "\n240 ") and not rounds_differ? ->
            bump(st, :engine_check_rounds_ok_future_bye)

          # A player nobody has paired yet has no number and is not in the
          # file, but has a place in the standings (finding F9, open).
          Enum.any?(players(st), &is_nil(&1.pairing_number)) and not rounds_differ? ->
            bump(st, :engine_check_rounds_ok_unnumbered_ranked)

          true ->
            if dir = System.get_env("APP_PATH_FUZZ_TRF_DIR") do
              File.mkdir_p!(dir)
              File.write!(Path.join(dir, "seed-#{st.seed}.trf"), text)
              File.write!(Path.join(dir, "seed-#{st.seed}.check.txt"), output)
            end

            fail(
              st,
              "the engine's checker does not reproduce the exported TRF:\n" <>
                String.slice(output, 0, 600)
            )
        end

      {:error, reason} ->
        fail(st, "no TRF at the end: #{inspect(reason, limit: 6)}")
    end
  end
end
