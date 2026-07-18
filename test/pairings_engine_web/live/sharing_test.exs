defmodule PairingsEngineWeb.SharingTest do
  # `async: false` for the same reason as PairingsEngine.TournamentImportTest
  # and PairingsEngine.Fide.SyncTest (see their own comments): this file's
  # tests each add a tournament + player/round/pairing fixture plus at least
  # one extra user on top of `register_and_log_in_user`'s own — enough
  # sequential writes to contend with the async pool for SQLite's single
  # writer lock. Every collaborator/stranger here is created with the same
  # lightweight direct-insert helper PairingsEngine.TournamentsTest uses
  # (see its `user_scope/0` comment) rather than the full
  # register/confirm/magic-link fixture, to keep that write burden down —
  # except the one test that specifically needs the real login flow (see
  # "invite-by-email for a not-yet-registered person" below).
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{AccountsFixtures, Accounts, Repo, Tournaments}
  alias PairingsEngine.Accounts.User
  alias PairingsEngine.Tournaments.{Player, Round, Pairing}

  setup :register_and_log_in_user

  defp fixture(scope) do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{
        "name" => "Shared Tournament",
        "type" => "swiss",
        "rounds_count" => "3"
      })

    white = Repo.insert!(%Player{tournament_id: tournament.id, name: "White"})
    black = Repo.insert!(%Player{tournament_id: tournament.id, name: "Black"})
    round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "playing"})

    pairing =
      Repo.insert!(%Pairing{
        round_id: round.id,
        board: 1,
        white_player_id: white.id,
        black_player_id: black.id,
        result: ""
      })

    %{tournament: tournament, pairing: pairing}
  end

  defp lightweight_user do
    Repo.insert!(%User{
      email: "user#{System.unique_integer([:positive])}@example.com",
      confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
    })
  end

  # Adds a fresh, already-registered user as a collaborator on `tournament`,
  # accepts the invitation on their behalf via the context (equivalent to
  # them clicking Accept on the /invites/:token page — that exact page gets
  # its own end-to-end test below), and logs them in via ConnCase's
  # session-shortcut `log_in_user/2` (like every other test in the suite)
  # rather than the real magic-link POST, since these tests only care about
  # *access after acceptance*, not about the login-time
  # `link_pending_collaborators/1` backfill — that gets its own real-flow
  # test below, under "invite-by-email for a not-yet-registered person".
  defp collaborator_conn(tournament, scope) do
    other_user = lightweight_user()
    other_scope = Accounts.Scope.for_user(other_user)
    {:ok, invite} = Tournaments.add_collaborator(scope, tournament, other_user.email)
    {:ok, _accepted} = Tournaments.accept_invitation(other_scope, invite.invite_token)

    conn = Phoenix.ConnTest.build_conn() |> log_in_user(other_user)
    %{conn: conn, scope: other_scope, user: other_user}
  end

  @shared_pages ~w(players pairings standings settings live norms print)

  describe "a collaborator can access everything a shared tournament offers, except managing collaborators and deleting" do
    test "every tournament-scoped LiveView page loads for a collaborator", %{scope: scope} do
      %{tournament: tournament} = fixture(scope)
      %{conn: collaborator_conn} = collaborator_conn(tournament, scope)

      for page <- @shared_pages do
        {:ok, _lv, html} = live(collaborator_conn, "/t/#{tournament.id}/#{page}")
        assert html =~ tournament.name
      end
    end

    test "a collaborator can enter a pairing result", %{scope: scope} do
      %{tournament: tournament, pairing: pairing} = fixture(scope)
      %{conn: collaborator_conn} = collaborator_conn(tournament, scope)

      {:ok, lv, _html} = live(collaborator_conn, ~p"/t/#{tournament.id}/pairings")

      lv
      |> form("#result-form-#{pairing.id}", %{"pairing-id" => pairing.id, "result" => "1-0"})
      |> render_change()

      # update_pairing_result/2 broadcasts on the tournament topic and this
      # `lv` is subscribed to its own tournament (see PairingsLive's mount) —
      # render_change/1 only waits for the *direct* reply to the "result"
      # event, not for that self-broadcast's handle_info reload, which lands
      # in the mailbox microseconds later and runs a second, independent
      # Repo query. Without draining it here, the test ends (and the test
      # process supervisor kills `lv`, via ExUnit.fetch_test_supervisor/0)
      # while that query may still be in flight, which can abort it mid-way
      # on the shared sandbox connection (this file's tests share one
      # connection — see the moduledoc comment) and briefly wedge SQLite's
      # single writer lock for later tests. render/1 is a synchronous call
      # into `lv`, so — since Erlang delivers messages in mailbox order — it
      # can't return until that already-queued self-broadcast reload has
      # been handled first.
      render(lv)

      assert Tournaments.get_round(tournament.id, 1).pairings
             |> Enum.find(&(&1.id == pairing.id))
             |> Map.get(:result) == "1-0"
    end

    test "the Share/Team card on Settings is owner-only — a collaborator doesn't see it", %{
      scope: scope
    } do
      %{tournament: tournament} = fixture(scope)
      %{conn: collaborator_conn} = collaborator_conn(tournament, scope)

      {:ok, _lv, html} = live(collaborator_conn, ~p"/t/#{tournament.id}/settings")

      refute html =~ "Share / Team"
      refute html =~ "add-collaborator-form"
    end

    test "a collaborator cannot manage collaborators even by forging the event", %{scope: scope} do
      %{tournament: tournament} = fixture(scope)
      %{user: collaborator_user} = collaborator_conn(tournament, scope)
      collaborator_scope = Accounts.Scope.for_user(collaborator_user)

      assert {:error, :not_owner} =
               Tournaments.add_collaborator(
                 collaborator_scope,
                 tournament,
                 "someone-else@example.com"
               )
    end

    test "a collaborator cannot delete the tournament — get_user_tournament!/2 stays owner-only",
         %{scope: scope} do
      %{tournament: tournament} = fixture(scope)
      %{user: collaborator_user} = collaborator_conn(tournament, scope)
      collaborator_scope = Accounts.Scope.for_user(collaborator_user)

      assert_raise Ecto.NoResultsError, fn ->
        Tournaments.get_user_tournament!(collaborator_scope, tournament.id)
      end
    end

    test "a non-collaborator gets a 404 on every tournament-scoped page", %{scope: scope} do
      %{tournament: tournament} = fixture(scope)

      stranger = lightweight_user()
      stranger_conn = Phoenix.ConnTest.build_conn() |> log_in_user(stranger)

      for page <- @shared_pages do
        assert_raise Ecto.NoResultsError, fn ->
          live(stranger_conn, "/t/#{tournament.id}/#{page}")
        end
      end
    end

    test "a pending (not-yet-accepted) invite grants no access at all — every page 404s", %{
      scope: scope
    } do
      %{tournament: tournament} = fixture(scope)

      invited_user = lightweight_user()
      {:ok, _invite} = Tournaments.add_collaborator(scope, tournament, invited_user.email)
      invited_conn = Phoenix.ConnTest.build_conn() |> log_in_user(invited_user)

      for page <- @shared_pages do
        assert_raise Ecto.NoResultsError, fn ->
          live(invited_conn, "/t/#{tournament.id}/#{page}")
        end
      end

      refute Enum.any?(
               Tournaments.list_tournaments(Accounts.Scope.for_user(invited_user)),
               fn {t, _count, _owner?} -> t.id == tournament.id end
             )
    end
  end

  describe "invite-by-email for a not-yet-registered person" do
    test "creates a pending row that's still pending after that person's first (real) login (no access until accepted), and accepting via the context then grants it",
         %{scope: scope} do
      %{tournament: tournament} = fixture(scope)
      invite_email = "brand-new-collaborator-#{System.unique_integer([:positive])}@example.com"

      assert {:ok, pending} = Tournaments.add_collaborator(scope, tournament, invite_email)
      assert pending.user_id == nil
      assert pending.status == "pending"

      # The invited person has no account yet. They register and log in for
      # the first time via the *real* magic-link controller flow — POSTing
      # to /users/log-in like the browser would — so this exercises
      # PairingsEngineWeb.UserAuth.log_in_user/3's call to
      # Tournaments.link_pending_collaborators/1 for real, rather than
      # bypassing it via ConnCase's session-only `log_in_user/2` test
      # shortcut (used everywhere else in this file, since those tests only
      # care about access, not about this backfill step).
      {:ok, new_user} = Accounts.register_user(%{email: invite_email})
      {encoded_token, _raw} = AccountsFixtures.generate_user_magic_link_token(new_user)

      new_conn =
        Phoenix.ConnTest.build_conn()
        |> post(~p"/users/log-in", %{"user" => %{"token" => encoded_token}})

      assert redirected_to(new_conn) == ~p"/"

      new_scope = Accounts.Scope.for_user(Accounts.get_user!(new_user.id))

      # Logging in only backfilled user_id (see link_pending_collaborators/1)
      # — the invite is still pending, so the tournament does NOT show up
      # yet and the page still 404s.
      refute {tournament.id, false} in Enum.map(
               Tournaments.list_tournaments(new_scope),
               fn {t, _count, owner?} -> {t.id, owner?} end
             )

      assert_raise Ecto.NoResultsError, fn -> live(new_conn, ~p"/t/#{tournament.id}/players") end

      # Now they explicitly accept — via the /invites/:token page in real
      # usage (see invite_live_test.exs), via the context here.
      [collaborator] = Tournaments.list_collaborators(tournament)

      assert {:ok, _accepted} =
               Tournaments.accept_invitation(new_scope, collaborator.invite_token)

      assert {tournament.id, false} in Enum.map(
               Tournaments.list_tournaments(new_scope),
               fn {t, _count, owner?} -> {t.id, owner?} end
             )

      # Phoenix.ConnTest automatically recycles the session cookie between
      # chained requests on the same conn, so this ~is~ the now-logged-in
      # browser session opening the tournament that was just shared with it.
      {:ok, _lv, html} = live(new_conn, ~p"/t/#{tournament.id}/players")
      assert html =~ tournament.name
    end
  end

  describe "Tournaments list shows a shared badge and hides Delete for shared tournaments" do
    test "the tournaments list marks a shared tournament and doesn't offer Delete for it", %{
      scope: scope
    } do
      %{tournament: tournament} = fixture(scope)
      %{conn: collaborator_conn} = collaborator_conn(tournament, scope)

      {:ok, _lv, html} = live(collaborator_conn, ~p"/")

      assert html =~ "shared"
      refute html =~ ~s(phx-click="delete_start" phx-value-id="#{tournament.id}")
    end
  end

  describe "the Settings Share/Team card shows invited vs active status" do
    test "a pending invite shows 'invited (waiting for accept)' and an accepted one shows 'active'",
         %{
           conn: conn,
           scope: scope
         } do
      %{tournament: tournament} = fixture(scope)
      invited_user = lightweight_user()
      {:ok, invite} = Tournaments.add_collaborator(scope, tournament, invited_user.email)

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/settings")
      assert html =~ "invited (waiting for accept)"

      assert {:ok, _} =
               Tournaments.accept_invitation(
                 Accounts.Scope.for_user(invited_user),
                 invite.invite_token
               )

      html = render(lv)
      assert html =~ "active"
      refute html =~ "invited (waiting for accept)"
    end

    test "the owner can remove a still-pending invite from the Share/Team card", %{
      conn: conn,
      scope: scope
    } do
      %{tournament: tournament} = fixture(scope)
      {:ok, invite} = Tournaments.add_collaborator(scope, tournament, "friend@example.com")

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings")

      lv |> element(~s(button[phx-value-id="#{invite.id}"])) |> render_click()

      # Same self-broadcast race as the "enter a pairing result" test above
      # — remove_collaborator/3 broadcasts on the tournament topic that this
      # `lv` (Settings) is itself subscribed to. Drain it before the test
      # (and `lv`'s teardown) proceeds.
      render(lv)

      assert Tournaments.list_collaborators(tournament) == []
    end
  end

  describe "the Tournaments page's Pending invitations section" do
    test "shows a pending invite with the inviter's email and accepting from there grants access",
         %{scope: scope} do
      %{tournament: tournament} = fixture(scope)
      invited_user = lightweight_user()
      {:ok, invite} = Tournaments.add_collaborator(scope, tournament, invited_user.email)

      invited_conn = Phoenix.ConnTest.build_conn() |> log_in_user(invited_user)

      {:ok, lv, html} = live(invited_conn, ~p"/")

      assert html =~ "Pending invitations"
      assert html =~ tournament.name
      assert html =~ scope.user.email

      {:error, {:live_redirect, %{to: to}}} =
        lv
        |> element(~s(button[phx-value-token="#{invite.invite_token}"]), "Accept")
        |> render_click()

      assert to == ~p"/t/#{tournament.id}/players"

      assert %{status: "accepted"} = hd(Tournaments.list_collaborators(tournament))
    end

    test "declining from the Tournaments page removes the invite and it no longer shows", %{
      scope: scope
    } do
      %{tournament: tournament} = fixture(scope)
      invited_user = lightweight_user()
      {:ok, invite} = Tournaments.add_collaborator(scope, tournament, invited_user.email)

      invited_conn = Phoenix.ConnTest.build_conn() |> log_in_user(invited_user)

      {:ok, lv, _html} = live(invited_conn, ~p"/")

      lv
      |> element(~s(button[phx-value-token="#{invite.invite_token}"]), "Decline")
      |> render_click()

      refute render(lv) =~ "Pending invitations"
      assert Tournaments.list_collaborators(tournament) == []
    end
  end
end
