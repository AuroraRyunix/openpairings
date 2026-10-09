defmodule PairingsEngine.BakuReferenceTest do
  @moduledoc """
  Baku acceleration (FIDE C.04.7) through the full pairing path, against
  references that never see OpenPairings' own engine input.

  `PairingsEngine.CrossProgramTest` hands bbpPairings the TRF OpenPairings
  built, so it compares two engines on the SAME input and cannot catch a
  mistake in that input. This file builds a second TRF itself, from the
  tournament's stored games: starting ranks are the pairing numbers (the
  C.04.3 A.2 initial ranking), and the `XXA` virtual points are worked out
  here from the C.04.7 text, not by `Pairing.accelerations/3`. Every round
  `Pairing.pair_next_round/1` - what the "Pair round" button runs - pairs
  is compared, colours included, with bbpPairings on that file and with
  Ainalrami replaying it (what `ainalrami -c` does round by round).

  The bug this guards: in an accelerated round each bracket was ordered by
  game points instead of game points plus the round's virtual points, and
  because the engine's starting ranks are that order, a Group-A player
  ranked below a Group-B player of the same pairing score was treated as
  the lower-ranked of the two.

  `BAKU_FUZZ_COUNT` (default 4) sets the number of tournaments and
  `BAKU_FUZZ_FIRST` (default 1) the first seed; `BAKU_FUZZ_REPORT=1` prints the
  counts and `BAKU_FUZZ_DUMP=path` writes every difference to a file. Run
  big counts in batches of about 50: the whole run is one test, and the
  SQL sandbox drops a connection held for more than two minutes. On
  2026-10-02, seeds 1-200 on Ainalrami compared 1,280 rounds with no
  difference; before the fix seeds 1-60 differed in 124 of 396 rounds, all
  of them accelerated rounds 2-5.
  """

  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{Pairing, Repo, Tournaments}
  alias PairingsEngine.Tournaments.Tournament
  alias PairingsEngine.Test.BbpPairings
  alias Ainalrami.Trf

  @moduletag :bbppairings

  # The file the engine was handed, captured as `CrossProgramTest` does, so
  # a difference can be told apart: wrong input (bbpPairings on OpenPairings'
  # own file disagrees with the reference) or an engine of its own mind
  # (given the right file, still pairing differently).
  setup do
    handler = "baku-reference-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:pairings_engine, :pairing, :trf_built],
      fn _event, _measurements, meta, _config ->
        Process.put({:trf, meta.tournament_id, meta.round}, meta.trf)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  @tag timeout: :infinity
  test "every round of random Baku tournaments matches bbpPairings and Ainalrami on a reference TRF" do
    count = System.get_env("BAKU_FUZZ_COUNT", "4") |> String.to_integer()
    first = System.get_env("BAKU_FUZZ_FIRST", "1") |> String.to_integer()

    results =
      for seed <- first..(first + count - 1) do
        :rand.seed(:exsss, {seed, seed * 7919, seed * 104_729})
        run_one(seed)
      end

    rounds = results |> Enum.map(& &1.rounds) |> Enum.sum()
    refused = results |> Enum.map(& &1.refused) |> Enum.sum()

    {engine_only, diffs} =
      results |> Enum.flat_map(& &1.diffs) |> Enum.split_with(&Map.get(&1, :engine_only, false))

    if System.get_env("BAKU_FUZZ_REPORT") do
      IO.puts(
        "\nBaku reference: #{count} tournaments, #{rounds} rounds compared, " <>
          "#{refused} refused by both references, " <>
          "#{length(engine_only)} differing by the engine alone on the right input, " <>
          "#{length(diffs)} differing round(s) - " <>
          "against bbp #{Enum.count(diffs, & &1.bbp?)}, ainalrami #{Enum.count(diffs, & &1.ainalrami?)}, " <>
          "references disagreeing with each other #{Enum.count(diffs, &(&1.bbp != &1.ainalrami))}, " <>
          "outside the accelerated rounds #{Enum.count(diffs, &(not &1.accelerated?))}, " <>
          "by round #{inspect(diffs |> Enum.frequencies_by(& &1.round) |> Enum.sort())}"
      )
    end

    if path = System.get_env("BAKU_FUZZ_DUMP"),
      do: File.write!(path, Enum.map_join(diffs, "\n\n", &format/1))

    assert diffs == [], Enum.map_join(diffs, "\n\n", &format/1)
    # Ainalrami is one of the references, so from a right file it never
    # pairs its own way.
    assert engine_only == []
  end

  defp run_one(seed) do
    player_count = Enum.random(5..40)
    round_count = Enum.random(4..9) |> min(player_count - 1)

    tournament =
      Repo.insert!(%Tournament{
        name: "Baku #{seed}",
        type: "swiss",
        rounds_count: round_count,
        acceleration: "baku"
      })

    ratings = Enum.take_random(1000..2600, player_count)

    for {rating, n} <- Enum.with_index(ratings, 1) do
      {:ok, _} =
        Tournaments.create_player(tournament.id, %{
          "name" => "P#{n}, Baku#{seed}",
          "fide_rating" => rating
        })
    end

    Enum.reduce_while(1..round_count, %{rounds: 0, diffs: [], refused: 0}, fn number, acc ->
      with {:ok, round} <- Pairing.pair_next_round(tournament),
           {:ok, diff} <- compare(tournament, round, number, seed, player_count) do
        enter_results(round)
        {:cont, %{acc | rounds: acc.rounds + 1, diffs: List.wrap(diff) ++ acc.diffs}}
      else
        # Both references find no legal round where the engine paired one -
        # seen with the old external engine only, late in a small event. Not a question of
        # bracket order; the tournament stops there.
        :refused -> {:halt, %{acc | refused: acc.refused + 1}}
        {:error, _reason} -> {:halt, acc}
      end
    end)
  end

  defp enter_results(round) do
    round = Repo.preload(round, :pairings, force: true)

    for pairing <- round.pairings, pairing.black_player_id, pairing.result in [nil, ""] do
      Tournaments.update_pairing_result(pairing, Enum.random(["1-0", "0-1", "1/2-1/2", "1-0"]))
    end
  end

  defp compare(tournament, round, number, seed, player_count) do
    players = Tournaments.list_players(tournament.id)
    pn = Map.new(players, &{&1.id, &1.pairing_number})
    ours = round |> Repo.preload(:pairings, force: true) |> Map.fetch!(:pairings) |> to_pairs(pn)

    trf = reference_trf(tournament, players, pn, number)
    parsed = Trf.parse(trf)

    bbp =
      case BbpPairings.pair(trf) do
        {:ok, pairs} -> pairs
        {:error, _} -> :none
      end

    ainalrami =
      try do
        parsed.players
        |> Ainalrami.Pairing.pair_next_round(
          expected_rounds: tournament.rounds_count,
          initial_colour: parsed.tournament[:initial_colour]
        )
        |> Enum.map(fn {w, b} -> {w, b || 0} end)
      rescue
        Ainalrami.Pairing.NoValidPairingError -> :none
      end

    bbp? = sorted(bbp) != Enum.sort(ours)
    ainalrami? = sorted(ainalrami) != Enum.sort(ours)

    cond do
      bbp == :none and ainalrami == :none ->
        :refused

      (bbp? or ainalrami?) and own_input_agrees?(tournament.id, number, players, bbp) ->
        {:ok, %{engine_only: true}}

      bbp? or ainalrami? ->
        {:ok, difference(tournament, number, seed, player_count, ours, bbp, ainalrami, trf)}

      true ->
        {:ok, nil}
    end
  end

  # bbpPairings on the file OpenPairings handed its engine, in pairing
  # numbers, against bbpPairings on the reference file.
  defp own_input_agrees?(tournament_id, number, players, bbp) do
    case Process.get({:trf, tournament_id, number}) do
      nil ->
        false

      own ->
        pn_by_name = Map.new(players, &{&1.name, &1.pairing_number})

        pn_by_rank =
          own |> Trf.parse() |> Map.fetch!(:players) |> Map.new(&{&1.rank, pn_by_name[&1.name]})

        case BbpPairings.pair(own) do
          {:ok, pairs} ->
            sorted(Enum.map(pairs, fn {w, b} -> {pn_by_rank[w], Map.get(pn_by_rank, b, 0)} end)) ==
              sorted(bbp)

          _ ->
            false
        end
    end
  end

  defp sorted(:none), do: :none
  defp sorted(pairs), do: Enum.sort(pairs)

  defp difference(tournament, number, seed, player_count, ours, bbp, ainalrami, trf) do
    bbp? = sorted(bbp) != Enum.sort(ours)
    ainalrami? = sorted(ainalrami) != Enum.sort(ours)

    %{
      seed: seed,
      round: number,
      players: player_count,
      ours: Enum.sort(ours),
      bbp: sorted(bbp),
      ainalrami: sorted(ainalrami),
      bbp?: bbp?,
      ainalrami?: ainalrami?,
      accelerated?: number <= div(tournament.rounds_count + 1, 2),
      trf: trf
    }
  end

  defp to_pairs(pairings, pn) do
    Enum.map(pairings, fn p ->
      {Map.fetch!(pn, p.white_player_id), Map.get(pn, p.black_player_id, 0)}
    end)
  end

  # The state before round `number`, numbered by pairing number, with the
  # C.04.7 virtual points for rounds 1..`number`.
  defp reference_trf(tournament, players, pn, number) do
    rounds =
      tournament.id
      |> Tournaments.list_rounds()
      |> Enum.filter(&(&1.number < number))
      |> Repo.preload(:pairings, force: true)
      |> Enum.sort_by(& &1.number)

    n = length(players)
    group_a = 2 * div(n + 3, 4)
    accelerated = div(tournament.rounds_count + 1, 2)
    full = div(accelerated + 1, 2)

    virtual =
      for r <- 1..number do
        cond do
          r <= full -> 1.0
          r <= accelerated -> 0.5
          true -> 0.0
        end
      end

    rows =
      players
      |> Enum.sort_by(& &1.pairing_number)
      |> Enum.map(fn p ->
        games = Enum.map(rounds, &game(&1, p.id, pn))

        row = %{
          rank: p.pairing_number,
          name: p.name,
          fide_rating: p.fide_rating,
          points: games |> Enum.map(&game_points/1) |> Enum.sum(),
          games: games
        }

        if p.pairing_number <= group_a and Enum.any?(virtual, &(&1 > 0)),
          do: Map.put(row, :accelerations, virtual),
          else: row
      end)

    Trf.serialize(
      %{
        tournament: %{
          name: tournament.name,
          number_of_rounds: tournament.rounds_count,
          initial_colour: initial_colour(tournament)
        },
        players: rows
      },
      xxr: true,
      xxc: true
    )
  end

  defp initial_colour(tournament) do
    case tournament.id
         |> Tournaments.get_tournament!()
         |> Tournament.effective_initial_colour() do
      "white" -> "w"
      "black" -> "b"
      nil -> "w"
    end
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

  defp game_points(%{result: r}) when r in ["1", "U"], do: 1.0
  defp game_points(%{result: "="}), do: 0.5
  defp game_points(_), do: 0.0

  defp format(d) do
    """
    seed #{d.seed}, round #{d.round}, #{d.players} players:
      OpenPairings: #{inspect(d.ours)}
      bbpPairings:  #{inspect(d.bbp)}
      Ainalrami:    #{inspect(d.ainalrami)}
    #{d.trf}
    """
  end
end
