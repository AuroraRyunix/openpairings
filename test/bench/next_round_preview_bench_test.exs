defmodule PairingsEngine.Bench.NextRoundPreviewBenchTest do
  @moduledoc """
  How long the next-round preview takes on a large generated Swiss, with 1,
  3 and 6 games of round 4 still open (3, 27 and 729 outcomes, each a full
  pairing of round 5). Not a test of anything: excluded from every run
  unless asked for, and it prints its timings.

      mix test test/bench/next_round_preview_bench_test.exs --include bench

  `BENCH_SIZES` (default `200,600`), `BENCH_OPEN` (default `1,3,6`) and
  `BENCH_CONCURRENCY` (default: `NextRoundPreview.concurrency/0`) choose
  the runs. `+S 2:2` in `ELIXIR_ERL_OPTIONS` imitates the 2-vCPU server.
  """
  use ExUnit.Case, async: false

  import PairingsEngine.NextRoundPreviewFixture

  alias PairingsEngine.{NextRoundPreview, Tournaments}

  @moduletag :bench
  @moduletag timeout: :infinity

  # A 600-player field with six open games takes minutes, far past the
  # sandbox's default two-minute ownership.
  setup do
    owner =
      Ecto.Adapters.SQL.Sandbox.start_owner!(PairingsEngine.Repo,
        shared: true,
        ownership_timeout: :infinity
      )

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
  end

  test "preview timings" do
    sizes = env_list("BENCH_SIZES", [200, 600])
    open = env_list("BENCH_OPEN", [1, 3, 6])

    case System.get_env("BENCH_CONCURRENCY") do
      nil ->
        :ok

      n ->
        Application.put_env(
          :pairings_engine,
          :next_round_preview_concurrency,
          String.to_integer(n)
        )
    end

    on_exit(fn -> Application.delete_env(:pairings_engine, :next_round_preview_concurrency) end)

    IO.puts(
      "\n[bench] schedulers #{System.schedulers_online()}, preview concurrency #{NextRoundPreview.concurrency()}"
    )

    for size <- sizes do
      t = plain_tournament(size, %{rounds_count: 9})

      for _ <- 1..3 do
        pair!(t)
        finish_latest_round(t)
      end

      pair!(t)

      for k <- open do
        leave_only_open(t, k)
        {us, {:ok, preview}} = :timer.tc(fn -> NextRoundPreview.run(reload(t)) end)

        IO.puts(
          "[bench] #{size} players, #{k} open (#{preview.outcomes} outcomes): " <>
            "#{Float.round(us / 1_000_000, 2)} s - fixed #{length(preview.fixed)}, " <>
            "shifting #{length(preview.shifting)}, colours open #{length(preview.colours_open)}, " <>
            "open players #{length(preview.open)}, bye #{preview.bye.status}"
        )
      end
    end
  end

  # Round 4 with exactly `k` boards open: every other board gets a result,
  # and boards that should be open again are cleared.
  defp leave_only_open(t, k) do
    round = latest_round(t)
    games = round.pairings |> Enum.filter(& &1.black_player_id) |> Enum.sort_by(& &1.board)
    # Open games from the top of the round, where they matter most.
    {open, rest} = Enum.split(games, k)

    for p <- open, p.result != "", do: {:ok, _} = Tournaments.update_pairing_result(p, "")

    for p <- rest,
        p.result == "",
        do: {:ok, _} = Tournaments.update_pairing_result(p, default_result(p.board))
  end

  defp env_list(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> value |> String.split(",") |> Enum.map(&String.to_integer/1)
    end
  end
end
