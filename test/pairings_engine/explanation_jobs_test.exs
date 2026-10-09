defmodule PairingsEngine.ExplanationJobsTest do
  @moduledoc """
  The round's engine account is worked out after the pairing click
  (`PairingsEngine.ExplanationJobs`). These run the jobs for real - in the
  background, with a stand-in explainer the test holds up or breaks
  (`PairingsEngine.Test.SlowExplainer`) - so they switch global settings and
  are `async: false`.
  """
  use PairingsEngine.DataCase, async: false

  @moduletag :capture_log

  alias PairingsEngine.{ExplanationJobs, Pairing, Repo, RoundExplanation, Tournaments}
  alias PairingsEngine.Tournaments.{Round, Tournament}

  setup do
    previous =
      for key <- [:explanation_jobs, :round_explainer, :slow_explainer],
          do: {key, Application.get_env(:pairings_engine, key)}

    Application.put_env(:pairings_engine, :explanation_jobs, :async)
    Application.put_env(:pairings_engine, :round_explainer, PairingsEngine.Test.SlowExplainer)

    on_exit(fn ->
      # No job may outlive the test's sandbox.
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

  defp block, do: Application.put_env(:pairings_engine, :slow_explainer, {:block, self()})
  defp explainer(mode), do: Application.put_env(:pairings_engine, :slow_explainer, mode)

  defp tournament(attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Tournament{
          name: "Later accounts",
          type: "swiss",
          rounds_count: 5,
          tiebreaks: ~w(BH),
          initial_colour: "white",
          round_dates: List.duplicate("2026-09-01", 5)
        },
        attrs
      )
    )
  end

  defp roster(t, count, overrides \\ %{}) do
    for n <- 1..count do
      attrs =
        Map.merge(
          %{"name" => "P#{n}", "fide_rating" => 2100 - n * 40},
          Map.get(overrides, n, %{})
        )

      {:ok, p} = Tournaments.create_player(t.id, attrs)
      p
    end
  end

  defp subscribe(t),
    do: Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(t.id))

  defp stored(t, number), do: Tournaments.get_round(t.id, number)

  defp white_wins(round) do
    round
    |> Repo.preload(:pairings, force: true)
    |> Map.fetch!(:pairings)
    |> Enum.each(fn p ->
      if p.black_player_id, do: {:ok, _} = Tournaments.update_pairing_result(p, "1-0")
    end)
  end

  describe "the click" do
    test "saves and returns the round without waiting for the account, which arrives by broadcast" do
      t = tournament()
      roster(t, 9)
      subscribe(t)
      block()

      # The explainer is held: if the click waited for it, this would not
      # return until the 30-second fallback.
      {micros, {:ok, round}} = :timer.tc(fn -> Pairing.pair_next_round(t) end)
      assert micros < 10_000_000

      assert_receive {:explainer_started, job}, 5_000
      assert Pairing.explanation_state(round) == :pending
      assert Pairing.explanation_state(stored(t, 1)) == :pending
      pending_job = round.explanation["job"]
      assert ExplanationJobs.running?(round.id)
      # Boards are all there already.
      assert length(Repo.preload(round, :pairings).pairings) == 5

      send(job, :release)
      assert_receive {:tournament_changed, id, :explanation}, 10_000
      assert id == t.id

      round = stored(t, 1)
      assert Pairing.explanation_state(round) == :ready
      # The brackets only; the alternatives are worked out when opened, and
      # stored against the fingerprint the account keeps.
      assert round.explanation["version"] == 4
      assert round.explanation["alternatives"] == "on_demand"
      assert round.explanation["job"] == pending_job
      refute Map.has_key?(round.explanation, "status")
      assert [_ | _] = RoundExplanation.for_round(round, Tournaments.list_players(t.id))
      refute ExplanationJobs.running?(round.id)
    end

    test "the account worked out later is the one worked out in the click before" do
      t = tournament()
      roster(t, 9)
      subscribe(t)

      {:ok, _} = Pairing.pair_next_round(t)
      assert_receive {:tournament_changed, _, :explanation}, 10_000
      later = stored(t, 1).explanation

      # The same round paired again, its account worked out before the
      # call returns - the way the click used to produce it.
      assert :ok = Pairing.delete_round(t.id, 1)
      Application.put_env(:pairings_engine, :explanation_jobs, :inline)
      {:ok, _} = Pairing.pair_next_round(Repo.reload!(t))

      # Apart from the fingerprint, which is new for every pairing.
      assert Map.delete(stored(t, 1).explanation, "job") == Map.delete(later, "job")
    end
  end

  describe "correctness stays in the click" do
    test "a bye exclusion that moved the bye is stamped and audited before the account exists" do
      t = tournament()

      [_p1, _p2, _p3, p4, p5] =
        roster(t, 5, %{5 => %{"no_bye" => "true", "no_bye_scope" => "all"}})

      subscribe(t)
      block()

      {:ok, round} = Pairing.pair_next_round(Repo.reload!(t))
      assert_receive {:explainer_started, job}, 5_000

      # Still pending, and already on the record: P5 was passed over, P4
      # has the bye, and the tournament left the FIDE rules this round.
      assert Pairing.explanation_state(stored(t, 1)) == :pending
      assert [section] = stored(t, 1).explanation["sections"]
      assert section["bye_passed_over"] == [p5.id]
      assert section["bye_exclusions"] == [p5.id]
      assert Pairing.pairing_deviations(t, 1) == [:bye_exclusion]
      assert Repo.reload!(t).fide_compliance_lost_round == 1
      assert RoundExplanation.bye_exclusion_rounds(t.id) == [1]

      bye =
        round
        |> Repo.preload(:pairings)
        |> Map.fetch!(:pairings)
        |> Enum.find_value(&(is_nil(&1.black_player_id) && &1.white_player_id))

      assert bye == p4.id

      send(job, :release)
      assert_receive {:tournament_changed, _, :explanation}, 10_000

      # The finished account says the same.
      assert [section] = stored(t, 1).explanation["sections"]
      assert section["bye_passed_over"] == [p5.id]
      assert Pairing.pairing_deviations(t, 1) == [:bye_exclusion]
    end

    test "a wish that moved a board is stamped before the account exists" do
      t = tournament()
      [p1, _p2, p3, _p4] = roster(t, 4)
      {:ok, _} = Tournaments.add_forbidden_pairing(t, p1.id, p3.id, soft: true)
      block()

      {:ok, _round} = Pairing.pair_next_round(Repo.reload!(t))
      assert_receive {:explainer_started, _job}, 5_000

      assert Pairing.explanation_state(stored(t, 1)) == :pending
      assert Pairing.pairing_deviations(t, 1) == [:soft_pairs]
      assert Repo.reload!(t).fide_compliance_lost_round == 1
    end
  end

  describe "a job that no longer applies" do
    test "unpairing stops the job, and a late result is not written" do
      t = tournament()
      roster(t, 9)
      block()

      {:ok, round} = Pairing.pair_next_round(t)
      assert_receive {:explainer_started, _job}, 5_000
      fingerprint = round.explanation["job"]
      [{job_pid, _}] = Registry.lookup(PairingsEngine.ExplanationJobRegistry, round.id)
      ref = Process.monitor(job_pid)

      assert :ok = Pairing.delete_round(t.id, 1)
      assert_receive {:DOWN, ^ref, :process, ^job_pid, _}, 5_000

      assert ExplanationJobs.store(round.id, fingerprint, %{"sections" => []}) == :stale
      assert is_nil(Repo.get(Round, round.id))
    end

    test "a result for a round paired again is not written onto the new one" do
      t = tournament()
      roster(t, 9)
      block()

      {:ok, first} = Pairing.pair_next_round(t)
      assert_receive {:explainer_started, _job}, 5_000
      assert :ok = Pairing.delete_round(t.id, 1)

      {:ok, second} = Pairing.pair_next_round(Repo.reload!(t))
      assert_receive {:explainer_started, job}, 5_000

      # SQLite hands the freed row id out again; the fingerprint is what
      # tells the two apart.
      assert first.explanation["job"] != second.explanation["job"]

      assert ExplanationJobs.store(second.id, first.explanation["job"], %{"sections" => []}) ==
               :stale

      assert Pairing.explanation_state(stored(t, 1)) == :pending

      subscribe(t)
      send(job, :release)
      assert_receive {:tournament_changed, _, :explanation}, 10_000
      assert Pairing.explanation_state(stored(t, 1)) == :ready
    end
  end

  describe "failure and restart" do
    test "a job that fails marks the account failed and says so; trying again works it out" do
      t = tournament()
      roster(t, 9)
      subscribe(t)
      explainer(:raise)

      {:ok, _round} = Pairing.pair_next_round(t)
      assert_receive {:tournament_changed, _, :explanation}, 10_000

      round = stored(t, 1)
      assert Pairing.explanation_state(round) == :failed
      assert Pairing.reexplain_status(t, round) == :failed
      assert Pairing.reexplain_round(t, 1) == {:skip, :failed}

      explainer(:real)
      assert :ok = Pairing.retry_explanation(t, round)
      assert_receive {:tournament_changed, _, :explanation}, 10_000

      round = stored(t, 1)
      assert Pairing.explanation_state(round) == :ready
      assert round.explanation["origin"] == "recomputed"
    end

    test "a pending account nobody is working on is worked out again on demand" do
      t = tournament()
      roster(t, 9)
      subscribe(t)
      block()

      {:ok, round} = Pairing.pair_next_round(t)
      assert_receive {:explainer_started, _job}, 5_000

      # The node going down under the job: gone, record still pending.
      :ok = ExplanationJobs.cancel(round.id)
      refute_receive {:tournament_changed, _, :explanation}, 200
      refute ExplanationJobs.running?(round.id)
      assert Pairing.explanation_state(stored(t, 1)) == :pending

      explainer(:real)
      assert Pairing.ensure_explanation(t, stored(t, 1)) == :pending
      assert_receive {:tournament_changed, _, :explanation}, 10_000

      round = stored(t, 1)
      assert Pairing.explanation_state(round) == :ready
      assert round.explanation["origin"] == "recomputed"
    end

    test "the account rebuilt after a restart matches the one worked out in memory" do
      t = tournament()
      roster(t, 11)
      subscribe(t)

      {:ok, r1} = Pairing.pair_next_round(t)
      assert_receive {:tournament_changed, _, :explanation}, 10_000
      white_wins(r1)

      block()
      {:ok, r2} = Pairing.pair_next_round(Repo.reload!(t))
      assert_receive {:explainer_started, job}, 5_000
      pending = r2.explanation
      send(job, :release)
      assert_receive {:tournament_changed, _, :explanation}, 10_000
      in_memory = stored(t, 2).explanation

      # Put the pending record back, as a restart would have left it.
      r2 |> Repo.reload!() |> Ecto.Changeset.change(explanation: pending) |> Repo.update!()
      explainer(:real)
      assert {:ok, rebuilt} = Pairing.recompute_explanation(Repo.reload!(t), 2)

      json = &(&1 |> Jason.encode!() |> Jason.decode!())
      # The job stores the fingerprint on it; `recompute_explanation/2` is
      # the work, which does not.
      assert json.(Map.drop(rebuilt, ["origin", "paired_by"])) ==
               json.(Map.delete(in_memory, "job"))
    end

    test "a category-paired round is rebuilt section by section" do
      t =
        tournament(%{pair_by_category: true, categories_enabled: true, categories: ["A", "B"]})

      roster(t, 10, %{
        1 => %{"category" => "A"},
        2 => %{"category" => "B"},
        3 => %{"category" => "A"},
        4 => %{"category" => "B"},
        5 => %{"category" => "A"},
        6 => %{"category" => "B"},
        7 => %{"category" => "A"},
        8 => %{"category" => "B"},
        9 => %{"category" => "A"},
        10 => %{"category" => "B"}
      })

      subscribe(t)
      block()
      {:ok, r1} = Pairing.pair_next_round(Repo.reload!(t))
      pending = r1.explanation
      assert Enum.map(pending["sections"], & &1["category"]) == ["A", "B"]

      # One job, one section after the other.
      assert_receive {:explainer_started, job}, 5_000
      send(job, :release)
      assert_receive {:explainer_started, job}, 5_000
      send(job, :release)
      assert_receive {:tournament_changed, _, :explanation}, 10_000
      in_memory = stored(t, 1).explanation

      r1 |> Repo.reload!() |> Ecto.Changeset.change(explanation: pending) |> Repo.update!()
      explainer(:real)
      assert {:ok, rebuilt} = Pairing.recompute_explanation(Repo.reload!(t), 1)

      json = &(&1 |> Jason.encode!() |> Jason.decode!())
      # The job stores the fingerprint on it; `recompute_explanation/2` is
      # the work, which does not.
      assert json.(Map.drop(rebuilt, ["origin", "paired_by"])) ==
               json.(Map.delete(in_memory, "job"))
    end
  end

  test "accounts stored before this change read exactly as before" do
    t = tournament()
    roster(t, 4)
    Application.put_env(:pairings_engine, :explanation_jobs, :inline)
    {:ok, round} = Pairing.pair_next_round(t)

    # A version-3 record carries no "status": that is every round paired
    # before the account moved out of the click.
    refute Map.has_key?(round.explanation, "status")
    assert Pairing.explanation_state(round) == :ready
    assert Pairing.reexplain_status(t, round) == :current
    assert Pairing.ensure_explanation(t, round) == :ready
    assert Pairing.explanation_state(%Round{explanation: nil}) == :none
  end
end
