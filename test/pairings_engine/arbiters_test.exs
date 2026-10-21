defmodule PairingsEngine.ArbitersTest do
  @moduledoc """
  The arbiter role (docs/manubrium.md): an account a tournament shares its
  hall with and nothing else - results and incidents from a phone, under
  its own name, with the desk pages shut.
  """
  use PairingsEngine.DataCase, async: true

  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.{Audit, Mobile, Repo, Tournaments}
  alias PairingsEngine.Mobile.Enrollment
  alias PairingsEngine.Tournaments.{Collaborator, Pairing, Round}

  setup do
    owner = user_scope_fixture()
    {:ok, t} = Tournaments.create_tournament(owner, %{"name" => "Hall Open", "type" => "swiss"})
    %{owner: owner, tournament: t}
  end

  # Invites `role` and has the invitee accept, as the emailed link would.
  defp enlist(owner, t, role) do
    scope = user_scope_fixture()
    {:ok, c} = Tournaments.add_collaborator(owner, t, scope.user.email, role)
    {:ok, _} = Tournaments.accept_invitation(scope, c.invite_token)
    {scope, Repo.get!(Collaborator, c.id)}
  end

  defp board(t) do
    round = Repo.insert!(%Round{tournament_id: t.id, number: 1, status: "paired"})
    {:ok, w} = Tournaments.create_player(t.id, %{"name" => "White"})
    {:ok, b} = Tournaments.create_player(t.id, %{"name" => "Black"})

    Repo.insert!(%Pairing{
      round_id: round.id,
      board: 1,
      white_player_id: w.id,
      black_player_id: b.id,
      result: ""
    })
    |> Repo.preload([:white_player, :black_player])
  end

  describe "the role" do
    test "only editor and arbiter exist", %{owner: owner, tournament: t} do
      assert Tournaments.add_collaborator(owner, t, "x@example.com", "admin") ==
               {:error, :bad_role}

      assert {:ok, %{role: "arbiter"}} =
               Tournaments.add_collaborator(owner, t, "y@example.com", "arbiter")

      assert {:ok, %{role: "editor"}} = Tournaments.add_collaborator(owner, t, "z@example.com")
    end

    test "an arbiter never gets the desk pages", %{owner: owner, tournament: t} do
      {arbiter, _c} = enlist(owner, t, "arbiter")
      {editor, _c} = enlist(owner, t, "editor")

      assert Tournaments.get_authorized_tournament(arbiter, t.id) == nil
      assert Tournaments.get_authorized_tournament(editor, t.id).id == t.id
      assert Tournaments.get_authorized_tournament(owner, t.id).id == t.id
    end

    test "hall_role says who may work in the hall", %{owner: owner, tournament: t} do
      {arbiter, _} = enlist(owner, t, "arbiter")
      {editor, _} = enlist(owner, t, "editor")
      stranger = user_scope_fixture()
      {:ok, _pending} = Tournaments.add_collaborator(owner, t, "later@example.com", "arbiter")

      assert Tournaments.hall_role(owner.user, t.id) == :owner
      assert Tournaments.hall_role(editor.user, t.id) == :editor
      assert Tournaments.hall_role(arbiter.user, t.id) == :arbiter
      assert Tournaments.hall_role(stranger.user, t.id) == nil
      assert Tournaments.hall_role(nil, t.id) == nil

      assert [{%{id: id}, :arbiter}] = Tournaments.hall_tournaments(arbiter)
      assert id == t.id
      assert [{_, :owner}] = Tournaments.hall_tournaments(owner)
      assert Tournaments.hall_tournaments(stranger) == []
    end
  end

  describe "an arbiter's own phone code" do
    test "is a deputy, under the account, and only for someone the tournament knows", %{
      owner: owner,
      tournament: t
    } do
      {arbiter, _} = enlist(owner, t, "arbiter")
      stranger = user_scope_fixture()

      {:ok, e} = Mobile.create_enrollment(t.id, user_id: arbiter.user.id, level: "helper")
      assert e.level == "deputy"
      assert e.user_id == arbiter.user.id

      assert Mobile.create_enrollment(t.id, user_id: stranger.user.id) ==
               {:error, :not_authorized}
    end

    test "writes results under the account", %{owner: owner, tournament: t} do
      {arbiter, _} = enlist(owner, t, "arbiter")
      pairing = board(t)
      {:ok, e} = Mobile.create_enrollment(t.id, user_id: arbiter.user.id)

      {:ok, _} = Tournaments.update_pairing_result(pairing, "1-0")
      Mobile.log_result(e, pairing, 1, "", "1-0")

      [row] =
        Audit.list_for_tournament(t.id) |> Enum.filter(&(&1.action == "pairing.result_entered"))

      assert row.user_id == arbiter.user.id
    end

    test "stops working when the arbiter is taken off the tournament", %{
      owner: owner,
      tournament: t
    } do
      {arbiter, c} = enlist(owner, t, "arbiter")
      {:ok, e} = Mobile.create_enrollment(t.id, user_id: arbiter.user.id)
      assert Mobile.get_active(e.id)

      {:ok, _} = Tournaments.remove_collaborator(owner, t, c.id)

      assert Mobile.get_active(e.id) == nil
      assert %DateTime{} = Repo.get!(Enrollment, e.id).revoked_at
    end

    test "leaving the tournament takes the phone with it", %{owner: owner, tournament: t} do
      {arbiter, _c} = enlist(owner, t, "arbiter")
      {:ok, e} = Mobile.create_enrollment(t.id, user_id: arbiter.user.id)

      {:ok, _} = Tournaments.leave_tournament(arbiter, t)
      assert Mobile.get_active(e.id) == nil
    end

    test "a no-account code is untouched by any of it", %{owner: owner, tournament: t} do
      {_arbiter, c} = enlist(owner, t, "arbiter")
      {:ok, helper} = Mobile.create_enrollment(t.id, level: "helper")

      {:ok, _} = Tournaments.remove_collaborator(owner, t, c.id)
      assert Mobile.get_active(helper.id)
    end
  end

  describe "board assignment" do
    test "the desk gives an arbiter boards; the arbiter cannot give themselves any", %{
      owner: owner,
      tournament: t
    } do
      {arbiter, c} = enlist(owner, t, "arbiter")
      {editor, editor_c} = enlist(owner, t, "editor")

      assert {:ok, %{board_from: 11, board_to: 20}} =
               Tournaments.assign_boards(owner, t, c.id, {11, 20})

      assert Tournaments.assigned_boards(arbiter.user.id, t.id) == {11, 20}

      assert {:ok, _} = Tournaments.assign_boards(editor, t, c.id, {1, 5})
      assert Tournaments.assign_boards(arbiter, t, c.id, {1, 99}) == {:error, :not_authorized}
      assert Tournaments.assign_boards(owner, t, c.id, {9, 3}) == {:error, :invalid_range}
      assert Tournaments.assign_boards(owner, t, editor_c.id, {1, 2}) == {:error, :not_found}

      assert {:ok, _} = Tournaments.assign_boards(owner, t, c.id, {nil, nil})
      assert Tournaments.assigned_boards(arbiter.user.id, t.id) == nil

      assert Enum.any?(
               Audit.list_for_tournament(t.id),
               &(&1.action == "collaborator.boards_assigned")
             )
    end
  end
end
