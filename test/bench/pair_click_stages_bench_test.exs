defmodule PairingsEngineWeb.Bench.PairClickStagesBenchTest do
  @moduledoc """
  What an arbiter waits for after clicking "Pair round", stage by stage,
  through the real Pairings LiveView. Not a test of anything: excluded from
  every run unless asked for, and it prints its timings.

      $env:ELIXIR_ERL_OPTIONS = "+S 1"   # one scheduler: the 2-vCPU server under load
      mix test test/bench/pair_click_stages_bench_test.exs --include bench

  `BENCH_SIZES` (default `50,200,600,1000`) picks the fields and
  `BENCH_ROUNDS` (default `2,5,9`) the rounds clicked through the page; the
  rounds in between are paired directly. `BENCH_REPEAT` (default 1) clicks
  each measured round that many times - unpairing in between - and reports
  the fastest.

  Per click it reports:

    * `server` - what the page's process spent before its reply left: the
      `"pair"` handler (every `PairingsEngine.PairTiming` stage inside it)
      and the LiveView's render and diff (`[:phoenix, :live_view, :render]`),
      with the diff's size as JSON;
    * `click-to-reply` - the same, plus what the test client spends taking
      the diff apart (a browser does that part instead);
    * after the reply: the page handling its own click's broadcast (`echo`,
      with the reload and render it caused, if any), the round's
      explanation job, and building the public snapshot a publish sends.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias PairingsEngine.{Pairing, PairTiming, Repo, Snapshot, Tournaments}
  alias PairingsEngine.Tournaments.Round

  @endpoint PairingsEngineWeb.Endpoint

  @moduletag :bench
  @moduletag :capture_log
  @moduletag timeout: :infinity

  setup do
    owner =
      Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true, ownership_timeout: :infinity)

    previous = Application.get_env(:pairings_engine, :explanation_jobs)
    # As on the server: the account is worked out after the click.
    Application.put_env(:pairings_engine, :explanation_jobs, :async)

    on_exit(fn ->
      Application.put_env(:pairings_engine, :explanation_jobs, previous)
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
    end)

    PairingsEngineWeb.ConnCase.register_and_log_in_user(%{conn: build_conn()})
  end

  test "pair click stages", %{conn: conn, scope: scope} do
    sizes = env_list("BENCH_SIZES", [50, 200, 600, 1000])
    rounds = env_list("BENCH_ROUNDS", [2, 5, 9])
    repeat = hd(env_list("BENCH_REPEAT", [1]))

    IO.puts("\n[bench] schedulers #{System.schedulers_online()}")

    bench = self()
    handler = "pair-click-stages-bench"

    events =
      for(stage <- PairTiming.stages(), do: PairTiming.prefix() ++ [stage, :stop]) ++
        [[:phoenix, :live_view, :render, :stop], [:phoenix, :live_view, :handle_event, :stop]]

    :telemetry.attach_many(
      handler,
      events,
      fn event, %{duration: d}, _meta, _ -> send(bench, {:timed, event, d}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    for size <- sizes do
      t = generated_event(scope, size)
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(t.id))

      for number <- 1..Enum.max(rounds) do
        if number in rounds do
          best =
            1..repeat
            |> Enum.map(fn attempt ->
              if attempt > 1 do
                :ok = Pairing.delete_round(t.id, number)
                flush()
              end

              click(conn, t, number)
            end)
            |> Enum.min_by(&server/1)

          report(size, number, best)
        else
          {:ok, _} = Pairing.pair_next_round(Tournaments.get_tournament!(t.id))
          wait_for_explanation(t, number)
        end

        flush()
        if number < Enum.max(rounds), do: results(t, number)
      end
    end
  end

  defp click(conn, t, number) do
    {:ok, view, _html} = live(conn, "/t/#{t.id}/pairings")
    flush()

    :erlang.trace(view.pid, true, [:send])
    {total, _html} = :timer.tc(fn -> render_click(view, "pair", %{}) end)

    # Everything the click itself timed is in the mailbox by now: the
    # handlers run in the page's process, before it replies.
    {stages, diffs} = collect(%{}, [])

    # The page's own broadcast is in its mailbox already: this waits until
    # it has been handled, and that is the echo.
    {echo_wall, _} = :timer.tc(fn -> :sys.get_state(view.pid) end)
    :erlang.trace(view.pid, false, [:send])
    {after_stages, after_diffs} = collect(%{}, [])

    {explanation, _} = :timer.tc(fn -> wait_for_explanation(t, number) end)
    {public, _} = :timer.tc(fn -> Snapshot.build(Tournaments.get_tournament!(t.id)) end)

    GenServer.stop(view.pid)

    %{
      total: total,
      stages: stages,
      diff: Enum.sum(diffs),
      after: after_stages,
      after_diff: Enum.sum(after_diffs),
      echo_wall: echo_wall,
      explanation: explanation,
      public: public
    }
  end

  defp collect(stages, diffs) do
    receive do
      {:timed, event, d} ->
        key = event |> Enum.slice(0..-2//1) |> List.last()
        key = if match?([:phoenix | _], event), do: {:phoenix, key}, else: key
        collect(Map.update(stages, key, [d], &[d | &1]), diffs)

      {:trace, _pid, :send, %Phoenix.Socket.Reply{payload: %{diff: diff}}, _to} ->
        collect(stages, [byte_size(Jason.encode!(diff)) | diffs])

      {:trace, _pid, :send, %Phoenix.Socket.Message{event: "diff", payload: diff}, _to} ->
        collect(stages, [byte_size(Jason.encode!(diff)) | diffs])

      {:trace, _, _, _, _} ->
        collect(stages, diffs)
    after
      0 -> {stages, Enum.reverse(diffs)}
    end
  end

  defp sum(stages, key), do: stages |> Map.get(key, []) |> Enum.sum()

  # The `"pair"` handler: its `:click` span, or - run against a version
  # from before the spans - LiveView's own handle_event span.
  defp handler(stages) do
    case sum(stages, :click) do
      0 -> sum(stages, {:phoenix, :handle_event})
      click -> click
    end
  end

  defp server(run), do: handler(run.stages) + sum(run.stages, {:phoenix, :render})

  defp report(size, number, run) do
    ms = &PairTiming.format_ms/1

    inside =
      for stage <- PairTiming.stages(),
          stage not in [:click, :echo],
          Map.has_key?(run.stages, stage) do
        "#{stage} #{ms.(sum(run.stages, stage))}"
      end

    IO.puts(
      "[bench] #{size} players, round #{number}: server #{ms.(server(run))} ms " <>
        "(handler #{ms.(handler(run.stages))}, " <>
        "render+diff #{ms.(sum(run.stages, {:phoenix, :render}))}, diff #{run.diff} B), " <>
        "click-to-reply #{div(run.total, 1000)} ms"
    )

    IO.puts("[bench]   stages: #{Enum.join(inside, ", ")}")

    IO.puts(
      "[bench]   after the reply: echo #{ms.(sum(run.after, :echo))} " <>
        "(reload #{ms.(sum(run.after, :refresh))}) + render " <>
        "#{ms.(sum(run.after, {:phoenix, :render}))} (diff #{run.after_diff} B, " <>
        "waited #{div(run.echo_wall, 1000)} ms), explanation job " <>
        "#{div(run.explanation, 1000)} ms, public snapshot #{div(run.public, 1000)} ms"
    )
  end

  defp generated_event(scope, size) do
    :rand.seed(:exsss, {size, 7, 11})

    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "Bench #{size}",
        "type" => "swiss",
        "rounds_count" => "9",
        "pairing_engine" => "ainalrami",
        "tiebreaks" => ["BH", "BHC1", "SB", "DE"],
        "round_dates" => List.duplicate("2026-09-01", 9)
      })

    for n <- 1..size do
      {:ok, _} =
        Tournaments.create_player(t.id, %{
          "name" => "Player #{n}",
          "fide_rating" => 2700 - n * 2 - :rand.uniform(3)
        })
    end

    # The public page is part of what a write sets going: queue it as the
    # server would.
    Repo.update_all(from(x in PairingsEngine.Tournaments.Tournament, where: x.id == ^t.id),
      set: [publish_to_openresults: true]
    )

    Tournaments.get_tournament!(t.id)
  end

  defp results(t, number) do
    round = Repo.one!(from r in Round, where: r.tournament_id == ^t.id and r.number == ^number)

    pairings =
      Repo.all(from p in PairingsEngine.Tournaments.Pairing, where: p.round_id == ^round.id)

    for p <- pairings, p.black_player_id do
      Repo.update_all(from(x in PairingsEngine.Tournaments.Pairing, where: x.id == ^p.id),
        set: [result: Enum.random(["1-0", "0-1", "1/2-1/2", "1/2-1/2"])]
      )
    end
  end

  defp wait_for_explanation(t, number) do
    case Repo.one(from r in Round, where: r.tournament_id == ^t.id and r.number == ^number) do
      %{explanation: %{"status" => "pending"}} ->
        receive do
          {:tournament_changed, _, :explanation} -> wait_for_explanation(t, number)
        after
          600_000 -> flunk("no explanation after 10 minutes")
        end

      _ ->
        :ok
    end
  end

  defp flush do
    receive do
      {:tournament_changed, _, _} -> flush()
      {:timed, _, _} -> flush()
      {:trace, _, _, _, _} -> flush()
    after
      0 -> :ok
    end
  end

  defp env_list(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> value |> String.split(",", trim: true) |> Enum.map(&String.to_integer/1)
    end
  end
end
