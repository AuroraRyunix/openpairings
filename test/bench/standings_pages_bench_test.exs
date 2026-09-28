defmodule PairingsEngineWeb.Bench.StandingsPagesBenchTest do
  @moduledoc """
  How long the pages that compute standings take to load on a large
  generated Swiss (451 players, five rounds), with the standings cache off
  and on. Not a test of anything: excluded unless asked for, prints timings.

      $env:ELIXIR_ERL_OPTIONS = "+S 2:2"   # the 2-vCPU server
      mix test test/bench/standings_pages_bench_test.exs --include bench

  "first" is the first load after a write (nothing cached for the new
  data), "again" the next load with nothing written in between - a second
  arbiter, a projector, the public page, a broadcast refreshing an open
  page. With the cache off both are the full replay.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias PairingsEngine.{Pairing, Repo, Snapshot, StandingsCache, Tournaments}

  @moduletag :bench
  @moduletag :capture_log
  @moduletag timeout: :infinity

  setup :register_and_log_in_user

  setup do
    keys = [:explanation_jobs, :round_explainer, :slow_explainer, StandingsCache]
    previous = for key <- keys, do: {key, Application.get_env(:pairings_engine, key)}

    # The rounds' explanations are not what is measured here: fail them fast.
    Application.put_env(:pairings_engine, :explanation_jobs, :inline)
    Application.put_env(:pairings_engine, :round_explainer, PairingsEngine.Test.SlowExplainer)
    Application.put_env(:pairings_engine, :slow_explainer, :raise)

    on_exit(fn ->
      for {key, value} <- previous do
        if is_nil(value),
          do: Application.delete_env(:pairings_engine, key),
          else: Application.put_env(:pairings_engine, key, value)
      end
    end)
  end

  test "pages of a 451-player event", %{conn: conn, scope: scope} do
    :rand.seed(:exsss, {451, 7, 11})
    size = String.to_integer(System.get_env("BENCH_SIZE") || "451")

    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "Bench standings",
        "type" => "swiss",
        "rounds_count" => "9",
        "pairing_engine" => "ainalrami",
        "tiebreaks" => ["BH", "BHC1", "SB", "DE"]
      })

    for n <- 1..size do
      {:ok, _} =
        Tournaments.create_player(t.id, %{
          "name" => "Player #{n}",
          "fide_rating" => 2700 - n * 3 - :rand.uniform(3)
        })
    end

    for _ <- 1..5 do
      {:ok, round} = Pairing.pair_next_round(Tournaments.get_tournament!(t.id))
      results(round)
    end

    t = Tournaments.get_tournament!(t.id)

    pages = [
      {"standings/2 alone", fn -> PairingsEngine.Standings.standings(t) end},
      {"grid_standings/1", fn -> PairingsEngine.Standings.grid_standings(t) end},
      {"Standings page", fn -> {:ok, _, _} = live(conn, ~p"/t/#{t.id}/standings") end},
      {"Players page", fn -> {:ok, _, _} = live(conn, ~p"/t/#{t.id}/players") end},
      {"Pairings page", fn -> {:ok, _, _} = live(conn, ~p"/t/#{t.id}/pairings") end},
      {"Print standings", fn -> 200 = get(conn, ~p"/t/#{t.id}/print/standings").status end},
      {"Print crosstable", fn -> 200 = get(conn, ~p"/t/#{t.id}/print/crosstable").status end},
      {"Public snapshot", fn -> Snapshot.build(Tournaments.get_tournament!(t.id)) end}
    ]

    for enabled <- [false, true] do
      Application.put_env(:pairings_engine, StandingsCache, enabled: enabled)

      IO.puts(
        "\n[bench] #{size} players, 5 rounds, standings cache #{if enabled, do: "on", else: "off"}"
      )

      for {name, load} <- pages do
        StandingsCache.clear()
        first = ms(load)
        again = ms(load)
        IO.puts("[bench]   #{String.pad_trailing(name, 18)} first #{first} ms, again #{again} ms")
      end

      # All six in a row, as after one write with every page open.
      StandingsCache.clear()
      all = ms(fn -> Enum.each(pages, fn {_, load} -> load.() end) end)
      IO.puts("[bench]   all six pages once   #{all} ms")
    end
  end

  defp ms(fun) do
    {micros, _} = :timer.tc(fun)
    div(micros, 1000)
  end

  defp results(round) do
    pairings =
      Repo.all(from p in PairingsEngine.Tournaments.Pairing, where: p.round_id == ^round.id)

    for p <- pairings, p.black_player_id do
      Repo.update_all(from(x in PairingsEngine.Tournaments.Pairing, where: x.id == ^p.id),
        set: [result: Enum.random(["1-0", "0-1", "1/2-1/2", "1/2-1/2"])]
      )
    end
  end
end
