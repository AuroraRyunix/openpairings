defmodule PairingsEngine.Bench.PairingClickBenchTest do
  @moduledoc """
  How long the "Pair round" click takes on a large generated Swiss, and -
  since the round's explanation is worked out after the click - how long
  that takes to arrive. Not a test of anything: excluded from every run
  unless asked for (`@moduletag :bench`), and it prints its timings.

      $env:ELIXIR_ERL_OPTIONS = "+S 2:2"   # the 2-vCPU server
      mix test test/bench/pairing_click_bench_test.exs --include bench

  `BENCH_SIZES` (comma-separated, default `301,451`) picks the fields. Odd
  on purpose: the bye's alternatives are a dozen full pairings of their own.
  Five rounds, half the games drawn: by round 4 the field has many score
  groups and many floats, and the alternatives are most of the work.

  `BENCH_MODE=inline` works the account out inside the click, as every
  version before this change did - the "before" to compare with.
  """
  use PairingsEngine.DataCase, async: false

  import Ecto.Query

  alias PairingsEngine.{Pairing, Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Round, Tournament}

  @moduletag :bench
  @moduletag timeout: :infinity

  # As on the server: the account is worked out after the click. The suite
  # otherwise runs it inline (config/test.exs).
  setup do
    mode = if System.get_env("BENCH_MODE") == "inline", do: :inline, else: :async
    Application.put_env(:pairings_engine, :explanation_jobs, mode)
    IO.puts("\n[bench] explanation jobs: #{mode}")
    on_exit(fn -> Application.put_env(:pairings_engine, :explanation_jobs, :inline) end)
  end

  test "the pairing click on large fields" do
    sizes =
      (System.get_env("BENCH_SIZES") || "301,451")
      |> String.split(",", trim: true)
      |> Enum.map(&String.to_integer(String.trim(&1)))

    for size <- sizes do
      :rand.seed(:exsss, {size, 7, 11})
      t = generated_event(size)

      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(t.id))

      for number <- 1..5 do
        {micros, {:ok, round}} = :timer.tc(fn -> Pairing.pair_next_round(Repo.reload!(t)) end)
        {wait_micros, _} = :timer.tc(fn -> wait_for_explanation(t, round.number) end)

        IO.puts(
          "\n[bench] #{size} players, round #{number}: click #{ms(micros)} ms, " <>
            "explanation ready #{ms(wait_micros)} ms after the click returned"
        )

        random_results(round)
      end
    end
  end

  defp ms(micros), do: div(micros, 1000)

  defp generated_event(size) do
    t =
      Repo.insert!(%Tournament{
        name: "Bench #{size}",
        type: "swiss",
        rounds_count: 9,
        tiebreaks: ~w(BH),
        pairing_engine: "ainalrami",
        initial_colour: "white",
        round_dates: List.duplicate("2026-09-01", 9)
      })

    for n <- 1..size do
      {:ok, _} =
        Tournaments.create_player(t.id, %{
          "name" => "Player #{n}",
          "fide_rating" => 2700 - n * 3 - :rand.uniform(3)
        })
    end

    t
  end

  defp random_results(round) do
    pairings =
      Repo.all(from p in PairingsEngine.Tournaments.Pairing, where: p.round_id == ^round.id)

    for p <- pairings, p.black_player_id do
      result = Enum.random(["1-0", "0-1", "1/2-1/2", "1/2-1/2"])

      Repo.update_all(from(x in PairingsEngine.Tournaments.Pairing, where: x.id == ^p.id),
        set: [result: result]
      )
    end
  end

  # Before the explanation moved off the click there is nothing to wait for:
  # the round is stored with it. After, the job broadcasts when it is done.
  defp wait_for_explanation(t, number) do
    case Repo.one(from r in Round, where: r.tournament_id == ^t.id and r.number == ^number) do
      %{explanation: %{"status" => "pending"}} ->
        receive do
          {:tournament_changed, _, :explanation} -> wait_for_explanation(t, number)
        after
          1_800_000 -> flunk("no explanation after 30 minutes")
        end

      _ ->
        :ok
    end
  end
end
