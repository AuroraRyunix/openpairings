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

  Every third tournament (the seeds divisible by 3) allows postponed games
  (audit part 2): some boards are postponed - by White, by Black, by nobody
  in particular - under a random valuation for the player who asked and the
  one who did not; some are played later, some never. Then, on top:

    * the standings count an open postponed board as what the tournament's
      setting said when it was postponed, worked out here and not asked of
      the app - and the engine was paired on the standings (above);
    * the snapshot says `provisional` exactly while a postponed game is open
      in the rounds its standings cover, and counts them right;
    * at the end the rounds are sent for rating, the games still open are
      played and sent as late games, and over all the files every game
      played over the board is there once: not twice, not never.

  APP_PATH_FUZZ_COUNT (default 6), APP_PATH_FUZZ_FIRST (default 1).
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ainalrami.Trf
  alias Ecto.Adapters.SQL.Sandbox

  alias PairingsEngine.{
    Pairing,
    PostponedGames,
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

    # Baku, or the players' extra points in the pairing (as acceleration, or
    # as a handicap that counts), or neither. The changeset refuses both.
    {acceleration, extra_mode, count_extra} =
      Enum.random([
        {"none", "handicap", false},
        {"none", "handicap", false},
        {"none", "handicap", false},
        {"baku", "handicap", false},
        {"none", "acceleration", false},
        {"none", "handicap", true}
      ])

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
      "acceleration" => acceleration,
      "extra_points_mode" => extra_mode,
      "count_extra_points" => count_extra,
      "ask_bye_type" => chance(30),
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

    # Postponed games: every third seed, decided off the seed and not off
    # the generator, so the other two thirds are the tournaments they were
    # before this axis existed.
    postponed? = rem(seed, 3) == 0
    outcomes = ~w(draw win loss)

    attrs =
      if postponed?,
        do:
          Map.merge(attrs, %{
            "postponed_games" => true,
            "postponed_requester_outcome" => Enum.at(outcomes, rem(div(seed, 3), 3)),
            "postponed_opponent_outcome" => Enum.at(outcomes, rem(div(seed, 9), 3))
          }),
        else: attrs

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
      postponed?: postponed?,
      # pairing id => {round, what White counts as, what Black counts as}
      # while the board waits, by the tournament's setting when postponed.
      postponed: %{},
      dates: dates,
      stats: %{},
      failures: []
    }

    st =
      note(
        st,
        "config " <>
          inspect(
            Map.take(
              attrs,
              ~w(acceleration extra_points_mode count_extra_points ask_bye_type points_win bye_value abs_value late_entry_numbering)
            )
          )
      )

    st = Enum.reduce(1..n, st, fn _, acc -> add_player(acc, 1) end)
    st = maybe_forbid(st)

    Enum.reduce_while(1..rounds, st, fn r, acc ->
      acc = before_round(acc, r)
      acc = play_postponed(acc, 40)
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
            |> check_postponed_valuation(r)
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
    |> check_rated_once()
  end

  defp tournament(st), do: Tournaments.get_tournament!(st.tid)

  # The Pairings page's confirmation that an older postponed game is still
  # open - the one thing pairing asks about them, and nothing when there is
  # none.
  @pair_ack [acknowledged: [:adjourned_older_round_open]]
  defp pair(st), do: Pairing.pair_next_round(tournament(st), @pair_ack)

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
        # Rounded to 50, so some share a rating and the title and the name
        # get to decide (C.04.2 2.2.2, 2.2.3).
        "fide_rating" => if(chance(12), do: 0, else: between(24, 50) * 50),
        "title" => if(chance(20), do: Enum.random(~w(GM IM WGM FM WIM CM WFM WCM)), else: ""),
        "extra_points" => if(chance(25), do: Enum.random([0.5, 1.0]), else: 0.0),
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
        Tournaments.update_player(
          p,
          %{
            "absent_rounds" => Enum.join(kept ++ ["#{r}"], ","),
            # Read only where the tournament asks the bye type.
            "bye_types" => %{"#{r}" => Enum.random(~w(requested-half requested-zero full-point))}
          },
          acknowledged: [:second_half_bye, :sent_round_changed]
        )

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
            acc.postponed? and chance(10) -> Enum.random(~w(* *W *B))
            chance(8) -> Enum.random(~w(1-0FF 0-1FF 0-0FF))
            true -> Enum.random(~w(1-0 0-1 1/2-1/2 1-0 0-1))
          end

        opts = if acc.postponed?, do: [played_on: Enum.at(acc.dates, r - 1)], else: []

        case Tournaments.update_pairing_result(p, result, opts) do
          {:ok, _} -> acc |> bump(:games) |> postponed_now(p, r, result)
          other -> fail(acc, "round #{r}: result #{result} refused: #{inspect(other, limit: 4)}")
        end
      else
        acc
      end
    end)
  end

  # A board just postponed: what each side counts as while it waits, from
  # the tournament's setting as it is now - the player who asked gets the
  # requester's outcome, the other one (and both, when nobody is named) the
  # opponent's. From here on no checker replays the rounds: they were paired
  # on a score that is not in the file.
  defp postponed_now(st, p, r, result) when result in ~w(* *W *B) do
    t = tournament(st)
    asked = t.postponed_requester_outcome
    other = t.postponed_opponent_outcome

    {white, black} =
      case result do
        "*W" -> {asked, other}
        "*B" -> {other, asked}
        "*" -> {other, other}
      end

    %{st | postponed: Map.put(st.postponed, p.id, {r, white, black}), replayable?: false}
    |> bump(:postponed)
  end

  defp postponed_now(st, _p, _r, _result), do: st

  # Open postponed games get played: `pct` percent of them, some days after
  # their round.
  defp play_postponed(%{postponed?: false} = st, _pct), do: st

  defp play_postponed(st, pct) do
    st.tid
    |> PostponedGames.open_games()
    |> Enum.filter(fn _ -> chance(pct) end)
    |> Enum.reduce(st, fn %{round: rn, pairing: p}, acc ->
      result = Enum.random(~w(1-0 0-1 1/2-1/2))

      opts = [
        acknowledged: PostponedGames.acknowledgement_ids(),
        played_on: Date.add(Enum.at(acc.dates, rn - 1), between(1, 30))
      ]

      case Tournaments.update_pairing_result(Repo.reload!(p), result, opts) do
        {:ok, _} ->
          %{acc | postponed: Map.delete(acc.postponed, p.id)} |> bump(:postponed_played)

        other ->
          fail(
            acc,
            "postponed game of round #{rn}: #{result} refused: #{inspect(other, limit: 4)}"
          )
      end
    end)
  end

  # What a waiting board is worth, written out here: the standings must
  # hold exactly this for both players, and the engine is paired on the
  # standings (`check_engine_scores/2`).
  defp check_postponed_valuation(%{postponed?: false} = st, _r), do: st

  defp check_postponed_valuation(st, r) do
    t = tournament(st)
    table = Map.new(Standings.standings(t), &{&1.player.id, &1})
    worth = %{"win" => t.points_win, "draw" => t.points_draw, "loss" => t.points_loss}

    open = MapSet.new(PostponedGames.open_games(st.tid), & &1.pairing.id)

    st =
      if open == MapSet.new(Map.keys(st.postponed)),
        do: st,
        else:
          fail(
            st,
            "after round #{r}: the app holds #{MapSet.size(open)} open postponed games, this run postponed #{map_size(st.postponed)} and has not played them"
          )

    Enum.reduce(st.postponed, st, fn {id, {rn, white, black}}, acc ->
      p = Repo.get!(PairingsEngine.Tournaments.Pairing, id)

      Enum.reduce([{p.white_player_id, white}, {p.black_player_id, black}], acc, fn {pid, as},
                                                                                    acc ->
        record = table |> Map.fetch!(pid) |> Map.fetch!(:games) |> Enum.find(&(&1.round == rn))

        cond do
          is_nil(record) ->
            fail(acc, "after round #{r}: no record of the postponed game of round #{rn}")

          abs(record.points - worth[as]) > 0.001 ->
            fail(
              acc,
              "after round #{r}: a postponed game of round #{rn} counts #{record.points} in the standings, the setting says a #{as} (#{worth[as]})"
            )

          true ->
            acc
        end
      end)
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

          # Not a board that is or was postponed: its result is
          # `play_postponed/2`'s to give.
          if Map.has_key?(st.postponed, p.id) or p.provisional_white do
            st
          else
            case Tournaments.update_pairing_result(p, result, []) do
              {:ok, _} -> %{st | replayable?: false} |> bump(:earlier_edits)
              _refused -> st
            end
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
         Enum.map(numbered, & &1.id) != Enum.map(Enum.sort_by(numbered, &seed_key/1), & &1.id) do
      fail(
        st,
        "pairing numbers do not follow the initial order: " <>
          Enum.map_join(numbered, " ", &"#{&1.pairing_number}:#{Player.rating(&1, t)}")
      )
    else
      st
    end
  end

  # C.04.2 2.2, written out again here rather than borrowed from the app:
  # rating, then title (GM-IM-WGM-FM-WIM-CM-WFM-WCM-none), then the name.
  @titles ~w(GM IM WGM FM WIM CM WFM WCM)
  defp seed_key(p),
    do: {-(p.fide_rating || 0), Enum.find_index(@titles, &(&1 == p.title)) || 8, p.name}

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
        # A postponed board is `?` in the file and worth the file's own `X`,
        # a draw, whatever the tournament counts it as meanwhile
        # (`TrfExport.report_unknown/2`, deliberate). So a player waiting on
        # a board that counts as a win or a loss is not asked here.
        waiting = waiting_on_non_draw(st)

        by_name =
          for e <- table, e.player.id not in waiting, into: %{}, do: {e.player.name, e.points}

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

      # FIDE mode sends no file while a postponed game is open (VCL4THP Q169).
      {:error, {:open_postponed, _games}} when map_size(st.postponed) > 0 ->
        bump(st, :trf_refused_open_postponed)

      {:error, reason} ->
        fail(st, "after round #{r}: no TRF: #{inspect(reason, limit: 6)}")
    end
  end

  defp waiting_on_non_draw(st) do
    for {id, {_round, white, black}} <- st.postponed,
        p = Repo.get!(PairingsEngine.Tournaments.Pairing, id),
        {pid, as} <- [{p.white_player_id, white}, {p.black_player_id, black}],
        as != "draw",
        into: MapSet.new(),
        do: pid
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

    st = check_snapshot_provisional(st, snapshot, after_round)

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

  # `provisional` and the count beside it: exactly the postponed games still
  # open in the rounds the standings cover.
  defp check_snapshot_provisional(%{postponed?: false} = st, _snapshot, _after), do: st
  defp check_snapshot_provisional(st, _snapshot, nil), do: st

  defp check_snapshot_provisional(st, snapshot, after_round) do
    open = Enum.count(st.postponed, fn {_id, {rn, _w, _b}} -> rn <= after_round end)
    said = snapshot["standings"]["postponed_games"] || 0
    flag = snapshot["standings"]["provisional"] == true

    if said == open and flag == open > 0,
      do: st,
      else:
        fail(
          st,
          "snapshot after round #{after_round}: #{open} postponed game(s) open, the standings block says provisional=#{flag}, postponed_games=#{said}"
        )
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

            # Nor for the players' extra points: the rounds paired with them
            # are in the file (`XXA`/`250`), what the next round would be
            # paired with is not.
            extra? = PairingsEngine.Tournaments.Tournament.extra_points_pairing?(tournament(acc))

            # Nor for what a postponed game counts as while it waits: the
            # file says `?`, worth the draw its own `X` declares, and the
            # copy pairs on that draw where the original pairs on the win or
            # the loss the tournament gave the board.
            waiting? = kind == :trf and MapSet.size(waiting_on_non_draw(acc)) > 0

            if (kind == :trf and extra? and roster(original) == roster(other)) or waiting? do
              if waiting?,
                do: bump(acc, :round_trip_trf_postponed_valuation_left_behind),
                else: bump(acc, :round_trip_trf_extra_points_left_behind)
            else
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
            end

          other when kind == :trf and is_list(other) ->
            # The original cannot be paired and the copy can: the withdrawn
            # are back (F6 again).
            if Enum.any?(players(acc), &(&1.status == "withdrawn")),
              do: bump(acc, :round_trip_trf_withdrawn_came_back),
              else: fail(acc, "round #{r}: the trf copy pairs a round the original cannot")

          {:error, _} when kind == :trf and is_list(original) ->
            # And the other way round: the copy is a player short - the one
            # with no number yet - and what is left cannot be paired.
            if Enum.any?(
                 players(acc),
                 &(is_nil(&1.pairing_number) and &1.name in roster(original))
               ),
               do: bump(acc, :round_trip_trf_unnumbered_left_out),
               else: fail(acc, "round #{r}: the trf copy cannot pair a round the original can")

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
    case Pairing.pair_next_round(Tournaments.get_tournament!(t.id), @pair_ack) do
      {:ok, round} ->
        names = Map.new(Tournaments.list_players(t.id), &{&1.id, &1.name})

        Repo.all(
          from p in PairingsEngine.Tournaments.Pairing,
            where: p.round_id == ^round.id,
            order_by: p.board
        )
        |> Enum.map(&{&1.board, names[&1.white_player_id], names[&1.black_player_id]})

      # Why not is not compared: the message counts the players, and a
      # copy may hold fewer (see `round_trip/2`).
      {:error, {reason, _message}} when is_atom(reason) ->
        {:error, reason}

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

          # A handicap that counts is in the pairing and deliberately not
          # in the file as virtual points (`Pairing.accelerated_rows/4`: a
          # head start is not something a pairing checker should add back),
          # so the file's rounds are not the engine's to reproduce.
          t.extra_points_mode == "handicap" and t.count_extra_points ->
            bump(st, :engine_check_handicap_not_in_file)

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

  ## ---------- the files for rating, with postponed games ----------

  # The Export page's "Send": every round, then - once the games still open
  # have been played - the late games, a file per rating period. Over all of
  # them, each game played over the board is there once.
  defp check_rated_once(%{postponed?: false} = st), do: st

  defp check_rated_once(st) do
    t = tournament(st)
    paired = Pairing.paired_rounds_count(st.tid)

    if paired == 0 do
      st
    else
      # FIDE mode sends no round with a postponed game open; "not played in
      # this event" is the arbiter's way past that, and the game is rated
      # later, in the late file.
      st =
        t
        |> PostponedGames.blocking_games()
        |> Enum.reduce(st, fn game, acc ->
          case PostponedGames.report_not_played(t, game.pairing.id) do
            {:ok, _} -> acc
            other -> fail(acc, "not played in this event refused: #{inspect(other, limit: 4)}")
          end
        end)

      t = tournament(st)
      meta = TrfExport.export_meta(t, nil)
      build = fn fresh -> TrfExport.export(fresh, meta.rounds, for: :rating) end

      {st, files} =
        case PostponedGames.send_rounds(t, meta.rounds, build, acknowledged: [:round_sent_before]) do
          {:ok, %{file: text}} ->
            {bump(st, :sent), [text]}

          other ->
            {fail(st, "the rounds could not be sent for rating: #{inspect(other, limit: 6)}"), []}
        end

      # Most of them: a game nobody ever plays stays out of every file.
      st = play_postponed(st, 75)
      t = tournament(st)

      periods =
        t
        |> PostponedGames.sendable_late_games()
        |> Enum.map(&PostponedGames.late_period/1)
        |> Enum.uniq()
        |> Enum.reject(&is_nil/1)

      {st, files} =
        Enum.reduce(periods, {st, files}, fn period, {acc, files} ->
          case PostponedGames.send_late_games(t, &TrfExport.postponed_export(&1, period: period)) do
            {:ok, text, _games, _receipt} ->
              {bump(acc, :late_files), files ++ [text]}

            other ->
              {fail(acc, "late games of #{period} not sent: #{inspect(other, limit: 6)}"), files}
          end
        end)

      # Every board with two players and a result decided over the board,
      # twice (once on each player's line).
      expected =
        2 *
          Enum.count(
            for(r <- 1..paired, b <- boards(st, r), do: b),
            &(&1.white_player_id && &1.black_player_id && &1.result in ~w(1-0 0-1 1/2-1/2))
          )

      written =
        files
        |> Enum.flat_map(fn text -> Trf.parse(text).players end)
        |> Enum.flat_map(& &1.games)
        |> Enum.count(&(&1.result in ~w(1 0 =) and not is_nil(&1.opponent_rank)))

      if written == expected,
        do: st,
        else:
          fail(
            st,
            "the files for rating hold #{written} player-games played over the board, the tournament #{expected}: a game is rated twice, or never"
          )
    end
  end
end
