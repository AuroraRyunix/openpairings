defmodule PairingsEngine.TournamentGroupsTest do
  # async: false, like the other files here that write several users and
  # tournaments: SQLite has one writer.
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{Audit, Repo, TournamentExport, TournamentGroups, TournamentImport}
  alias PairingsEngine.Accounts.{Scope, User}
  alias PairingsEngine.Tournaments
  alias PairingsEngine.TournamentGroups.{Group, Member}

  defp user_scope do
    user =
      Repo.insert!(%User{
        email: "user#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    Scope.for_user(user)
  end

  defp tournament(scope, name) do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => name,
        "type" => "swiss",
        "rounds_count" => "5"
      })

    t
  end

  defp share(owner_scope, tournament, other_scope) do
    {:ok, invite} = Tournaments.add_collaborator(owner_scope, tournament, other_scope.user.email)
    {:ok, _} = Tournaments.accept_invitation(other_scope, invite.invite_token)
    :ok
  end

  defp labels(scope, tournament),
    do: TournamentGroups.switcher(scope, tournament).members |> Enum.map(& &1.label)

  setup do
    scope = user_scope()
    open = tournament(scope, "Spring Open")
    u20 = tournament(scope, "Spring U20")
    {:ok, group} = TournamentGroups.create_group(scope, open, "Spring Festival")
    %{scope: scope, open: open, u20: u20, group: group}
  end

  describe "create, join, leave" do
    test "a group starts with the tournament it was made from", %{scope: scope, open: open} do
      assert %{group: %Group{name: "Spring Festival"}, members: [m]} =
               TournamentGroups.switcher(scope, open)

      assert m.id == open.id and m.current? and m.label == "Spring Open"
    end

    test "joining adds at the end; a tournament is in one group at most", ctx do
      %{scope: scope, open: open, u20: u20, group: group} = ctx

      assert {:ok, _} = TournamentGroups.join_group(scope, u20, group.id)
      assert labels(scope, open) == ["Spring Open", "Spring U20"]

      assert {:error, :already_grouped} = TournamentGroups.join_group(scope, u20, group.id)
      assert {:error, :already_grouped} = TournamentGroups.create_group(scope, u20, "Another")
    end

    test "the last member out takes the group with it", ctx do
      %{scope: scope, open: open, u20: u20, group: group} = ctx
      {:ok, _} = TournamentGroups.join_group(scope, u20, group.id)

      assert {:ok, _} = TournamentGroups.leave_group(scope, open)
      assert TournamentGroups.switcher(scope, open) == nil
      assert Repo.get(Group, group.id)

      assert {:ok, _} = TournamentGroups.leave_group(scope, u20)
      refute Repo.get(Group, group.id)
      assert {:error, :not_grouped} = TournamentGroups.leave_group(scope, u20)
    end

    test "a blank name is refused", %{scope: scope, u20: u20} do
      assert {:error, %Ecto.Changeset{}} = TournamentGroups.create_group(scope, u20, "   ")
      assert TournamentGroups.membership(u20.id) == nil
    end

    test "each change leaves an audit row on the tournament acted on", ctx do
      %{scope: scope, open: open, u20: u20, group: group} = ctx
      {:ok, _} = TournamentGroups.join_group(scope, u20, group.id)
      {:ok, _} = TournamentGroups.rename_group(scope, u20, "Spring Festival 2026")
      {:ok, _} = TournamentGroups.set_label(scope, u20, "U20")
      {:ok, _} = TournamentGroups.move(scope, u20, u20.id, :up)
      {:ok, _} = TournamentGroups.leave_group(scope, u20)

      actions = fn t -> t.id |> Audit.list_for_tournament([]) |> Enum.map(& &1.action) end

      assert "group.created" in actions.(open)

      for action <- ~w(group.joined group.renamed group.label_set group.reordered group.left) do
        assert action in actions.(u20), "#{action} missing"
      end
    end
  end

  describe "label, rename and order" do
    setup %{scope: scope, u20: u20, group: group} do
      {:ok, _} = TournamentGroups.join_group(scope, u20, group.id)
      :ok
    end

    test "a label replaces the name in the switcher, and blank clears it", ctx do
      %{scope: scope, open: open, u20: u20} = ctx
      {:ok, _} = TournamentGroups.set_label(scope, u20, "  U20 ")
      assert labels(scope, open) == ["Spring Open", "U20"]

      {:ok, _} = TournamentGroups.set_label(scope, u20, "")
      assert labels(scope, open) == ["Spring Open", "Spring U20"]
    end

    test "a label longer than the switcher can hold is refused", %{scope: scope, u20: u20} do
      long = String.duplicate("x", Member.max_label() + 1)
      assert {:error, %Ecto.Changeset{}} = TournamentGroups.set_label(scope, u20, long)
    end

    test "rename changes the group for every member", %{scope: scope, open: open, u20: u20} do
      {:ok, _} = TournamentGroups.rename_group(scope, u20, "Autumn Festival")
      assert TournamentGroups.switcher(scope, open).group.name == "Autumn Festival"
    end

    test "moving up and down reorders; the ends are a no-op", ctx do
      %{scope: scope, open: open, u20: u20} = ctx
      {:ok, _} = TournamentGroups.move(scope, open, u20.id, :up)
      assert labels(scope, open) == ["Spring U20", "Spring Open"]

      {:ok, _} = TournamentGroups.move(scope, open, u20.id, :up)
      assert labels(scope, open) == ["Spring U20", "Spring Open"]

      {:ok, _} = TournamentGroups.move(scope, open, u20.id, :down)
      assert labels(scope, open) == ["Spring Open", "Spring U20"]
    end
  end

  describe "who may do what, and who sees what" do
    test "a stranger can neither join nor see the group", ctx do
      %{open: open, group: group} = ctx
      stranger = user_scope()
      theirs = tournament(stranger, "Their Open")

      assert {:error, :not_found} = TournamentGroups.join_group(stranger, theirs, group.id)
      assert TournamentGroups.joinable_groups(stranger, theirs) == []
      assert {:error, :not_authorized} = TournamentGroups.leave_group(stranger, open)
      assert {:error, :not_authorized} = TournamentGroups.rename_group(stranger, open, "Mine")
      assert {:error, :not_authorized} = TournamentGroups.create_group(stranger, open, "Mine")
    end

    test "a collaborator sees only the siblings shared with them", ctx do
      %{scope: scope, u20: u20, group: group} = ctx
      {:ok, _} = TournamentGroups.join_group(scope, u20, group.id)
      helper = user_scope()
      share(scope, u20, helper)

      # The Open is not theirs: no entry, no count, nothing to infer from.
      assert %{members: [only]} = TournamentGroups.switcher(helper, u20)
      assert only.id == u20.id

      # And they can still manage the tournament they were given.
      assert {:ok, _} = TournamentGroups.set_label(helper, u20, "U20")
      assert {:ok, _} = TournamentGroups.leave_group(helper, u20)
    end

    test "a collaborator may add their own tournament to a group they can edit", ctx do
      %{scope: scope, open: open, group: group} = ctx
      helper = user_scope()
      share(scope, open, helper)
      rapid = tournament(helper, "Spring Rapid")

      assert [%{group: %Group{id: id}, labels: ["Spring Open"]}] =
               TournamentGroups.joinable_groups(helper, rapid)

      assert id == group.id
      assert {:ok, _} = TournamentGroups.join_group(helper, rapid, group.id)

      # The owner cannot open the helper's rapid, so it is not in their switcher.
      assert labels(scope, open) == ["Spring Open"]
      assert labels(helper, open) == ["Spring Open", "Spring Rapid"]
    end

    test "an archived tournament is read-only here too", %{scope: scope, open: open} do
      {:ok, archived} = Tournaments.archive_tournament(open)
      assert {:error, :archived} = TournamentGroups.leave_group(scope, archived)
    end

    test "a binned tournament drops out of the switcher and is back on restore", ctx do
      %{scope: scope, open: open, u20: u20, group: group} = ctx
      {:ok, _} = TournamentGroups.join_group(scope, u20, group.id)

      {:ok, binned} = Tournaments.soft_delete_tournament(u20)
      assert labels(scope, open) == ["Spring Open"]

      {:ok, _} = Tournaments.restore_tournament(binned)
      assert labels(scope, open) == ["Spring Open", "Spring U20"]
    end

    test "deleting a tournament for good takes it out, and an emptied group with it", ctx do
      %{scope: scope, open: open, u20: u20, group: group} = ctx
      {:ok, _} = TournamentGroups.join_group(scope, u20, group.id)

      {:ok, _} = Tournaments.delete_tournament(u20)
      assert labels(scope, open) == ["Spring Open"]

      {:ok, _} = Tournaments.delete_tournament(open)
      refute Repo.get(Group, group.id)
    end
  end

  describe "export and import" do
    test "the export names the group as information; the import does not join it", ctx do
      %{scope: scope, u20: u20, group: group} = ctx
      {:ok, _} = TournamentGroups.join_group(scope, u20, group.id)
      {:ok, _} = TournamentGroups.set_label(scope, u20, "U20")

      envelope = TournamentExport.export_tournament(u20)
      [entry] = envelope["tournaments"]

      assert entry["group"] == %{"name" => "Spring Festival", "label" => "U20", "position" => 1}

      {:ok, [copy]} =
        envelope |> Jason.encode!() |> Jason.decode!() |> TournamentImport.import(scope)

      assert TournamentGroups.membership(copy.id) == nil
      assert labels(scope, u20) == ["Spring Open", "U20"]
    end

    test "an ungrouped tournament's export has no group block", %{u20: u20} do
      [entry] = TournamentExport.export_tournament(u20)["tournaments"]
      refute Map.has_key?(entry, "group")
    end
  end
end
