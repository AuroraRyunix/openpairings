defmodule PairingsEngineWeb.AlternativesOnDemandLiveTest do
  @moduledoc """
  The explanation page's "why him and not me" questions on a round paired
  since 2026-09-28: closed until opened, worked out when opened ("Working it
  out…" meanwhile), kept for everybody after, and a failure that says so
  with a way to try again. Runs jobs in the background with a stand-in
  explainer, so `async: false`.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{ExplanationJobs, Pairing, Repo, Tournaments}
  alias PairingsEngine.Test.SlowExplainer

  @moduletag :capture_log

  setup :register_and_log_in_user

  setup do
    previous =
      for key <- [:explanation_jobs, :round_explainer, :slow_explainer, :slow_alternatives],
          do: {key, Application.get_env(:pairings_engine, key)}

    Application.put_env(:pairings_engine, :explanation_jobs, :inline)
    Application.put_env(:pairings_engine, :round_explainer, SlowExplainer)
    SlowExplainer.reset_question_calls()

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

  defp jobs(mode), do: Application.put_env(:pairings_engine, :explanation_jobs, mode)
  defp questions(mode), do: Application.put_env(:pairings_engine, :slow_alternatives, mode)

  # Seven players: an odd field, so round one has a bye and its question.
  defp paired(scope) do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "On demand",
        "type" => "swiss",
        "rounds_count" => "5"
      })

    for n <- 1..7 do
      {:ok, _} = Tournaments.create_player(t.id, %{"name" => "P#{n}", "fide_rating" => 2000 - n})
    end

    {:ok, round} = Pairing.pair_next_round(Tournaments.get_tournament!(t.id))
    {Tournaments.get_tournament!(t.id), Tournaments.get_round(t.id, round.number)}
  end

  # The job that works out `question`, to wait for: it broadcasts before it
  # ends, so once it is down every page subscribed has the news queued.
  defp job_for(round, question) do
    [{pid, _}] =
      Registry.lookup(PairingsEngine.ExplanationJobRegistry, {:alternative, round.id, question})

    {pid, Process.monitor(pid)}
  end

  test "the explanation is there without the alternatives, each one closed", %{
    conn: conn,
    scope: scope
  } do
    {t, _round} = paired(scope)
    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings/1/explain")

    assert has_element?(lv, "#engine-account")
    assert has_element?(lv, "#alternatives-on-demand-note")

    assert has_element?(
             lv,
             ~s(#alt-bye-0-toggle[aria-expanded="false"][aria-controls="alt-bye-0-panel"])
           )

    assert has_element?(lv, "#alt-bye-0-panel[hidden]")
    refute has_element?(lv, "#alt-bye-0-answer")
    assert SlowExplainer.question_calls() == 0
  end

  test "opening one shows Working it out…, then the answer - on every open page", %{
    conn: conn,
    scope: scope
  } do
    {t, round} = paired(scope)
    jobs(:async)
    questions({:block, self()})

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings/1/explain")
    {:ok, other, _html} = live(conn, ~p"/t/#{t.id}/pairings/1/explain")

    lv |> element("#alt-bye-0-toggle") |> render_click()
    assert_receive {:alternative_started, worker}, 5_000

    assert has_element?(lv, ~s(#alt-bye-0-toggle[aria-expanded="true"]))
    assert has_element?(lv, ~s(#alt-bye-0-panel[aria-busy="true"]))
    assert has_element?(lv, "#alt-bye-0-working")

    # A second viewer opening it meanwhile joins the job, not a second one.
    other |> element("#alt-bye-0-toggle") |> render_click()
    assert has_element?(other, "#alt-bye-0-working")

    {job, ref} = job_for(round, "bye/0")
    send(worker, :release)
    assert_receive {:DOWN, ^ref, :process, ^job, _}, 10_000

    for view <- [lv, other] do
      refute has_element?(view, "#alt-bye-0-working")
      assert has_element?(view, "#alt-bye-0-answer li")
    end

    assert SlowExplainer.question_calls() == 1
    assert %{"bye/0" => _} = Pairing.stored_alternatives(round)
  end

  test "a second open reads the stored answer; closing hides it", %{conn: conn, scope: scope} do
    {t, _round} = paired(scope)

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings/1/explain")
    lv |> element("#alt-bye-0-toggle") |> render_click()
    assert has_element?(lv, "#alt-bye-0-answer li")
    assert SlowExplainer.question_calls() == 1

    lv |> element("#alt-bye-0-toggle") |> render_click()
    assert has_element?(lv, ~s(#alt-bye-0-toggle[aria-expanded="false"]))
    assert has_element?(lv, "#alt-bye-0-panel[hidden]")

    # Another visit, later: shown as stored, not worked out again.
    {:ok, again, _html} = live(conn, ~p"/t/#{t.id}/pairings/1/explain")
    again |> element("#alt-bye-0-toggle") |> render_click()
    assert has_element?(again, "#alt-bye-0-answer li")
    assert SlowExplainer.question_calls() == 1
  end

  test "a failure says so and offers to try again, which works", %{conn: conn, scope: scope} do
    {t, _round} = paired(scope)
    questions(:raise)

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings/1/explain")
    lv |> element("#alt-bye-0-toggle") |> render_click()

    assert has_element?(lv, "#alt-bye-0-failed[role=alert]")
    assert has_element?(lv, "#alt-bye-0-retry")
    refute has_element?(lv, "#alt-bye-0-working")

    questions(:real)
    lv |> element("#alt-bye-0-retry") |> render_click()
    refute has_element?(lv, "#alt-bye-0-failed")
    assert has_element?(lv, "#alt-bye-0-answer li")
  end

  test "a job lost without a word ends as a failure, not a spinner", %{
    conn: conn,
    scope: scope
  } do
    {t, round} = paired(scope)
    jobs(:async)
    questions({:block, self()})

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings/1/explain")
    lv |> element("#alt-bye-0-toggle") |> render_click()
    assert_receive {:alternative_started, _worker}, 5_000

    # The node going down under it: gone, nothing said.
    {job, ref} = job_for(round, "bye/0")
    Task.Supervisor.terminate_child(PairingsEngine.ExplanationTaskSupervisor, job)
    assert_receive {:DOWN, ^ref, :process, ^job, _}, 5_000

    send(lv.pid, :check_alternatives)
    assert has_element?(lv, "#alt-bye-0-failed")
    assert has_element?(lv, "#alt-bye-0-retry")
  end

  test "after unpairing and pairing again, the old answers are gone", %{
    conn: conn,
    scope: scope
  } do
    {t, round} = paired(scope)

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings/1/explain")
    lv |> element("#alt-bye-0-toggle") |> render_click()
    assert has_element?(lv, "#alt-bye-0-answer li")

    # Unpaired under the open page: it cannot start work on a round that is
    # no longer there.
    :ok = Pairing.delete_round(t.id, round.number)

    assert render_click(lv, "alternative_retry", %{"q" => "bye/0"}) =~
             "This round has changed since the page was opened"

    # Paired again: the open page takes the new account when it arrives,
    # with nothing opened and none of the old answers.
    {:ok, _again} = Pairing.pair_next_round(Repo.reload!(t))
    assert has_element?(lv, ~s(#alt-bye-0-toggle[aria-expanded="false"]))
    refute has_element?(lv, "#alt-bye-0-answer")

    {:ok, fresh, _html} = live(conn, ~p"/t/#{t.id}/pairings/1/explain")
    assert has_element?(fresh, "#alt-bye-0-toggle")
    refute has_element?(fresh, "#alt-bye-0-answer")
    assert Pairing.stored_alternatives(Tournaments.get_round(t.id, 1)) == %{}

    assert ExplanationJobs.running_alternatives(round.id, round.explanation["job"]) ==
             MapSet.new()
  end
end
