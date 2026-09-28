defmodule PairingsEngineWeb.ExplanationPendingLiveTest do
  @moduledoc """
  What the Pairings page and the explanation page show while a round's
  engine account is still being worked out after the pairing click
  (`PairingsEngine.ExplanationJobs`), and that they fill in by themselves.
  Runs the jobs in the background for real, so `async: false`.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{ExplanationJobs, Pairing, Repo, Tournaments}

  @moduletag :capture_log

  setup :register_and_log_in_user

  setup do
    previous =
      for key <- [:explanation_jobs, :round_explainer, :slow_explainer],
          do: {key, Application.get_env(:pairings_engine, key)}

    Application.put_env(:pairings_engine, :explanation_jobs, :async)
    Application.put_env(:pairings_engine, :round_explainer, PairingsEngine.Test.SlowExplainer)

    on_exit(fn ->
      for {_, pid, _, _} <- Supervisor.which_children(PairingsEngine.ExplanationTaskSupervisor) do
        Task.Supervisor.terminate_child(PairingsEngine.ExplanationTaskSupervisor, pid)
      end

      for {key, value} <- previous do
        if is_nil(value),
          do: Application.delete_env(:pairings_engine, key),
          else: Application.put_env(:pairings_engine, key, value)
      end
    end)

    :ok
  end

  defp explainer(mode), do: Application.put_env(:pairings_engine, :slow_explainer, mode)

  defp paired_tournament(scope) do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "Later",
        "type" => "swiss",
        "rounds_count" => "5",
        "pairing_engine" => "ainalrami"
      })

    for n <- 1..7 do
      {:ok, _} = Tournaments.create_player(t.id, %{"name" => "P#{n}", "fide_rating" => 2000 - n})
    end

    Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(t.id))
    {:ok, round} = Pairing.pair_next_round(Tournaments.get_tournament!(t.id))
    {Tournaments.get_tournament!(t.id), round}
  end

  # Once the job has finished, everything it broadcast is in the pages'
  # mailboxes; `:sys.get_state/1` waits until each page has read it.
  defp settled(round_id, views) do
    case Registry.lookup(PairingsEngine.ExplanationJobRegistry, round_id) do
      [{pid, _}] ->
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 10_000

      [] ->
        :ok
    end

    for view <- views, do: :sys.get_state(view.pid)
    :ok
  end

  test "both pages say the account is being worked out, and fill in when it is", %{
    conn: conn,
    scope: scope
  } do
    explainer({:block, self()})
    {t, round} = paired_tournament(scope)
    assert_receive {:explainer_started, job}, 5_000

    {:ok, pairings, _} = live(conn, ~p"/t/#{t.id}/pairings")
    assert has_element?(pairings, "#round-explanation-pending")

    {:ok, explain, _} = live(conn, ~p"/t/#{t.id}/pairings/1/explain")
    assert has_element?(explain, "#explanation-pending")
    refute has_element?(explain, "#engine-account")
    refute has_element?(explain, "#recompute")

    send(job, :release)
    settled(round.id, [pairings, explain])

    refute has_element?(pairings, "#round-explanation-pending")
    assert has_element?(explain, "#engine-account")
    refute has_element?(explain, "#explanation-pending")
  end

  test "a failed account is said plainly, and Try again works it out", %{
    conn: conn,
    scope: scope
  } do
    explainer(:raise)
    {t, round} = paired_tournament(scope)
    assert_receive {:tournament_changed, _, :explanation}, 10_000

    {:ok, explain, _} = live(conn, ~p"/t/#{t.id}/pairings/1/explain")
    assert has_element?(explain, "#explanation-failed")
    refute has_element?(explain, "#explanation-pending")

    explainer(:real)
    explain |> element("#explanation-retry") |> render_click()
    settled(round.id, [explain])

    assert has_element?(explain, "#engine-account")
    refute has_element?(explain, "#explanation-failed")
  end

  test "an account left pending by a restart is worked out when the page is opened", %{
    conn: conn,
    scope: scope
  } do
    explainer({:block, self()})
    {t, round} = paired_tournament(scope)
    assert_receive {:explainer_started, _job}, 5_000

    :ok = ExplanationJobs.cancel(round.id)
    refute_receive {:tournament_changed, _, :explanation}, 200
    assert Pairing.explanation_state(Repo.reload!(round)) == :pending

    explainer(:real)
    {:ok, explain, _} = live(conn, ~p"/t/#{t.id}/pairings/1/explain")
    settled(round.id, [explain])

    assert has_element?(explain, "#engine-account")
  end
end
