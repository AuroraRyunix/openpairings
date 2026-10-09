defmodule PairingsEngine.AlternativesOnDemandTest do
  @moduledoc """
  A round's "why him and not me" alternatives - one forced re-pairing of
  the round per candidate - are worked out when somebody opens the question
  (`PairingsEngine.Pairing.open_alternative/4`), once, and kept against the
  account's fingerprint. The account itself, stored after pairing, is the
  brackets only.

  Switches global settings (the job mode, a stand-in explainer), so
  `async: false`.
  """
  use PairingsEngine.DataCase, async: false

  @moduletag :capture_log

  alias PairingsEngine.{ExplanationJobs, Pairing, Repo, RoundExplanation, Tournaments}
  alias PairingsEngine.Pairing.Explainer
  alias PairingsEngine.Test.SlowExplainer
  alias PairingsEngine.Tournaments.Tournament

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

  defp tournament do
    Repo.insert!(%Tournament{
      name: "On demand",
      type: "swiss",
      rounds_count: 5,
      tiebreaks: ~w(BH),
      initial_colour: "white",
      round_dates: List.duplicate("2026-09-01", 5)
    })
  end

  defp roster(t, count) do
    for n <- 1..count do
      {:ok, p} = Tournaments.create_player(t.id, %{"name" => "P#{n}", "fide_rating" => 2100 - n})
      p
    end
  end

  # Nine players, round one won by White throughout: round two's top
  # bracket is odd, so somebody floats out of it, and the field is odd, so
  # somebody has the bye.
  defp round_two do
    t = tournament()
    roster(t, 9)
    {:ok, r1} = Pairing.pair_next_round(t)

    for p <- Repo.preload(r1, :pairings).pairings, p.black_player_id do
      {:ok, _} = Tournaments.update_pairing_result(p, "1-0")
    end

    {:ok, r2} = Pairing.pair_next_round(Repo.reload!(t))
    {Repo.reload!(t), Tournaments.get_round(t.id, r2.number)}
  end

  defp question_keys(round, t) do
    [section] = RoundExplanation.for_round(round, Tournaments.list_players(t.id))
    floats = for b <- section.brackets, q <- b.float_questions, do: q.key
    {floats, section.bye_question && section.bye_question.key}
  end

  defp subscribe(t) do
    Phoenix.PubSub.subscribe(PairingsEngine.PubSub, ExplanationJobs.alternatives_topic(t.id))
    Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(t.id))
  end

  test "after pairing the account is ready with the brackets, and no alternative worked out" do
    t = tournament()
    roster(t, 9)
    subscribe(t)
    jobs(:async)

    {:ok, paired} = Pairing.pair_next_round(t)
    assert Pairing.explanation_state(paired) == :pending
    assert_receive {:tournament_changed, _, :explanation}, 10_000

    round = Tournaments.get_round(t.id, paired.number)
    assert Pairing.explanation_state(round) == :ready
    assert %{"version" => 4, "alternatives" => "on_demand", "job" => job} = round.explanation
    # The pending record's fingerprint, kept: the answers are stored against it.
    assert job == paired.explanation["job"]

    [section] = round.explanation["sections"]
    assert [_ | _] = section["brackets"]
    assert is_nil(section["bye"])
    assert section["bye_holder"]
    assert length(section["pairs"]) == 5

    assert Pairing.stored_alternatives(round) == %{}
    assert SlowExplainer.question_calls() == 0
  end

  test "one question's answer is exactly the engine's answer for that floater" do
    {t, round} = round_two()
    {:ok, field} = Pairing.engine_field(t, round.number)
    {:ok, pairs} = Pairing.field_pairs(field)

    all = Ainalrami.Alternatives.float_alternatives(field.players, pairs, field.opts)
    assert [_ | _] = all

    for entry <- all do
      assert Explainer.float_question(
               field.players,
               pairs,
               field.opts,
               entry.group,
               entry.floater
             ) ==
               entry
    end

    assert Explainer.bye_question(field.players, pairs, field.opts) ==
             Ainalrami.Alternatives.bye_alternatives(field.players, pairs, field.opts)
  end

  test "opening a question works it out and stores it; opening it again reads it back" do
    {t, round} = round_two()
    {[float | _], bye} = question_keys(round, t)
    assert bye

    assert Pairing.open_alternative(t, round.number, float) == :started
    assert SlowExplainer.question_calls() == 1

    stored = Pairing.stored_alternatives(round)
    assert %{^float => %{"floater" => floater, "candidates" => [_ | _]}} = stored
    assert "float/0/" <> rest = float
    assert String.ends_with?(rest, "/#{floater}")

    # Somebody else, later: stored, not worked out again.
    assert Pairing.open_alternative(t, round.number, float) == :stored
    assert SlowExplainer.question_calls() == 1

    # Every question of the round, answered and read back resolved.
    assert Pairing.open_alternative(t, round.number, bye) == :started

    answers =
      RoundExplanation.answers(Pairing.stored_alternatives(round), Tournaments.list_players(t.id))

    assert %{holder: %{}, candidates: [_ | _]} = answers[bye]
    assert %{floater: %{}, candidates: [_ | _]} = answers[float]

    # Nothing about the round changed: the account is the one stored.
    assert Tournaments.get_round(t.id, round.number).explanation == round.explanation
  end

  test "an answer never outlives its pairing" do
    {t, round} = round_two()
    {_floats, bye} = question_keys(round, t)
    subscribe(t)
    jobs(:async)
    questions({:block, self()})

    assert Pairing.open_alternative(t, round.number, bye) == :started
    assert_receive {:alternative_started, _worker}, 5_000
    assert_receive {:round_alternative, _, _, ^bye, :running}, 5_000

    assert MapSet.member?(
             ExplanationJobs.running_alternatives(round.id, round.explanation["job"]),
             bye
           )

    [{job_pid, _}] =
      Registry.lookup(PairingsEngine.ExplanationJobRegistry, {:alternative, round.id, bye})

    ref = Process.monitor(job_pid)

    # Unpairing stops it, and an answer arriving late is refused.
    assert :ok = Pairing.delete_round(t.id, round.number)
    assert_receive {:DOWN, ^ref, :process, ^job_pid, _}, 5_000

    assert ExplanationJobs.store_alternative(round.id, round.explanation["job"], bye, %{}) ==
             :stale

    # Paired again - SQLite may hand the same row id out - it starts empty,
    # and an answer stored for the old pairing is never read as its own.
    questions(:real)
    jobs(:inline)
    {:ok, again} = Pairing.pair_next_round(Repo.reload!(t))
    again = Tournaments.get_round(t.id, again.number)
    assert again.explanation["job"] != round.explanation["job"]
    assert Pairing.stored_alternatives(again) == %{}
    assert Pairing.open_alternative(t, again.number, bye) == :started
    assert %{^bye => _} = Pairing.stored_alternatives(again)

    assert :ok = Pairing.delete_round(t.id, again.number)
    assert Repo.aggregate(PairingsEngine.Tournaments.RoundAlternative, :count) == 0
  end

  test "a question that fails says so, stores nothing, and can be tried again" do
    {t, round} = round_two()
    {[float | _], _bye} = question_keys(round, t)
    subscribe(t)
    jobs(:async)
    questions(:raise)

    assert Pairing.open_alternative(t, round.number, float) == :started
    assert_receive {:round_alternative, _, _, ^float, :failed}, 10_000
    assert Pairing.stored_alternatives(round) == %{}

    refute MapSet.member?(
             ExplanationJobs.running_alternatives(round.id, round.explanation["job"]),
             float
           )

    questions(:real)
    assert Pairing.open_alternative(t, round.number, float) == :started
    assert_receive {:round_alternative, _, _, ^float, :ready}, 10_000
    assert %{^float => _} = Pairing.stored_alternatives(round)
  end

  test "a category-paired round answers each section's question from its own field" do
    t =
      Repo.insert!(%Tournament{
        name: "Sections",
        type: "swiss",
        rounds_count: 5,
        tiebreaks: ~w(BH),
        initial_colour: "white",
        round_dates: List.duplicate("2026-09-01", 5),
        pair_by_category: true,
        categories_enabled: true,
        categories: ["A", "B"]
      })

    players =
      for n <- 1..10 do
        {:ok, p} =
          Tournaments.create_player(t.id, %{
            "name" => "P#{n}",
            "fide_rating" => 2100 - n,
            "category" => if(rem(n, 2) == 1, do: "A", else: "B")
          })

        p
      end

    {:ok, round} = Pairing.pair_next_round(t)
    round = Tournaments.get_round(t.id, round.number)
    assert [%{"category" => "A"} = a, %{"category" => "B"} = b] = round.explanation["sections"]

    assert Pairing.open_alternative(t, 1, "bye/1") == :started
    assert %{"bye/1" => bye} = Pairing.stored_alternatives(round)

    in_b = for p <- players, p.category == "B", into: MapSet.new(), do: p.id
    assert bye["holder"] == b["bye_holder"]
    assert bye["holder"] != a["bye_holder"]
    assert Enum.all?(bye["candidates"], &MapSet.member?(in_b, &1["player"]))
    assert length(bye["candidates"]) == 4
  end

  test "only a question the account asks can be opened" do
    {t, round} = round_two()
    [p | _] = Tournaments.list_players(t.id)

    for question <- ["bye/1", "float/0/0/#{p.id}", "float/0/99/1", "../../etc", "bye/-1", ""] do
      assert Pairing.open_alternative(t, round.number, question) == {:error, :stale}
    end

    assert SlowExplainer.question_calls() == 0
  end

  test "a round paired before this change keeps the alternatives it stored" do
    {t, round} = round_two()
    {:ok, field} = Pairing.engine_field(t, round.number)
    {:ok, pairs} = Pairing.field_pairs(field)
    floater = hd(Ainalrami.Alternatives.float_alternatives(field.players, pairs, field.opts))
    floater_id = field.player_by_local_rank[floater.floater].id

    # A version-3 record: its alternatives inline, no questions.
    v3 =
      round.explanation
      |> Map.put("version", 3)
      |> Map.drop(["alternatives", "job"])
      |> update_in(["sections"], fn [section] ->
        [
          section
          |> Map.drop(["bye_holder", "pairs"])
          |> Map.update!("brackets", fn brackets ->
            Enum.map(brackets, fn b ->
              alts =
                if floater_id in b["floats"],
                  do: [%{"floater" => floater_id, "candidates" => []}],
                  else: []

              Map.put(b, "float_alternatives", alts)
            end)
          end)
        ]
      end)

    round = round |> Ecto.Changeset.change(explanation: v3) |> Repo.update!()

    [section] = RoundExplanation.for_round(round, Tournaments.list_players(t.id))
    assert is_nil(section.bye_question)
    assert Enum.all?(section.brackets, &(&1.float_questions == []))

    assert Enum.any?(
             section.brackets,
             &match?([%{floater: %{id: ^floater_id}}], &1.float_alternatives)
           )

    assert Pairing.stored_alternatives(round) == %{}

    assert Pairing.open_alternative(t, round.number, "float/0/0/#{floater_id}") ==
             {:error, :stale}
  end
end
