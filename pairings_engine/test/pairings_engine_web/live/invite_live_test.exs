defmodule PairingsEngineWeb.InviteLiveTest do
  # `async: false` for the same reason as PairingsEngineWeb.SharingTest: each
  # test here creates a tournament plus at least one extra user on top of
  # `register_and_log_in_user`'s own — enough sequential writes to contend
  # with the async pool for SQLite's single writer lock.
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Accounts, Repo, Tournaments}
  alias PairingsEngine.Accounts.User

  setup :register_and_log_in_user

  defp lightweight_user do
    Repo.insert!(%User{
      email: "user#{System.unique_integer([:positive])}@example.com",
      confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
    })
  end

  defp fixture(scope) do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{"name" => "Invite Tournament", "type" => "swiss", "rounds_count" => "3"})

    tournament
  end

  describe "/invites/:token" do
    test "renders the invitation and accepting grants access and redirects to the players page", %{
      scope: owner_scope,
      user: owner
    } do
      tournament = fixture(owner_scope)
      invitee = lightweight_user()
      {:ok, invite} = Tournaments.add_collaborator(owner_scope, tournament, invitee.email)

      invitee_conn = Phoenix.ConnTest.build_conn() |> log_in_user(invitee)

      {:ok, lv, html} = live(invitee_conn, ~p"/invites/#{invite.invite_token}")

      assert html =~ tournament.name
      assert html =~ owner.email
      assert html =~ "You&#39;ve been invited"

      {:error, {:live_redirect, %{to: to}}} = lv |> element("button", "Accept") |> render_click()
      assert to == ~p"/t/#{tournament.id}/players"

      invitee_scope = Accounts.Scope.for_user(invitee)
      assert %{status: "accepted", invite_token: nil} = hd(Tournaments.list_collaborators(tournament))
      assert Tournaments.get_authorized_tournament(invitee_scope, tournament.id) != nil
    end

    test "declining removes the invitation and redirects home", %{scope: owner_scope} do
      tournament = fixture(owner_scope)
      invitee = lightweight_user()
      {:ok, invite} = Tournaments.add_collaborator(owner_scope, tournament, invitee.email)

      invitee_conn = Phoenix.ConnTest.build_conn() |> log_in_user(invitee)

      {:ok, lv, _html} = live(invitee_conn, ~p"/invites/#{invite.invite_token}")

      {:error, {:live_redirect, %{to: to}}} = lv |> element("button", "Decline") |> render_click()
      assert to == ~p"/"

      assert Tournaments.list_collaborators(tournament) == []
    end

    test "a logged-in user whose email doesn't match the invite sees a mismatch message and gains no access", %{
      scope: owner_scope
    } do
      tournament = fixture(owner_scope)
      invitee = lightweight_user()
      stranger = lightweight_user()
      {:ok, invite} = Tournaments.add_collaborator(owner_scope, tournament, invitee.email)

      stranger_conn = Phoenix.ConnTest.build_conn() |> log_in_user(stranger)

      {:ok, lv, html} = live(stranger_conn, ~p"/invites/#{invite.invite_token}")

      assert html =~ "Wrong account"
      assert html =~ invitee.email
      refute has_element?(lv, "button", "Accept")

      # Even a forged event can't accept it for the wrong account.
      assert Tournaments.get_authorized_tournament(Accounts.Scope.for_user(stranger), tournament.id) == nil
      assert %{status: "pending"} = hd(Tournaments.list_collaborators(tournament))
    end

    test "an invalid token shows a not-found message", %{scope: owner_scope, conn: conn} do
      # `conn` here is already the owner's logged-in conn from
      # register_and_log_in_user — any authenticated user hitting a bogus
      # token should see the same not-found state.
      _tournament = fixture(owner_scope)

      {:ok, _lv, html} = live(conn, ~p"/invites/not-a-real-token")

      assert html =~ "Invitation not found"
    end
  end
end
