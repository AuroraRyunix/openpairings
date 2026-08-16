defmodule PairingsEngine.SnapshotBranchingTest do
  @moduledoc """
  Restore points form a tree: going back and then carrying on differently
  forks the history rather than overwriting the line you left.
  """
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{Repo, Snapshots, Tournaments}
  alias PairingsEngine.Tournaments.Player
  alias PairingsEngine.Accounts.{Scope, User}

  defp user_scope do
    user =
      Repo.insert!(%User{
        email: "branch#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    Scope.for_user(user)
  end

  defp tournament(scope) do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "Branch Test",
        "type" => "swiss",
        "rounds_count" => "3"
      })

    t
  end

  defp reload(t), do: Repo.reload!(t)

  defp lanes(t) do
    t |> Snapshots.branch_tree() |> Enum.map(&{&1.snapshot.summary, &1.lane})
  end

  describe "HEAD tracking" do
    test "a tournament starts with no HEAD" do
      t = tournament(user_scope())
      refute t.head_snapshot_id
    end

    test "capturing advances HEAD to the new snapshot" do
      scope = user_scope()
      t = tournament(scope)

      {:ok, first} = Snapshots.capture(t, "manual", scope, summary: "A")
      assert reload(t).head_snapshot_id == first.id

      {:ok, second} = Snapshots.capture(reload(t), "manual", scope, summary: "B")
      assert reload(t).head_snapshot_id == second.id
    end

    test "each capture hangs off the previous one, forming a chain" do
      scope = user_scope()
      t = tournament(scope)

      {:ok, a} = Snapshots.capture(t, "manual", scope, summary: "A")
      {:ok, b} = Snapshots.capture(reload(t), "manual", scope, summary: "B")
      {:ok, c} = Snapshots.capture(reload(t), "manual", scope, summary: "C")

      refute Repo.reload!(a).parent_id
      assert Repo.reload!(b).parent_id == a.id
      assert Repo.reload!(c).parent_id == b.id
    end

    test "restoring moves HEAD to the restored point, not to the new snapshot" do
      scope = user_scope()
      t = tournament(scope)

      {:ok, a} = Snapshots.capture(t, "manual", scope, summary: "A")
      {:ok, _b} = Snapshots.capture(reload(t), "manual", scope, summary: "B")

      {:ok, _} = Snapshots.restore(reload(t), a.id, scope)

      # The live data is at A now — even though a newer snapshot exists.
      assert reload(t).head_snapshot_id == a.id
    end
  end

  describe "forking" do
    test "carrying on after a restore forks the tree at the restored point" do
      scope = user_scope()
      t = tournament(scope)

      {:ok, a} = Snapshots.capture(t, "manual", scope, summary: "A")
      {:ok, b} = Snapshots.capture(reload(t), "manual", scope, summary: "B")

      # Go back to A, then take a new snapshot: it should hang off A, not B.
      {:ok, _} = Snapshots.restore(reload(t), a.id, scope)
      {:ok, fork} = Snapshots.capture(reload(t), "manual", scope, summary: "Fork")

      assert Repo.reload!(fork).parent_id == a.id
      assert Repo.reload!(b).parent_id == a.id

      # A now has more than one child — that's the fork.
      entry = t |> Snapshots.branch_tree() |> Enum.find(&(&1.snapshot.id == a.id))
      assert entry.children >= 2
    end

    test "the abandoned line stays intact and reachable" do
      scope = user_scope()
      t = tournament(scope)

      {:ok, a} = Snapshots.capture(t, "manual", scope, summary: "A")
      Repo.insert!(%Player{tournament_id: t.id, name: "Only On Line B"})
      {:ok, b} = Snapshots.capture(reload(t), "manual", scope, summary: "B")

      {:ok, _} = Snapshots.restore(reload(t), a.id, scope)
      {:ok, _} = Snapshots.capture(reload(t), "manual", scope, summary: "Fork")

      # B is still there, and restoring to it brings its state back.
      assert Repo.get(PairingsEngine.Snapshots.Snapshot, b.id)

      {:ok, _} = Snapshots.restore(reload(t), b.id, scope)

      assert t.id
             |> Tournaments.list_players()
             |> Enum.any?(&(&1.name == "Only On Line B"))
    end
  end

  describe "branch_tree/1 lane layout" do
    test "an unbranched history is a single straight lane" do
      scope = user_scope()
      t = tournament(scope)

      {:ok, _} = Snapshots.capture(t, "manual", scope, summary: "A")
      {:ok, _} = Snapshots.capture(reload(t), "manual", scope, summary: "B")
      {:ok, _} = Snapshots.capture(reload(t), "manual", scope, summary: "C")

      assert reload(t) |> lanes() |> Enum.map(&elem(&1, 1)) |> Enum.uniq() == [0]
    end

    test "returns newest first, matching the timeline" do
      scope = user_scope()
      t = tournament(scope)

      {:ok, _} = Snapshots.capture(t, "manual", scope, summary: "A")
      {:ok, _} = Snapshots.capture(reload(t), "manual", scope, summary: "B")

      assert reload(t) |> lanes() |> Enum.map(&elem(&1, 0)) == ["B", "A"]
    end

    test "the line the live data is on is always lane 0" do
      scope = user_scope()
      t = tournament(scope)

      {:ok, a} = Snapshots.capture(t, "manual", scope, summary: "A")
      {:ok, _b} = Snapshots.capture(reload(t), "manual", scope, summary: "B")

      {:ok, _} = Snapshots.restore(reload(t), a.id, scope)
      {:ok, _} = Snapshots.capture(reload(t), "manual", scope, summary: "Fork")

      tree = reload(t) |> Snapshots.branch_tree()

      # Whatever else happened, the current line reads as the trunk.
      for entry <- tree, entry.on_head_line do
        assert entry.lane == 0
      end

      # ...and the abandoned line is somewhere else.
      abandoned = Enum.find(tree, &(&1.snapshot.summary == "B"))
      assert abandoned.lane != 0
      refute abandoned.on_head_line
    end

    test "an abandoned chain stays ONE branch instead of a lane per snapshot" do
      # The case `first_child?/3` exists for, and the one it silently failed:
      # walking oldest-first puts the parent in `lanes` before its child is
      # examined, so a scan for "has anything taken the parent's lane?" always
      # matched the parent itself. Every child then took a fresh lane, and an
      # abandoned run of restore points was drawn as several parallel
      # one-node branches rather than the single line it is.
      scope = user_scope()
      t = tournament(scope)

      {:ok, a} = Snapshots.capture(t, "manual", scope, summary: "A")
      {:ok, _b} = Snapshots.capture(reload(t), "manual", scope, summary: "B")
      {:ok, _c} = Snapshots.capture(reload(t), "manual", scope, summary: "C")
      {:ok, _d} = Snapshots.capture(reload(t), "manual", scope, summary: "D")

      # Go back to A, stranding B -> C -> D as one abandoned line.
      {:ok, _} = Snapshots.restore(reload(t), a.id, scope)
      {:ok, _} = Snapshots.capture(reload(t), "manual", scope, summary: "Fork")

      tree = reload(t) |> Snapshots.branch_tree()
      abandoned = Enum.filter(tree, &(&1.snapshot.summary in ~w(B C D)))

      assert length(abandoned) == 3

      lanes = abandoned |> Enum.map(& &1.lane) |> Enum.uniq()

      assert length(lanes) == 1,
             "B, C and D are one chain and belong in one lane, got #{inspect(Enum.map(abandoned, &{&1.snapshot.summary, &1.lane}))}"

      refute 0 in lanes, "lane 0 is reserved for the line the live data is on"
    end

    test "marks which entry is HEAD" do
      scope = user_scope()
      t = tournament(scope)

      {:ok, a} = Snapshots.capture(t, "manual", scope, summary: "A")
      {:ok, _} = Snapshots.capture(reload(t), "manual", scope, summary: "B")
      {:ok, _} = Snapshots.restore(reload(t), a.id, scope)

      tree = reload(t) |> Snapshots.branch_tree()
      heads = Enum.filter(tree, & &1.is_head)

      assert [head] = heads
      assert head.snapshot.id == a.id
    end

    test "carries the parent's lane so the view can draw the connector" do
      scope = user_scope()
      t = tournament(scope)

      {:ok, _a} = Snapshots.capture(t, "manual", scope, summary: "A")
      {:ok, _b} = Snapshots.capture(reload(t), "manual", scope, summary: "B")

      tree = reload(t) |> Snapshots.branch_tree()

      root = Enum.find(tree, &(&1.snapshot.summary == "A"))
      child = Enum.find(tree, &(&1.snapshot.summary == "B"))

      refute root.parent_lane
      assert child.parent_lane == root.lane
    end

    test "an empty history is an empty tree" do
      assert tournament(user_scope()) |> Snapshots.branch_tree() == []
    end

    test "pre-existing snapshots with no parent still render (as roots)" do
      scope = user_scope()
      t = tournament(scope)

      # Simulates rows written before branching existed: no parent, no HEAD.
      {:ok, _legacy} = Snapshots.capture(t, "manual", scope, summary: "Legacy")

      Repo.update_all(
        from(s in PairingsEngine.Snapshots.Snapshot, where: s.tournament_id == ^t.id),
        set: [parent_id: nil]
      )

      Repo.update_all(
        from(x in PairingsEngine.Tournaments.Tournament, where: x.id == ^t.id),
        set: [head_snapshot_id: nil]
      )

      assert [entry] = reload(t) |> Snapshots.branch_tree()
      assert entry.snapshot.summary == "Legacy"
      refute entry.on_head_line
    end
  end

  describe "round-tripping between two lines" do
    test "you can move back and forth and the data follows" do
      scope = user_scope()
      t = tournament(scope)

      Repo.insert!(%Player{tournament_id: t.id, name: "Common"})
      {:ok, base} = Snapshots.capture(t, "manual", scope, summary: "Base")

      # Line 1
      Repo.insert!(%Player{tournament_id: t.id, name: "Line One"})
      {:ok, line_one} = Snapshots.capture(reload(t), "manual", scope, summary: "Line one")

      # Back to base, then a different line
      {:ok, _} = Snapshots.restore(reload(t), base.id, scope)
      Repo.insert!(%Player{tournament_id: t.id, name: "Line Two"})
      {:ok, line_two} = Snapshots.capture(reload(t), "manual", scope, summary: "Line two")

      # Jump to line one: its player is present, line two's is not.
      {:ok, _} = Snapshots.restore(reload(t), line_one.id, scope)
      names = t.id |> Tournaments.list_players() |> Enum.map(& &1.name)
      assert "Line One" in names
      refute "Line Two" in names

      # ...and back again.
      {:ok, _} = Snapshots.restore(reload(t), line_two.id, scope)
      names = t.id |> Tournaments.list_players() |> Enum.map(& &1.name)
      assert "Line Two" in names
      refute "Line One" in names
    end
  end
end
