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

  describe "logged-out visitor is carried back to /invites/:token after auth (return_to)" do
    # `/invites/:token` sits in the `:require_authenticated_tournaments`
    # live_session, whose scope is `pipe_through [:browser,
    # :require_authenticated_user]` (see router.ex) — so an unauthenticated
    # hit is caught by the *plug* (`UserAuth.require_authenticated_user/2`)
    # before the LiveView ever mounts, and that plug's
    # `maybe_store_return_to/1` stashes the current path in the session as
    # `user_return_to`. `UserAuth.log_in_user/3` reads it back out after
    # login. These tests drive that whole chain end to end (unlike
    # `user_auth_test.exs`, which only asserts the session gets the value —
    # not that a real magic-link login/registration actually lands there).
    test "an account that already exists: unauth visit -> log-in -> magic link -> back on the invite page", %{
      scope: owner_scope
    } do
      tournament = fixture(owner_scope)
      invitee = lightweight_user()
      {:ok, invite} = Tournaments.add_collaborator(owner_scope, tournament, invitee.email)

      anon_conn = Phoenix.ConnTest.build_conn()

      conn = get(anon_conn, ~p"/invites/#{invite.invite_token}")
      assert redirected_to(conn) == ~p"/users/log-in"
      assert Plug.Conn.get_session(conn, :user_return_to) == ~p"/invites/#{invite.invite_token}"

      test_pid = self()

      {:ok, _} =
        Accounts.deliver_login_instructions(invitee, fn t ->
          send(test_pid, {:magic_token, t})
          "http://example.com/users/log-in/#{t}"
        end)

      token = receive(do: ({:magic_token, t} -> t))

      conn = conn |> recycle() |> get(~p"/users/log-in/#{token}")
      {:ok, lv, _html} = live(conn)

      final_conn =
        lv
        |> form("#login_form", user: %{token: token})
        |> submit_form(conn)

      assert redirected_to(final_conn) == ~p"/invites/#{invite.invite_token}"
    end

    test "a brand-new invitee (no account yet): unauth visit -> register -> magic link -> back on the invite page", %{
      scope: owner_scope
    } do
      tournament = fixture(owner_scope)
      email = "brand-new-invitee-#{System.unique_integer([:positive])}@example.com"
      {:ok, invite} = Tournaments.add_collaborator(owner_scope, tournament, email)

      anon_conn = Phoenix.ConnTest.build_conn()

      conn = get(anon_conn, ~p"/invites/#{invite.invite_token}")
      assert redirected_to(conn) == ~p"/users/log-in"

      register_conn = conn |> recycle() |> get(~p"/users/register")
      {:ok, register_lv, _html} = live(register_conn)

      register_lv
      |> form("#registration_form", user: %{email: email})
      |> render_submit()

      user = Accounts.get_user_by_email(email)
      assert user

      test_pid = self()

      {:ok, _} =
        Accounts.deliver_login_instructions(user, fn t ->
          send(test_pid, {:magic_token, t})
          "http://example.com/users/log-in/#{t}"
        end)

      token = receive(do: ({:magic_token, t} -> t))

      confirm_conn = register_conn |> recycle() |> get(~p"/users/log-in/#{token}")
      {:ok, confirm_lv, _html} = live(confirm_conn)

      final_conn =
        confirm_lv
        |> form("#confirmation_form", user: %{token: token})
        |> submit_form(confirm_conn)

      assert redirected_to(final_conn) == ~p"/invites/#{invite.invite_token}"
    end
  end
end
