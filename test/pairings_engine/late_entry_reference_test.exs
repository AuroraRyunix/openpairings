defmodule PairingsEngine.LateEntryReferenceTest do
  @moduledoc """
  Round-1 absentees and late entrants in a NEW Swiss (C.04.2 2.4,
  `Tournament`'s `round_one_absentees_late`), through the app's own path,
  against a reference that never reads the app's numbers.

  Each random tournament is made with `Tournaments.create_tournament/2` and
  paired with `Pairing.pair_next_round/1` - what the Pairings page's button
  runs. Players are absent from round 1, join in a later start round, are
  entered while the event is under way, and go missing for a round now and
  then; sometimes round 1 is unpaired and paired again with the absences
  changed (the production case). Before every round this file works out
  the pairing numbers itself, from the C.04.2 text:

    * round 1 numbers the players present, by rating, 1..N - whoever is
      absent gets nothing;
    * a player arriving later is numbered on the round they arrive:
      `late_entry_numbering` "rating" puts them before the first numbered
      player they outrank, everybody from there on one down; "after" gives
      them the next number.

  Then (1) every number the app holds must be the reference's, and nobody
  unarrived may hold one; (2) the round the app paired must be the one
  bbpPairings pairs from a TRF this file builds from the stored games and
  the reference numbers (`0000 - Z` for a round a player missed, and for
  the round being paired when they are not in it). A difference is checked
  with Ainalrami on the same file, to tell a reference's own mind from the
  app's input.

  Ratings are distinct, so rating order is the whole initial order (title
  and name never decide). Not Baku: Group A and its virtual points are
  `baku_reference_test.exs`'s and `baku_group_a_test.exs`'s.

  `LATE_FUZZ_COUNT` (unset: skipped), `LATE_FUZZ_FIRST` (1),
  `LATE_FUZZ_BBP` (a bbpPairings binary instead of the vendored one - the
  one with the C2 bit-field fix), `LATE_FUZZ_DUMP` (file for the
  differences). Every tournament runs in its own sandbox owner, so a big
  count is fine.
  """

  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias PairingsEngine.{Pairing, Repo, Tournaments}
  alias PairingsEngine.Accounts.{Scope, User}
  alias Ainalrami.Trf

  @moduletag :bbppairings
  @moduletag capture_log: true

  if System.get_env("LATE_FUZZ_COUNT") in [nil, ""] do
    @moduletag skip: "set LATE_FUZZ_COUNT to run"
  end

  @tag timeout: :infinity
  test "numbers and pairings of new Swiss tournaments with round-1 absentees match the reference" do
    first = env_int("LATE_FUZZ_FIRST", 1)
    count = env_int("LATE_FUZZ_COUNT", 4)

    results = for seed <- first..(first + count - 1), do: run_seed(seed)

    totals =
      Enum.reduce(results, %{}, fn r, acc -> Map.merge(acc, r.stats, fn _, a, b -> a + b end) end)

    failures = Enum.flat_map(results, & &1.failures)

    if path = System.get_env("LATE_FUZZ_DUMP"),
      do: File.write!(path, Enum.join(failures, "\n\n"))

    IO.puts(
      "\nLATEFUZZ tournaments=#{count} " <>
        Enum.map_join(Enum.sort(totals), " ", fn {k, v} -> "#{k}=#{v}" end) <>
        " failures=#{length(failures)}"
    )

    assert failures == [], Enum.join(Enum.take(failures, 3), "\n\n")
  end

  defp env_int(name, default) do
    case Integer.parse(System.get_env(name) || "") do
      {v, ""} -> v
      _ -> default
    end
  end

  defp chance(pct), do: :rand.uniform(100) <= pct

  ## ---------- one tournament ----------

  defp run_seed(seed) do
    owner = Sandbox.start_owner!(Repo, shared: false, ownership_timeout: 1_800_000)

    try do
      :rand.seed(:exsss, {seed, seed * 7919, seed * 104_729})
      play(seed)
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

  defp play(seed) do
    n = Enum.random(6..40)
    rounds = Enum.random(4..9) |> min(n - 1)
    numbering = Enum.random(~w(rating after))

    user =
      Repo.insert!(%User{
        email: "late#{seed}-#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    {:ok, t} =
      Tournaments.create_tournament(Scope.for_user(user), %{
        "name" => "Late #{seed}",
        "type" => "swiss",
        "rounds_count" => rounds,
        "initial_colour" => "white",
        "late_entry_numbering" => numbering
      })

    true = t.round_one_absentees_late

    # LATE_FUZZ_OLD=1: the negative control - a tournament from before the
    # rule, which the reference must catch numbering its absentees.
    t =
      if System.get_env("LATE_FUZZ_OLD") == "1" do
        t
        |> Ecto.Changeset.change(round_one_absentees_late: false)
        |> Repo.update!()
      else
        t
      end

    st = %{
      seed: seed,
      t: t,
      rounds: rounds,
      numbering: numbering,
      ratings: Enum.take_random(1000..2800, 200),
      next: 1,
      # The reference's numbers: player id => number.
      numbers: %{},
      stats: %{},
      failures: []
    }

    st =
      Enum.reduce(1..n, st, fn _, acc ->
        cond do
          chance(12) -> add_player(acc, 1, "1")
          chance(5) -> add_player(acc, 1, "1,2")
          chance(8) -> add_player(acc, Enum.random(2..3), "")
          true -> add_player(acc, 1, "")
        end
      end)

    st =
      if chance(40),
        do: repair_round_one(st),
        else: st

    Enum.reduce_while(1..rounds, st, fn r, acc ->
      acc = if r > 1, do: before_round(acc, r), else: acc

      case pair(acc, r) do
        {:ok, acc} -> {:cont, acc}
        {:halt, acc} -> {:halt, acc}
      end
    end)
    |> Map.take([:stats, :failures])
  end

  defp bump(st, key, by \\ 1), do: %{st | stats: Map.update(st.stats, key, by, &(&1 + by))}
  defp fail(st, text), do: %{st | failures: ["seed #{st.seed}: " <> text | st.failures]}

  defp add_player(st, start_round, absent_rounds) do
    i = st.next
    [rating | ratings] = st.ratings

    {:ok, _} =
      Tournaments.create_player(st.t.id, %{
        "name" => "P#{String.pad_leading("#{i}", 3, "0")}, Late#{st.seed}",
        "fide_rating" => rating,
        "start_round" => start_round,
        "absent_rounds" => absent_rounds
      })

    %{st | next: i + 1, ratings: ratings}
  end

  # Round 1 paired, unpaired, and paired again with somebody absent the
  # first time now present and somebody present then now absent.
  defp repair_round_one(st) do
    case Pairing.pair_next_round(Tournaments.get_tournament!(st.t.id)) do
      {:ok, _round} ->
        :ok = Pairing.delete_round(st.t.id, 1)
        players = Tournaments.list_players(st.t.id)

        case Enum.filter(players, &(1 in absent_rounds(&1))) do
          [] -> :ok
          absent -> set_absent(Enum.random(absent), [])
        end

        if chance(50) do
          present = Enum.filter(players, &playing?(&1, 1))
          if length(present) > 6, do: set_absent(Enum.random(present), [1])
        end

        bump(st, :round_one_repaired)

      {:error, _} ->
        st
    end
  end

  defp set_absent(player, rounds) do
    player = Repo.reload!(player)
    kept = player |> absent_rounds() |> Enum.reject(&(&1 == 1))

    {:ok, _} =
      Tournaments.update_player(player, %{
        "absent_rounds" => (kept ++ rounds) |> Enum.sort() |> Enum.join(",")
      })
  end

  defp before_round(st, r) do
    st = if chance(25), do: add_player(st, r, ""), else: st

    if chance(30) do
      present =
        st.t.id
        |> Tournaments.list_players()
        |> Enum.filter(&(arrived?(&1, r) and r not in absent_rounds(&1)))

      if length(present) > 6 do
        p = Enum.random(present)

        {:ok, _} =
          Tournaments.update_player(p, %{
            "absent_rounds" => Enum.join(absent_rounds(p) ++ [r], ",")
          })
      end
    end

    st
  end

  defp arrived?(p, r), do: (p.start_round || 1) <= r

  defp absent_rounds(p),
    do: PairingsEngine.Tournaments.Player.parse_absent_rounds(p.absent_rounds)

  defp playing?(p, r), do: arrived?(p, r) and r not in absent_rounds(p)

  ## ---------- the reference numbering ----------

  defp reference_numbers(_st, players, 1) do
    players
    |> Enum.filter(&playing?(&1, 1))
    |> Enum.sort_by(&(-&1.fide_rating))
    |> Enum.with_index(1)
    |> Map.new(fn {p, n} -> {p.id, n} end)
  end

  defp reference_numbers(st, players, r) do
    arrivals =
      players
      |> Enum.filter(&(playing?(&1, r) and not Map.has_key?(st.numbers, &1.id)))
      |> Enum.sort_by(&(-&1.fide_rating))

    rating = Map.new(players, &{&1.id, &1.fide_rating})

    Enum.reduce(arrivals, st.numbers, fn p, numbers ->
      highest = numbers |> Map.values() |> Enum.max(fn -> 0 end)

      at =
        if st.numbering == "rating" do
          numbers
          |> Enum.filter(fn {id, _n} -> rating[id] < p.fide_rating end)
          |> Enum.map(&elem(&1, 1))
          |> Enum.min(fn -> nil end)
        end

      case at do
        nil ->
          Map.put(numbers, p.id, highest + 1)

        at ->
          numbers
          |> Map.new(fn {id, n} -> if n >= at, do: {id, n + 1}, else: {id, n} end)
          |> Map.put(p.id, at)
      end
    end)
  end

  ## ---------- one round ----------

  defp pair(st, r) do
    players = Tournaments.list_players(st.t.id)
    waiting = Enum.count(players, &(not playing?(&1, r) and not Map.has_key?(st.numbers, &1.id)))
    st = if waiting > 0, do: bump(st, :rounds_with_unnumbered_absentees), else: st
    expected = reference_numbers(st, players, r)
    st = %{st | numbers: expected}

    case Pairing.pair_next_round(Tournaments.get_tournament!(st.t.id)) do
      {:ok, round} ->
        st = check_numbers(st, r)
        st = compare(st, round, r)
        enter_results(round)
        {:ok, bump(st, :rounds)}

      {:error, reason} ->
        # The engine found no legal round: counted, and the event stops.
        _ = reason
        {:halt, bump(st, :halted)}
    end
  end

  defp check_numbers(st, r) do
    actual =
      st.t.id
      |> Tournaments.list_players()
      |> Enum.filter(&is_integer(&1.pairing_number))
      |> Map.new(&{&1.id, &1.pairing_number})

    if actual == st.numbers do
      bump(st, :numbers_ok)
    else
      fail(
        st,
        "round #{r}: numbers differ\n  app:       #{inspect(Enum.sort_by(actual, &elem(&1, 1)))}\n" <>
          "  reference: #{inspect(Enum.sort_by(st.numbers, &elem(&1, 1)))}"
      )
    end
  end

  defp compare(st, round, r) do
    players = Tournaments.list_players(st.t.id)
    trf = reference_trf(st, players, r)
    by_rank = Map.new(st.numbers, fn {id, n} -> {n, id} end)

    ours =
      round
      |> Repo.preload(:pairings, force: true)
      |> Map.fetch!(:pairings)
      |> Enum.map(&{&1.white_player_id, &1.black_player_id})
      |> Enum.sort()

    case bbp(trf) do
      {:ok, pairs} ->
        theirs = pairs |> Enum.map(fn {w, b} -> {by_rank[w], by_rank[b]} end) |> Enum.sort()

        cond do
          theirs == ours ->
            bump(st, :rounds_agree)

          ainalrami(trf, st.rounds, by_rank) == ours ->
            st
            |> bump(:bbp_alone_differs)
            |> fail("round #{r}: bbp differs, Ainalrami agrees with the app\n#{trf}")

          true ->
            fail(
              st,
              "round #{r}: app #{inspect(ours)}\n  bbp #{inspect(theirs)}\n#{trf}"
            )
        end

      {:error, out} ->
        fail(st, "round #{r}: bbp refused: #{out}\n#{trf}")
    end
  end

  defp ainalrami(trf, rounds, by_rank) do
    parsed = Trf.parse(trf)

    parsed.players
    |> Ainalrami.Pairing.pair_next_round(
      expected_rounds: rounds,
      initial_colour: parsed.tournament[:initial_colour]
    )
    |> Enum.map(fn {w, b} -> {by_rank[w], b && by_rank[b]} end)
    |> Enum.sort()
  rescue
    _ -> :none
  end

  defp bbp(trf) do
    path = System.get_env("LATE_FUZZ_BBP") || PairingsEngine.Test.BbpPairings.binary_path()
    suffix = :crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false)
    dir = Path.join(System.tmp_dir!(), "late-fuzz-#{suffix}")
    File.mkdir_p!(dir)
    input = Path.join(dir, "in.trf")
    output = Path.join(dir, "out.txt")

    try do
      File.write!(input, trf)

      case System.cmd(path, ["--dutch", input, "-p", output], stderr_to_stdout: true) do
        {_out, 0} -> output |> File.read!() |> PairingsEngine.Test.BbpPairings.parse_pairs()
        {out, code} -> {:error, "exit #{code}: #{out}"}
      end
    after
      File.rm_rf(dir)
    end
  end

  defp enter_results(round) do
    round = Repo.preload(round, :pairings, force: true)

    for p <- round.pairings, p.black_player_id, p.result in [nil, ""] do
      {:ok, _} =
        Tournaments.update_pairing_result(p, Enum.random(["1-0", "0-1", "1/2-1/2", "1-0"]))
    end
  end

  # The state before round `r` in the reference's numbers: every numbered
  # player's games of rounds 1..r-1 (`0000 - Z` for a round without one,
  # the pairing-allocated bye `U`), and `0000 - Z` in round r for a numbered
  # player who is not in it.
  defp reference_trf(st, players, r) do
    rounds =
      st.t.id
      |> Tournaments.list_rounds()
      |> Enum.filter(&(&1.number < r))
      |> Repo.preload(:pairings, force: true)
      |> Enum.sort_by(& &1.number)

    pn = st.numbers

    rows =
      players
      |> Enum.filter(&Map.has_key?(pn, &1.id))
      |> Enum.sort_by(&pn[&1.id])
      |> Enum.map(fn p ->
        games = Enum.map(rounds, &game(&1, p.id, pn))
        points = games |> Enum.map(&points/1) |> Enum.sum()

        games =
          if playing?(p, r),
            do: games,
            else: games ++ [%{opponent_rank: nil, colour: "-", result: "Z"}]

        %{
          rank: pn[p.id],
          name: p.name,
          fide_rating: p.fide_rating,
          points: points,
          games: games
        }
      end)

    Trf.serialize(
      %{
        tournament: %{name: st.t.name, number_of_rounds: st.rounds, initial_colour: "w"},
        players: rows
      },
      xxr: true,
      xxc: true
    )
  end

  defp game(round, id, pn) do
    case Enum.find(round.pairings, &(id in [&1.white_player_id, &1.black_player_id])) do
      nil ->
        %{opponent_rank: nil, colour: "-", result: "Z"}

      %{black_player_id: nil} ->
        %{opponent_rank: nil, colour: "-", result: "U"}

      %{white_player_id: ^id} = p ->
        %{opponent_rank: pn[p.black_player_id], colour: "w", result: code(p.result, :white)}

      p ->
        %{opponent_rank: pn[p.white_player_id], colour: "b", result: code(p.result, :black)}
    end
  end

  defp code("1-0", :white), do: "1"
  defp code("1-0", :black), do: "0"
  defp code("0-1", :white), do: "0"
  defp code("0-1", :black), do: "1"
  defp code("1/2-1/2", _), do: "="

  defp points(%{result: r}) when r in ["1", "U"], do: 1.0
  defp points(%{result: "="}), do: 0.5
  defp points(_), do: 0.0
end
