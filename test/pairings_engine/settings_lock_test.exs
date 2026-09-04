defmodule PairingsEngine.SettingsLockTest do
  @moduledoc """
  Settings that decide the shape of rounds which already exist are frozen
  once the first round is paired - changing them afterwards silently
  reinterprets history (flip `pairing_system` to Keizer and the rounds
  already on the board are scored by different rules).

  These were previously enforced only by the Settings LiveViews, which meant
  any other caller went straight through. The tests here are specifically
  about the *context* refusing, not about disabled inputs.
  """
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{Repo, Snapshots, Tournaments}
  alias PairingsEngine.Tournaments.{Pairing, Player, Round, Tournament}
  alias PairingsEngine.Accounts.{Scope, User}

  defp user_scope do
    user =
      Repo.insert!(%User{
        email: "lock#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    Scope.for_user(user)
  end

  defp tournament(attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Tournament{name: "Locks", type: "swiss", rounds_count: 5, tiebreaks: ~w(BH)},
        attrs
      )
    )
  end

  defp pair_a_round(t) do
    a = Repo.insert!(%Player{tournament_id: t.id, name: "A"})
    b = Repo.insert!(%Player{tournament_id: t.id, name: "B"})
    r = Repo.insert!(%Round{tournament_id: t.id, number: 1, status: "finished"})

    Repo.insert!(%Pairing{
      round_id: r.id,
      board: 1,
      white_player_id: a.id,
      black_player_id: b.id,
      result: "1-0"
    })

    Repo.reload!(t)
  end

  describe "locked_fields/1" do
    test "nothing is locked before a round is paired" do
      assert Tournaments.locked_fields(tournament()) == []
    end

    test "the pairing-shape and absence-scoring settings lock once a round exists" do
      locked = tournament() |> pair_a_round() |> Tournaments.locked_fields()

      for field <- ~w(pairing_system pairing_engine rr_match_format swiss_match_format
                      pair_by_category abs_value abs_jusque abs_nbfois)a do
        assert field in locked, "#{field} should be frozen once a round is paired"
      end
    end

    test "rr_cycles stays open while the paired rounds are still inside cycle 1" do
      # 4 players -> a single cycle is 3 rounds, so one paired round is well
      # inside it and switching single/double is still harmless.
      t = tournament(%{pairing_system: "round_robin", rr_cycles: 1})
      for n <- 1..4, do: Repo.insert!(%Player{tournament_id: t.id, name: "P#{n}"})
      t = pair_a_round(t)

      refute :rr_cycles in Tournaments.locked_fields(t)
    end

    test "rr_cycles locks once the paired rounds reach what the setting implies" do
      t = tournament(%{pairing_system: "round_robin", rr_cycles: 1})
      a = Repo.insert!(%Player{tournament_id: t.id, name: "A"})
      b = Repo.insert!(%Player{tournament_id: t.id, name: "B"})

      # 2 players, single cycle => 1 round is the whole schedule.
      r = Repo.insert!(%Round{tournament_id: t.id, number: 1})

      Repo.insert!(%Pairing{
        round_id: r.id,
        board: 1,
        white_player_id: a.id,
        black_player_id: b.id,
        result: "1-0"
      })

      assert :rr_cycles in Tournaments.locked_fields(Repo.reload!(t))
    end
  end

  describe "update_tournament/2 refuses a locked change" do
    test "pairing_system cannot be switched after round 1" do
      t = tournament() |> pair_a_round()

      assert Tournaments.update_tournament(t, %{"pairing_system" => "keizer"}) ==
               {:error, :locked_after_pairing}

      assert Repo.reload!(t).pairing_system == "swiss"
    end

    test "the absence-scoring trio cannot be changed after round 1" do
      t = tournament() |> pair_a_round()

      for {field, value} <- [{"abs_value", "0.5"}, {"abs_jusque", "7"}, {"abs_nbfois", "2"}] do
        assert Tournaments.update_tournament(t, %{field => value}) ==
                 {:error, :locked_after_pairing}
      end

      reloaded = Repo.reload!(t)
      refute reloaded.abs_value
      refute reloaded.abs_jusque
      refute reloaded.abs_nbfois
    end

    test "an unlocked field alongside a locked one is refused as a whole" do
      t = tournament() |> pair_a_round()

      assert Tournaments.update_tournament(t, %{
               "venue" => "Town Hall",
               "pairing_system" => "keizer"
             }) == {:error, :locked_after_pairing}

      # All-or-nothing: the innocent field must not sneak through either,
      # or a caller would think the whole save landed.
      assert Repo.reload!(t).venue == ""
    end
  end

  describe "update_tournament/3 with the :unlock option - deliberate override" do
    test "a locked field named in :unlock is no longer refused" do
      t = tournament() |> pair_a_round()

      assert {:ok, updated} =
               Tournaments.update_tournament(t, %{"pairing_system" => "keizer"},
                 unlock: [:pairing_system]
               )

      assert updated.pairing_system == "keizer"
    end

    test "only the named field is unlocked - an untouched locked field alongside it is still refused" do
      t = tournament() |> pair_a_round()

      assert Tournaments.update_tournament(
               t,
               %{"pairing_system" => "keizer", "abs_value" => "0.5"},
               unlock: [:pairing_system]
             ) == {:error, :locked_after_pairing}

      # All-or-nothing, same as the plain refusal above - naming ONE field
      # in :unlock must not let a second, un-named locked field ride along.
      reloaded = Repo.reload!(t)
      assert reloaded.pairing_system == "swiss"
      refute reloaded.abs_value
    end

    test "the unlock does not persist - a second call without it is refused again" do
      t = tournament() |> pair_a_round()

      assert {:ok, updated} =
               Tournaments.update_tournament(t, %{"pairing_system" => "keizer"},
                 unlock: [:pairing_system]
               )

      # Same tournament, same field, no :unlock this time.
      assert Tournaments.update_tournament(updated, %{"pairing_system" => "swiss"}) ==
               {:error, :locked_after_pairing}

      assert Repo.reload!(updated).pairing_system == "keizer"
    end

    test "the whole absence-scoring trio can be unlocked together" do
      t = tournament() |> pair_a_round()

      assert {:ok, updated} =
               Tournaments.update_tournament(
                 t,
                 %{"abs_value" => "0.5", "abs_jusque" => "7", "abs_nbfois" => "2"},
                 unlock: [:abs_value, :abs_jusque, :abs_nbfois]
               )

      assert updated.abs_value == 0.5
      assert updated.abs_jusque == 7
      assert updated.abs_nbfois == 2
    end

    test "an empty :unlock refuses exactly like update_tournament/2" do
      t = tournament() |> pair_a_round()

      assert Tournaments.update_tournament(t, %{"pairing_system" => "keizer"}, unlock: []) ==
               {:error, :locked_after_pairing}
    end

    test "ensure_unlocked/3 is what update_tournament/3 relies on, and can be called the same way" do
      t = tournament() |> pair_a_round()

      assert Tournaments.ensure_unlocked(t, %{"pairing_system" => "keizer"}) ==
               {:error, :locked_after_pairing}

      assert Tournaments.ensure_unlocked(t, %{"pairing_system" => "keizer"},
               unlock: [:pairing_system]
             ) == :ok
    end
  end

  describe "what stays allowed" do
    test "ordinary settings still save after round 1" do
      t = tournament() |> pair_a_round()

      assert {:ok, updated} = Tournaments.update_tournament(t, %{"venue" => "Town Hall"})
      assert updated.venue == "Town Hall"
    end

    test "submitting a locked field UNCHANGED is fine" do
      t = tournament() |> pair_a_round()

      # The real form case: the input is disabled but still posts its current
      # value. Refusing that would break every save on the page.
      assert {:ok, _} =
               Tournaments.update_tournament(t, %{
                 "pairing_system" => "swiss",
                 "venue" => "Town Hall"
               })
    end

    test "type coercion doesn't make an unchanged value look changed" do
      t = tournament(%{pairing_system: "round_robin", rr_cycles: 2})
      for n <- 1..3, do: Repo.insert!(%Player{tournament_id: t.id, name: "P#{n}"})
      t = pair_a_round(t)

      # "2" from a form vs the stored integer 2 - same value, must not read
      # as a change.
      assert {:ok, _} = Tournaments.update_tournament(t, %{"rr_cycles" => "2"})
    end

    test "everything is still free before the first round is paired" do
      t = tournament()

      assert {:ok, updated} =
               Tournaments.update_tournament(t, %{
                 "pairing_system" => "keizer",
                 "abs_value" => "0.5"
               })

      assert updated.pairing_system == "keizer"
      assert updated.abs_value == 0.5
    end

    test "restoring a snapshot sets locked fields back, by design" do
      scope = user_scope()

      {:ok, t} =
        Tournaments.create_tournament(scope, %{
          "name" => "Restorable",
          "type" => "swiss",
          "pairing_system" => "keizer",
          "rounds_count" => "3"
        })

      {:ok, snapshot} = Snapshots.capture(t, "manual", scope)

      # Move to a state where the lock would refuse an ordinary edit...
      t = pair_a_round(t)
      assert :pairing_system in Tournaments.locked_fields(t)

      # ...and confirm restore still puts the whole recorded state back.
      # It writes via TournamentImport.restore_into!/2 rather than
      # update_tournament/2 precisely so the lock doesn't block it.
      assert {:ok, restored} = Snapshots.restore(t, snapshot.id, scope)
      assert restored.pairing_system == "keizer"
    end
  end

  describe "the UI lock and the context lock are the same rule" do
    test "locked_fields/1 is what the Settings pages render from" do
      t = tournament() |> pair_a_round()
      locked = Tournaments.locked_fields(t)

      # If these ever diverge, a disabled input would still be writable (or
      # an enabled one refused) - the failure mode this whole module exists
      # to prevent.
      assert :pairing_system in locked
      assert :abs_value in locked
    end
  end
end
