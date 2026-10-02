defmodule PairingsEngine.EngineContractTest do
  @moduledoc """
  What OpenPairings hands Ainalrami's explanation calls (`explain_round/3`,
  `Ainalrami.Alternatives`): a complete pairing of the round's players and
  options in their canonical values. A stricter engine refuses anything else
  with an `ArgumentError`, so each place that could pass less is held here to
  not asking - and to saying nothing rather than logging a failure when
  there is nothing to ask about. These pass against the engine that
  tolerates an incomplete pairing as well as the one that refuses it.
  """
  use PairingsEngine.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import PairingsEngine.TeamFixtures

  alias PairingsEngine.Pairing, as: Engine
  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Tournaments.Tournament

  defp teams(n), do: for(i <- 1..n, do: {"T#{i}", [2000 - i * 10, 1990 - i * 10]})

  defp swiss(count) do
    t =
      Repo.insert!(%Tournament{
        name: "Contract",
        type: "swiss",
        rounds_count: 5,
        tiebreaks: ~w(BH),
        pairing_engine: "ainalrami",
        initial_colour: "white",
        round_dates: List.duplicate("2026-09-01", 5)
      })

    for n <- 1..count do
      {:ok, _} =
        Tournaments.create_player(t.id, %{"name" => "P#{n}", "fide_rating" => 2100 - n * 40})
    end

    t
  end

  describe "a team Swiss round" do
    test "has no individual explanation to work out, and none that fails" do
      {t, _} = team_swiss(teams(4), rounds: 3)

      log =
        capture_log(fn ->
          round = pair_next!(t)
          t = Repo.reload!(t)

          # Decided team against team: the individual engine has no account
          # of it, so there is none - not a failed one.
          assert Engine.explanation_state(round) == :none
          assert Engine.ensure_explanation(t, round) == :none
          assert Engine.reexplain_status(t, round) == :ineligible
          assert Engine.reexplain_round(t, 1) == {:skip, :ineligible}
          assert Engine.deepen_round(t, 1) == {:skip, :ineligible}

          assert {:error, :not_pending} = Engine.recompute_explanation(t, 1)
          assert Tournaments.get_round(t.id, 1).explanation["status"] == nil
        end)

      refute log =~ "could not be worked out"
      refute log =~ "invalid pairing"
      refute log =~ "could not judge"
    end
  end

  describe "an account asked for as the round finishes" do
    test "is not worked out again, and does not fail the finished one" do
      t = swiss(6)
      {:ok, round} = Engine.pair_next_round(t)
      round = Repo.reload!(round)
      assert Engine.explanation_state(round) == :ready

      # A page that read the round while it was still pending: the struct it
      # holds says so, the database no longer does.
      stale = %{round | explanation: Map.put(round.explanation, "status", "pending")}

      log =
        capture_log(fn ->
          assert {:error, :not_pending} = Engine.recompute_explanation(t, 1)
          assert Engine.ensure_explanation(t, stale) == :pending
        end)

      refute log =~ "could not be worked out"
      assert Engine.explanation_state(Repo.reload!(round)) == :ready
    end
  end

  describe "the boards of a round as played" do
    test "are a pairing to explain only when they are a complete one" do
      t = swiss(4)
      {:ok, round} = Engine.pair_next_round(t)
      {:ok, field} = Engine.engine_field(t, 1)
      assert {:ok, [_, _] = pairs} = Engine.field_pairs(field)
      assert Engine.complete_pairing?(pairs, [1, 2, 3, 4])

      # A board edited down to one seat: its other player is seated but in
      # no pairing, which the engine would read as a player given the bye.
      [_first, second] = Enum.sort_by(Repo.preload(round, :pairings).pairings, & &1.board)

      Repo.update_all(from_pairing(second.id), set: [white_player_id: nil])

      {:ok, field} = Engine.engine_field(Repo.reload!(t), 1)
      assert Engine.field_pairs(field) == :error
    end

    test "complete_pairing?/2 wants every player once, nobody else, and the byes the field has" do
      ok? = &Engine.complete_pairing?/2

      assert ok?.([{1, 2}, {3, 4}], [1, 2, 3, 4])
      assert ok?.([{1, 2}, {3, nil}], [1, 2, 3])

      # a player left out is not a player given the bye
      refute ok?.([{1, 2}], [1, 2, 3, 4])
      refute ok?.([{1, 2}, {3, 3}], [1, 2, 3])
      refute ok?.([{1, 2}, {2, 3}], [1, 2, 3])
      refute ok?.([{1, 2}, {3, 9}], [1, 2, 3])
      # a bye the field cannot have, and none where it has to
      refute ok?.([{1, 2}, {3, nil}, {4, nil}], [1, 2, 3, 4])
      refute ok?.([{1, 2}, {3, 4}, {5, 6}], [1, 2, 3, 4, 5])
    end
  end

  defp from_pairing(id) do
    from(p in Tournaments.Pairing, where: p.id == ^id)
  end
end
