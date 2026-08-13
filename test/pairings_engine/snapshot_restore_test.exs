defmodule PairingsEngine.SnapshotRestoreTest do
  @moduledoc """
  Restoring overwrites live scoring data, so these lean on the destructive
  cases: that the right things come back, that the things a restore must NOT
  touch survive it, and that going back is itself reversible.
  """
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{Audit, Repo, Snapshots, Tournaments}
  alias PairingsEngine.Snapshots.Snapshot
  alias PairingsEngine.Tournaments.{Pairing, Player, Round}
  alias PairingsEngine.Accounts.{Scope, User}

  defp user_scope do
    user =
      Repo.insert!(%User{
        email: "restore#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    Scope.for_user(user)
  end

  defp tournament(scope, attrs) do
    {:ok, t} =
      Tournaments.create_tournament(
        scope,
        Map.merge(%{"name" => "Restore Test", "type" => "swiss", "rounds_count" => "3"}, attrs)
      )

    t
  end

  # A tournament with a played round — the state we'll snapshot and come back to.
  defp played(scope, attrs \\ %{}) do
    t = tournament(scope, attrs)
    a = Repo.insert!(%Player{tournament_id: t.id, name: "Alice", fide_rating: 2100})
    b = Repo.insert!(%Player{tournament_id: t.id, name: "Bob", fide_rating: 1900})
    r = Repo.insert!(%Round{tournament_id: t.id, number: 1, status: "finished"})

    Repo.insert!(%Pairing{
      round_id: r.id,
      board: 1,
      white_player_id: a.id,
      black_player_id: b.id,
      result: "1-0"
    })

    {t, a, b}
  end

  describe "restore/3 brings the contents back" do
    test "players, rounds and results return to the snapshotted state" do
      scope = user_scope()
      {t, _a, _b} = played(scope)

      {:ok, snapshot} = Snapshots.capture(t, "manual", scope, summary: "Good state")

      # Wreck it: delete the round, add a bogus player.
      Repo.delete_all(from r in Round, where: r.tournament_id == ^t.id)
      Repo.insert!(%Player{tournament_id: t.id, name: "Should Not Survive"})

      assert {:ok, restored} = Snapshots.restore(t, snapshot.id, scope)

      names = restored.id |> Tournaments.list_players() |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["Alice", "Bob"]

      assert %Round{pairings: [pairing]} = Tournaments.get_round(restored.id, 1)
      assert pairing.result == "1-0"
    end

    test "settings come back too" do
      scope = user_scope()
      t = tournament(scope, %{"pairing_system" => "keizer", "points_win" => "3"})

      {:ok, snapshot} = Snapshots.capture(t, "manual", scope)

      {:ok, _} =
        Tournaments.update_tournament(t, %{"pairing_system" => "swiss", "points_win" => "1"})

      assert {:ok, restored} = Snapshots.restore(Repo.reload!(t), snapshot.id, scope)

      assert restored.pairing_system == "keizer"
      assert restored.points_win == 3.0
    end

    test "byes and forbidden pairings are restored, not left behind" do
      scope = user_scope()
      {t, a, b} = played(scope)

      {:ok, _} = Tournaments.add_forbidden_pairing(t, a.id, b.id)
      Repo.insert_all("byes", [%{tournament_id: t.id, player_id: b.id, round: 2, type: "absent"}])

      {:ok, snapshot} = Snapshots.capture(t, "manual", scope)

      # Clear both, then restore.
      Repo.delete_all(from f in "forbidden_pairings", where: f.tournament_id == ^t.id)
      Repo.delete_all(from bb in "byes", where: bb.tournament_id == ^t.id)

      assert {:ok, restored} = Snapshots.restore(t, snapshot.id, scope)

      assert [fp] = Tournaments.list_forbidden_pairings(restored.id)
      assert Enum.sort([fp.player_a.name, fp.player_b.name]) == ["Alice", "Bob"]

      assert [bye] = Tournaments.list_byes_for_round(restored.id, 2)
      assert bye.type == "absent"
    end

    test "state added after the snapshot is gone afterwards" do
      scope = user_scope()
      {t, _a, _b} = played(scope)
      {:ok, snapshot} = Snapshots.capture(t, "manual", scope)

      Repo.insert!(%Player{tournament_id: t.id, name: "Added Later"})

      {:ok, restored} = Snapshots.restore(t, snapshot.id, scope)

      refute restored.id
             |> Tournaments.list_players()
             |> Enum.any?(&(&1.name == "Added Later"))
    end

    test "the tournament's status is re-derived from what actually landed" do
      scope = user_scope()
      {t, _a, _b} = played(scope)
      {:ok, snapshot} = Snapshots.capture(t, "manual", scope)

      Repo.delete_all(from r in Round, where: r.tournament_id == ^t.id)
      {:ok, _} = Tournaments.refresh_status!(t.id) |> then(&{:ok, &1})
      assert Repo.reload!(t).status == "setup"

      {:ok, restored} = Snapshots.restore(Repo.reload!(t), snapshot.id, scope)

      # One paired round back, so no longer "setup".
      refute restored.status == "setup"
    end
  end

  describe "restore/3 leaves alone what it must not touch" do
    test "the audit log survives — the record of what happened isn't rolled back" do
      scope = user_scope()
      {t, _a, _b} = played(scope)

      Audit.log(t.id, scope, "player.created", %{"player_name" => "Alice"})
      {:ok, snapshot} = Snapshots.capture(t, "manual", scope)
      Audit.log(t.id, scope, "pairing.round_deleted", %{"round" => 1})

      before_count = length(Audit.list_for_tournament(t.id))

      {:ok, _} = Snapshots.restore(t, snapshot.id, scope)

      # Nothing removed; the restore adds its own entry via the caller, but
      # the pre-existing history is intact either way.
      assert length(Audit.list_for_tournament(t.id)) >= before_count
      actions = t.id |> Audit.list_for_tournament() |> Enum.map(& &1.action)
      assert "pairing.round_deleted" in actions
    end

    test "other snapshots survive, so the timeline isn't self-erasing" do
      scope = user_scope()
      {t, _a, _b} = played(scope)

      {:ok, first} = Snapshots.capture(t, "manual", scope, summary: "First")
      {:ok, second} = Snapshots.capture(t, "manual", scope, summary: "Second")

      {:ok, _} = Snapshots.restore(t, first.id, scope)

      remaining = t.id |> Snapshots.list() |> Enum.map(& &1.id)
      assert first.id in remaining
      assert second.id in remaining
    end

    test "collaborators keep their access" do
      scope = user_scope()
      other = user_scope()
      {t, _a, _b} = played(scope)

      {:ok, _} = Tournaments.add_collaborator(scope, t, other.user.email)
      before = length(Tournaments.list_collaborators(t))
      assert before == 1

      {:ok, snapshot} = Snapshots.capture(t, "manual", scope)
      {:ok, _} = Snapshots.restore(t, snapshot.id, scope)

      assert length(Tournaments.list_collaborators(Repo.reload!(t))) == before
    end

    test "the public slug and sharing state are untouched" do
      scope = user_scope()
      {t, _a, _b} = played(scope)

      {:ok, snapshot} = Snapshots.capture(t, "manual", scope)

      # Turn sharing ON after the snapshot was taken. A restore must not
      # turn it back off (nor, in the reverse case, silently re-publish).
      {:ok, t} = Tournaments.set_public_pages(t, true)
      slug = t.public_slug

      {:ok, restored} = Snapshots.restore(t, snapshot.id, scope)

      assert restored.public_pages_enabled
      assert restored.public_slug == slug
    end

    test "ownership is untouched" do
      scope = user_scope()
      {t, _a, _b} = played(scope)
      {:ok, snapshot} = Snapshots.capture(t, "manual", scope)

      {:ok, restored} = Snapshots.restore(t, snapshot.id, scope)

      assert restored.user_id == scope.user.id
    end
  end

  describe "going back is itself reversible" do
    test "restoring captures the state it replaced, pinned" do
      scope = user_scope()
      {t, _a, _b} = played(scope)

      {:ok, old} = Snapshots.capture(t, "manual", scope, summary: "Old state")

      # Move forward: add a player that only exists in the *current* state.
      Repo.insert!(%Player{tournament_id: t.id, name: "Only In New State"})

      {:ok, _} = Snapshots.restore(t, old.id, scope)

      # A new restore-point should hold the state we just left.
      assert [newest | _] = Snapshots.list(t.id)
      assert newest.trigger == "snapshot.restored"
      assert newest.summary =~ "Old state"
      assert newest.pinned
    end

    test "you can jump back to where you were before going back" do
      scope = user_scope()
      {t, _a, _b} = played(scope)

      {:ok, old} = Snapshots.capture(t, "manual", scope, summary: "Old state")
      Repo.insert!(%Player{tournament_id: t.id, name: "Only In New State"})

      # Go back...
      {:ok, _} = Snapshots.restore(t, old.id, scope)

      refute t.id |> Tournaments.list_players() |> Enum.any?(&(&1.name == "Only In New State"))

      # ...then forward again, using the restore point the restore left.
      [forward | _] = Snapshots.list(t.id)
      {:ok, _} = Snapshots.restore(Repo.reload!(t), forward.id, scope)

      assert t.id |> Tournaments.list_players() |> Enum.any?(&(&1.name == "Only In New State"))
    end

    test "pinned restore points are never pruned away by ordinary captures" do
      scope = user_scope()
      {t, _a, _b} = played(scope)

      {:ok, old} = Snapshots.capture(t, "manual", scope, summary: "Old state")
      {:ok, _} = Snapshots.restore(t, old.id, scope)

      [pinned | _] = Snapshots.list(t.id)
      assert pinned.pinned

      # Flood past the retention limit with ordinary captures.
      for _ <- 1..(Snapshots.keep_per_tournament() + 5) do
        {:ok, _} = Snapshots.capture(Repo.reload!(t), "bulk", scope)
      end

      # The pinned one survives; the unpinned ones are capped as usual.
      assert Repo.get(Snapshot, pinned.id)

      unpinned_count =
        Repo.aggregate(
          from(s in Snapshot, where: s.tournament_id == ^t.id and s.pinned == false),
          :count
        )

      assert unpinned_count == Snapshots.keep_per_tournament()
    end
  end

  describe "refusals" do
    test "an archived tournament refuses to restore" do
      scope = user_scope()
      {t, _a, _b} = played(scope)
      {:ok, snapshot} = Snapshots.capture(t, "manual", scope)
      {:ok, archived} = Tournaments.archive_tournament(t)

      assert Snapshots.restore(archived, snapshot.id, scope) == {:error, :archived}

      # And nothing was captured on the way to refusing.
      assert Snapshots.count(t.id) == 1
    end

    test "a snapshot id from another tournament is not reachable" do
      scope = user_scope()
      {mine, _a, _b} = played(scope)
      {theirs, _c, _d} = played(scope, %{"name" => "Someone Else"})

      {:ok, their_snapshot} = Snapshots.capture(theirs, "manual", scope)

      assert Snapshots.restore(mine, their_snapshot.id, scope) == {:error, :not_found}
    end

    test "an unknown snapshot id is refused rather than raising" do
      scope = user_scope()
      {t, _a, _b} = played(scope)

      assert Snapshots.restore(t, 999_999, scope) == {:error, :not_found}
    end

    test "a malformed payload is refused rather than wiping the tournament" do
      scope = user_scope()
      {t, _a, _b} = played(scope)

      {:ok, snapshot} = Snapshots.capture(t, "manual", scope)
      # Corrupt the stored payload the way a bad migration or hand-edit could.
      Repo.update_all(
        from(s in Snapshot, where: s.id == ^snapshot.id),
        set: [payload: %{"tournaments" => []}]
      )

      assert Snapshots.restore(t, snapshot.id, scope) == {:error, :malformed_snapshot}

      # Crucially: the tournament still has its contents.
      assert length(Tournaments.list_players(t.id)) == 2
      assert Tournaments.get_round(t.id, 1)
    end
  end

  describe "atomicity" do
    test "a failure part-way leaves the tournament as it was" do
      scope = user_scope()
      {t, _a, _b} = played(scope)

      {:ok, snapshot} = Snapshots.capture(t, "manual", scope)

      # Make one player in the payload invalid (blank name violates
      # validate_required), so the rebuild raises mid-transaction.
      broken =
        update_in(
          Repo.get(Snapshot, snapshot.id).payload,
          ["tournaments", Access.at(0), "players"],
          fn players -> Enum.map(players, &Map.put(&1, "name", "")) end
        )

      Repo.update_all(from(s in Snapshot, where: s.id == ^snapshot.id), set: [payload: broken])

      assert {:error, _reason} = Snapshots.restore(t, snapshot.id, scope)

      # The wipe and the rebuild share one transaction, so a failed rebuild
      # must roll the wipe back too — otherwise a bad snapshot would destroy
      # the tournament it was supposed to protect.
      players = Tournaments.list_players(t.id)
      assert length(players) == 2
      assert Enum.map(players, & &1.name) |> Enum.sort() == ["Alice", "Bob"]
      assert %Round{pairings: [_]} = Tournaments.get_round(t.id, 1)
    end
  end
end
