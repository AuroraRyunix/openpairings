defmodule PairingsEngine.SnapshotsTest do
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{Repo, Snapshots, Tournaments}
  alias PairingsEngine.Snapshots.Snapshot
  alias PairingsEngine.Tournaments.{Player, Round}
  alias PairingsEngine.Accounts.{Scope, User}

  defp user_scope do
    user =
      Repo.insert!(%User{
        email: "snap#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    Scope.for_user(user)
  end

  defp tournament(scope, attrs \\ %{}) do
    {:ok, t} =
      Tournaments.create_tournament(
        scope,
        Map.merge(%{"name" => "Snapshot Test", "type" => "swiss", "rounds_count" => "3"}, attrs)
      )

    t
  end

  describe "capture/4" do
    test "stores a full export envelope tagged with trigger, actor and summary" do
      scope = user_scope()
      t = tournament(scope)
      {:ok, _} = Tournaments.create_player(t.id, %{"name" => "Alice"})

      assert {:ok, snapshot} =
               Snapshots.capture(t, "pairing.round_paired", scope, summary: "Before round 1")

      assert snapshot.trigger == "pairing.round_paired"
      assert snapshot.summary == "Before round 1"
      assert snapshot.user_id == scope.user.id
      assert snapshot.tournament_id == t.id

      # The payload is a real export envelope, not a bespoke shape.
      assert snapshot.payload["format"] == PairingsEngine.TournamentExport.format()
      assert [tournament_entry] = snapshot.payload["tournaments"]
      assert tournament_entry["tournament"]["name"] == "Snapshot Test"
      assert [%{"name" => "Alice"}] = tournament_entry["players"]
    end

    test "captures the state as it was, not as it becomes afterwards" do
      scope = user_scope()
      t = tournament(scope)
      {:ok, _} = Tournaments.create_player(t.id, %{"name" => "Only Player"})

      {:ok, snapshot} = Snapshots.capture(t, "pairing.round_paired", scope)

      # Change the world after the snapshot.
      {:ok, _} = Tournaments.create_player(t.id, %{"name" => "Added Later"})
      {:ok, _} = Tournaments.update_tournament(t, %{"name" => "Renamed Later"})

      stored = Snapshots.get(t.id, snapshot.id)
      entry = hd(stored.payload["tournaments"])

      assert entry["tournament"]["name"] == "Snapshot Test"
      assert Enum.map(entry["players"], & &1["name"]) == ["Only Player"]
    end

    test "accepts a bare user id or nil actor (system write)" do
      scope = user_scope()
      t = tournament(scope)

      assert {:ok, with_id} = Snapshots.capture(t, "system.thing", scope.user.id)
      assert with_id.user_id == scope.user.id

      assert {:ok, without} = Snapshots.capture(t, "system.thing", nil)
      assert without.user_id == nil
    end

    test "sharing state and lifecycle are deliberately not captured" do
      scope = user_scope()
      t = tournament(scope)
      {:ok, t} = Tournaments.set_public_pages(t, true)
      {:ok, t} = Tournaments.archive_tournament(t)

      {:ok, snapshot} = Snapshots.capture(t, "manual", scope)
      t_map = hd(snapshot.payload["tournaments"])["tournament"]

      # Restoring must never silently re-publish a tournament, hand back a
      # rotated slug, or change whether it's archived.
      for field <- ~w(public_pages_enabled registration_open public_slug archived_at deleted_at) do
        refute Map.has_key?(t_map, field)
      end
    end
  end

  describe "list/2 and get/2" do
    test "lists newest first, without the heavy payload" do
      scope = user_scope()
      t = tournament(scope)

      {:ok, _first} = Snapshots.capture(t, "one", scope, summary: "first")
      {:ok, second} = Snapshots.capture(t, "two", scope, summary: "second")

      assert [newest, oldest] = Snapshots.list(t.id)
      assert newest.id == second.id
      assert newest.summary == "second"
      assert oldest.summary == "first"

      # Payload is dropped from list rows - it's a whole tournament each.
      assert newest.payload == nil
      # ...but the acting user is preloaded, for rendering "who".
      assert newest.user.id == scope.user.id
    end

    test "get/2 returns the payload, and is scoped to the tournament" do
      scope = user_scope()
      mine = tournament(scope)
      other = tournament(scope, %{"name" => "Someone Else"})

      {:ok, snapshot} = Snapshots.capture(mine, "one", scope)

      assert %Snapshot{payload: payload} = Snapshots.get(mine.id, snapshot.id)
      assert payload["format"]

      # A crafted id from another tournament must not resolve.
      refute Snapshots.get(other.id, snapshot.id)
    end

    test "get/2 returns nil for an unknown id rather than raising" do
      scope = user_scope()
      t = tournament(scope)

      refute Snapshots.get(t.id, 999_999)
    end
  end

  describe "retention" do
    test "keeps only the most recent N per tournament, pruning on capture" do
      scope = user_scope()
      t = tournament(scope)
      keep = Snapshots.keep_per_tournament()

      # One more than the limit, so exactly one prune should happen.
      for n <- 1..(keep + 1) do
        {:ok, _} = Snapshots.capture(t, "bulk", scope, summary: "snapshot #{n}")
      end

      assert Snapshots.count(t.id) == keep

      # The oldest is the one that went.
      summaries = t.id |> Snapshots.list() |> Enum.map(& &1.summary)
      refute "snapshot 1" in summaries
      assert "snapshot #{keep + 1}" in summaries
    end

    test "pruning is per tournament - one busy tournament can't evict another's" do
      scope = user_scope()
      busy = tournament(scope, %{"name" => "Busy"})
      quiet = tournament(scope, %{"name" => "Quiet"})

      {:ok, _} = Snapshots.capture(quiet, "only-one", scope)

      for _ <- 1..(Snapshots.keep_per_tournament() + 5) do
        {:ok, _} = Snapshots.capture(busy, "bulk", scope)
      end

      assert Snapshots.count(quiet.id) == 1
      assert Snapshots.count(busy.id) == Snapshots.keep_per_tournament()
    end
  end

  describe "lifecycle" do
    test "snapshots are deleted along with their tournament" do
      scope = user_scope()
      t = tournament(scope)
      {:ok, _} = Snapshots.capture(t, "one", scope)

      assert Snapshots.count(t.id) == 1

      {:ok, _} = Tournaments.delete_tournament(t)

      assert Repo.aggregate(
               from(s in Snapshot, where: s.tournament_id == ^t.id),
               :count
             ) == 0
    end

    test "an archived tournament can still be snapshotted (reads are never blocked)" do
      scope = user_scope()
      t = tournament(scope)
      {:ok, t} = Tournaments.archive_tournament(t)

      assert {:ok, _} = Snapshots.capture(t, "manual", scope)
    end
  end

  describe "capture is fire-and-forget" do
    test "a snapshot of a tournament with rounds and byes still serializes cleanly" do
      scope = user_scope()
      t = tournament(scope)
      a = Repo.insert!(%Player{tournament_id: t.id, name: "Alice"})
      b = Repo.insert!(%Player{tournament_id: t.id, name: "Bob"})
      round = Repo.insert!(%Round{tournament_id: t.id, number: 1, status: "finished"})

      Repo.insert!(%PairingsEngine.Tournaments.Pairing{
        round_id: round.id,
        board: 1,
        white_player_id: a.id,
        black_player_id: b.id,
        result: "1-0"
      })

      Repo.insert_all("byes", [
        %{tournament_id: t.id, player_id: b.id, round: 2, type: "requested-half"}
      ])

      assert {:ok, snapshot} = Snapshots.capture(t, "pairing.round_paired", scope)

      entry = hd(snapshot.payload["tournaments"])
      assert [round_entry] = entry["rounds"]
      assert [pairing] = round_entry["pairings"]
      assert pairing["result"] == "1-0"
      assert [bye] = entry["byes"]
      assert bye["type"] == "requested-half"
    end

    test "the whole payload survives a real JSON encode/decode round trip" do
      scope = user_scope()
      t = tournament(scope)
      {:ok, _} = Tournaments.create_player(t.id, %{"name" => "Alice"})

      {:ok, snapshot} = Snapshots.capture(t, "one", scope)
      stored = Snapshots.get(t.id, snapshot.id)

      assert stored.payload == stored.payload |> Jason.encode!() |> Jason.decode!()
    end
  end
end
