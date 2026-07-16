defmodule PairingsEngine.AuditTest do
  use PairingsEngine.DataCase, async: true

  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.{Audit, Repo}
  alias PairingsEngine.Tournaments.Tournament

  defp tournament, do: Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 5})

  test "log/4 inserts a row with the given action and details" do
    t = tournament()
    user = user_fixture()

    assert {:ok, row} =
             Audit.log(t.id, user.id, "player.created", %{player_id: 7, player_name: "Alice"})

    assert row.tournament_id == t.id
    assert row.user_id == user.id
    assert row.action == "player.created"
    assert row.inserted_at

    # Read back through the query path (JSON column → string keys), which is
    # how the audit page actually consumes details.
    [reloaded] = Audit.list_for_tournament(t.id)
    assert reloaded.details["player_name"] == "Alice"
  end

  test "log/4 accepts a Scope, pulling out the user id" do
    t = tournament()
    scope = user_scope_fixture()

    assert {:ok, row} = Audit.log(t.id, scope, "tournament.created", %{name: "X"})
    assert row.user_id == scope.user.id
  end

  test "log/4 accepts a nil user (system write)" do
    t = tournament()
    assert {:ok, row} = Audit.log(t.id, nil, "import.swar", %{name: "X"})
    assert row.user_id == nil
  end

  test "log/4 normalizes tuple values (before/after pairs) into JSON-friendly lists" do
    t = tournament()

    assert {:ok, row} =
             Audit.log(t.id, nil, "player.updated", %{
               changed_fields: %{"rating" => {1800, 1850}}
             })

    reloaded = Repo.get!(PairingsEngine.Audit.AuditLog, row.id)
    assert reloaded.details["changed_fields"]["rating"] == [1800, 1850]
  end

  test "list_for_tournament/2 returns rows newest-first, scoped to the tournament" do
    t = tournament()
    other = tournament()

    {:ok, _} = Audit.log(t.id, nil, "player.created", %{n: 1})
    {:ok, _} = Audit.log(t.id, nil, "player.created", %{n: 2})
    {:ok, _} = Audit.log(other.id, nil, "player.created", %{n: 99})

    rows = Audit.list_for_tournament(t.id)
    assert length(rows) == 2
    assert Enum.map(rows, & &1.details["n"]) == [2, 1]
  end

  test "list_for_tournament/2 filters by :action and by :actions list" do
    t = tournament()
    {:ok, _} = Audit.log(t.id, nil, "player.created", %{})
    {:ok, _} = Audit.log(t.id, nil, "pairing.round_paired", %{})
    {:ok, _} = Audit.log(t.id, nil, "pairing.result_entered", %{})

    assert [%{action: "player.created"}] =
             Audit.list_for_tournament(t.id, action: "player.created")

    pairing_rows =
      Audit.list_for_tournament(t.id, actions: ~w(pairing.round_paired pairing.result_entered))

    assert length(pairing_rows) == 2
    assert Enum.all?(pairing_rows, &String.starts_with?(&1.action, "pairing."))
  end

  test "list_for_tournament/2 honours :limit and :offset" do
    t = tournament()
    for n <- 1..5, do: Audit.log(t.id, nil, "player.created", %{n: n})

    page1 = Audit.list_for_tournament(t.id, limit: 2, offset: 0)
    page2 = Audit.list_for_tournament(t.id, limit: 2, offset: 2)

    assert length(page1) == 2
    assert length(page2) == 2
    # Disjoint pages.
    assert MapSet.disjoint?(
             MapSet.new(page1, & &1.id),
             MapSet.new(page2, & &1.id)
           )
  end

  test "count_for_tournament/2 counts, optionally filtered by :actions" do
    t = tournament()
    {:ok, _} = Audit.log(t.id, nil, "player.created", %{})
    {:ok, _} = Audit.log(t.id, nil, "pairing.round_paired", %{})

    assert Audit.count_for_tournament(t.id) == 2
    assert Audit.count_for_tournament(t.id, actions: ~w(player.created)) == 1
  end

  test "deleting a tournament cascade-deletes its audit rows" do
    t = tournament()
    {:ok, _} = Audit.log(t.id, nil, "player.created", %{})

    Repo.delete!(t)
    assert Audit.list_for_tournament(t.id) == []
  end
end
