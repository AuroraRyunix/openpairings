defmodule PairingsEngineWeb.MobileConnectControllerTest do
  @moduledoc """
  `/m/connect`: an arbiter's own way onto Manubrium, signed in, with codes
  bound to the account. And the doors an arbiter does not get.
  """
  use PairingsEngineWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.{RateLimit, Repo, Tournaments}
  alias PairingsEngine.Accounts.Scope
  alias PairingsEngine.Mobile.Enrollment

  setup do
    owner = user_scope_fixture()

    {:ok, t} =
      Tournaments.create_tournament(owner, %{"name" => "Connect Open", "type" => "swiss"})

    arbiter = user_fixture()
    {:ok, c} = Tournaments.add_collaborator(owner, t, arbiter.email, "arbiter")
    {:ok, _} = Tournaments.accept_invitation(Scope.for_user(arbiter), c.invite_token)
    RateLimit.clear(:mobile_code_create, Integer.to_string(arbiter.id))
    %{owner: owner, tournament: t, arbiter: arbiter}
  end

  test "signed out is sent to sign in", %{conn: conn} do
    conn = get(conn, ~p"/m/connect")
    assert redirected_to(conn) =~ "/users/log-in"
  end

  test "lists the tournaments the account works in", %{conn: conn, arbiter: a, tournament: t} do
    conn = conn |> log_in_user(a) |> get(~p"/m/connect")
    html = html_response(conn, 200)

    assert html =~ "connect-#{t.id}"
    assert html =~ "Connect Open"
    assert html =~ "Arbiter"
  end

  test "\"use this phone\" enrols the browser under the account", %{
    conn: conn,
    arbiter: a,
    tournament: t
  } do
    conn = conn |> log_in_user(a) |> post(~p"/m/connect/#{t.id}")

    assert redirected_to(conn) == ~p"/m/results"
    e = Repo.get!(Enrollment, get_session(conn, :mobile_enrollment_id))
    assert e.user_id == a.id
    assert e.level == "deputy"
    assert e.tournament_id == t.id
    assert %DateTime{} = e.claimed_at
  end

  test "\"a code for another phone\" shows a QR, claims nothing", %{
    conn: conn,
    arbiter: a,
    tournament: t
  } do
    conn = conn |> log_in_user(a) |> post(~p"/m/connect/#{t.id}/code")
    html = html_response(conn, 200)

    assert html =~ "connect-qr"
    assert [e] = Repo.all(Enrollment)
    assert html =~ "/m/e/#{e.token}"
    assert e.user_id == a.id
    assert e.claimed_at == nil
    assert get_session(conn, :mobile_enrollment_id) == nil
  end

  test "a tournament the account does not work in gets no code", %{conn: conn, tournament: t} do
    stranger = user_fixture()
    conn = conn |> log_in_user(stranger) |> post(~p"/m/connect/#{t.id}")

    assert redirected_to(conn) == ~p"/m/connect"
    assert Repo.all(Enrollment) == []
  end

  test "the arbiter's desk pages stay shut", %{conn: conn, arbiter: a, tournament: t} do
    conn = log_in_user(conn, a)

    assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/t/#{t.id}/pairings") end
    assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/t/#{t.id}/players") end
  end

  test "accepting an arbiter invitation lands on /m/connect", %{
    conn: conn,
    owner: owner,
    tournament: t
  } do
    invitee = user_fixture()
    {:ok, c} = Tournaments.add_collaborator(owner, t, invitee.email, "arbiter")

    {:ok, lv, _html} = conn |> log_in_user(invitee) |> live(~p"/invites/#{c.invite_token}")

    assert {:error, {:redirect, %{to: "/m/connect"}}} =
             lv |> element("button[phx-click='accept']") |> render_click()

    assert Tournaments.hall_role(invitee, t.id) == :arbiter
  end
end
