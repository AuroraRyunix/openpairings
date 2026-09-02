defmodule PairingsEngine.HandoffLifecycleTest do
  @moduledoc """
  The lifecycle actions - archive, bin, purge - against the hand-off lock.

  These three were never gated by `ensure_writable/1`, and were right not to
  be: archiving and binning are what you do to a tournament, not writes to
  the record of one, and a tournament being read-only has never been a
  reason you cannot file it away.

  Hand-off breaks that reasoning in one specific place. The lock's way back
  in is the token, and the token is compared against `tournaments.handoff_token`
  on THIS row. Destroy the row and the copy running the event has nothing to
  come back to: `take_back/2` has nothing to compare, `force_take_back/2`
  has nothing to unlock, and the tournament is stranded on the other machine
  with no route home. That is not a lifecycle decision, it is the deletion
  of the only key to a lock somebody else is standing behind.
  """
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Tournaments.Tournament
  alias PairingsEngine.Accounts.{Scope, User}

  defp user_scope do
    user =
      Repo.insert!(%User{
        email: "lifecycle#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    Scope.for_user(user)
  end

  defp tournament(scope) do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "Lifecycle Test",
        "type" => "swiss",
        "rounds_count" => "3"
      })

    t
  end

  defp handed_off(scope, label \\ "this laptop") do
    {:ok, t} = Tournaments.hand_off(tournament(scope), label)
    t
  end

  describe "purging" do
    test "is refused while handed off - it would destroy the row the token unlocks" do
      scope = user_scope()
      t = handed_off(scope)

      assert Tournaments.purge_tournament(t) == {:error, :handed_off}
      assert Repo.reload!(t)
    end

    test "the copy running the event can still come home afterwards" do
      # The whole point of the refusal, stated as the property it protects.
      scope = user_scope()
      t = handed_off(scope)

      assert Tournaments.purge_tournament(t) == {:error, :handed_off}
      assert {:ok, back} = Tournaments.take_back(Repo.reload!(t), t.handoff_token)
      refute back.handed_off_at
    end

    test "the hard delete underneath it refuses too, by whichever name it is called" do
      scope = user_scope()
      t = handed_off(scope)

      assert Tournaments.delete_tournament(t) == {:error, :handed_off}
      assert Repo.reload!(t)
    end

    test "and goes through the moment it is back" do
      scope = user_scope()
      t = handed_off(scope)
      {:ok, back} = Tournaments.take_back(t, t.handoff_token)

      assert {:ok, _} = Tournaments.purge_tournament(back)
      refute Repo.get(Tournament, t.id)
    end
  end

  describe "the automatic 90-day sweep" do
    test "leaves a handed-off tournament in the bin and does not count it as purged" do
      # Reachable in the other order: bin it, then hand it off. A sweep that
      # silently ate this row would strand the running copy months later,
      # with nobody watching.
      scope = user_scope()
      binned = tournament(scope)
      {:ok, binned} = Tournaments.soft_delete_tournament(binned)
      {:ok, binned} = Tournaments.hand_off(binned, "this laptop")

      long_ago = DateTime.utc_now() |> DateTime.add(-200, :day) |> DateTime.truncate(:second)

      {:ok, _} = binned |> Ecto.Changeset.change(deleted_at: long_ago) |> Repo.update()

      ordinary = tournament(scope)
      {:ok, ordinary} = Tournaments.soft_delete_tournament(ordinary)
      {:ok, _} = ordinary |> Ecto.Changeset.change(deleted_at: long_ago) |> Repo.update()

      assert Tournaments.purge_expired_tournaments() == 1

      assert Repo.get(Tournament, binned.id)
      refute Repo.get(Tournament, ordinary.id)
    end
  end

  describe "binning" do
    test "is refused while handed off" do
      # The bin is a purge on a 90-day timer, and every fetch path already
      # treats a binned tournament as gone - so the returning payload would
      # find nothing to apply itself to long before the row went.
      scope = user_scope()
      t = handed_off(scope)

      assert Tournaments.soft_delete_tournament(t) == {:error, :handed_off}
      refute Repo.reload!(t).deleted_at
    end

    test "restoring is never blocked - it is a way back, not a way out" do
      scope = user_scope()
      binned = tournament(scope)
      {:ok, binned} = Tournaments.soft_delete_tournament(binned)
      {:ok, binned} = Tournaments.hand_off(binned, "this laptop")

      assert {:ok, restored} = Tournaments.restore_tournament(binned)
      refute restored.deleted_at
      assert restored.handed_off_at
    end
  end

  describe "archiving" do
    test "is refused while handed off" do
      # Symmetry with `hand_off/2`, which already refuses an archived
      # tournament. Allowed in only one direction, the combined state would
      # be reachable by ordering two buttons one way and unreachable the
      # other, which is a state nobody designed.
      scope = user_scope()
      t = handed_off(scope)

      assert Tournaments.archive_tournament(t) == {:error, :handed_off}
      refute Repo.reload!(t).archived_at
    end

    test "the refusal is what keeps every other refusal in the app honest" do
      # `ensure_writable/1` reports `:archived` first when a tournament is
      # both. So an archived, handed-off tournament tells the arbiter to
      # unarchive - and after they do, every write is still refused, this
      # time for the reason they were never shown. One state, two truths,
      # only one of them on screen.
      scope = user_scope()
      t = handed_off(scope)

      assert Tournaments.archive_tournament(t) == {:error, :handed_off}
      assert Tournaments.ensure_writable(Repo.reload!(t)) == {:error, :handed_off}
    end

    test "unarchiving is never blocked - an already-both tournament must have a way out" do
      # The state is unreachable through the public API now, but rows
      # predating the gate exist and nothing may trap them.
      scope = user_scope()
      t = handed_off(scope)

      {:ok, both} =
        t
        |> Ecto.Changeset.change(archived_at: DateTime.utc_now() |> DateTime.truncate(:second))
        |> Repo.update()

      assert {:ok, unarchived} = Tournaments.unarchive_tournament(both)
      refute unarchived.archived_at
      assert unarchived.handed_off_at
    end

    test "and goes through the moment it is back" do
      scope = user_scope()
      t = handed_off(scope)
      {:ok, back} = Tournaments.take_back(t, t.handoff_token)

      assert {:ok, archived} = Tournaments.archive_tournament(back)
      assert archived.archived_at
    end
  end

  describe "a forced unlock also clears the way" do
    test "the owner who lost the other copy can then bin, archive and purge again" do
      scope = user_scope()
      t = handed_off(scope)

      assert Tournaments.archive_tournament(t) == {:error, :handed_off}

      {:ok, unlocked} = Tournaments.force_take_back(t, scope)

      assert {:ok, archived} = Tournaments.archive_tournament(unlocked)
      assert {:ok, _} = Tournaments.purge_tournament(archived)
    end
  end
end
