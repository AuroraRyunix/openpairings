defmodule PairingsEngineWeb.E2E.PublishTest do
  @moduledoc """
  Publishing a tournament to OpenResults, from the switch on Settings >
  Results to the copy arriving on the results site. The results site is
  `PairingsEngine.PublicServerStub`, answering the published wire, so nothing
  leaves the machine and every request is something this test can count.

  The desktop's public publishing, which is the path with a consent dialog
  between the arbiter and the network: local mode, for this test only.
  """
  use PairingsEngineWeb.E2ECase

  alias PairingsEngine.{Publishing, Repo, Tournaments}
  alias PairingsEngine.Accounts.Scope
  alias PairingsEngine.Pairing, as: Engine
  alias PairingsEngine.PublicServerStub, as: Server
  alias PairingsEngine.Tournaments.Player

  setup %{conn: conn} do
    # Signed in first: in local mode a loopback request with no session is
    # given the owner's, and this test is about the user it signed in.
    {conn, user} = sign_in(conn)

    previous = Application.get_env(:pairings_engine, :local_mode)
    Application.put_env(:pairings_engine, :local_mode, true)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:pairings_engine, :local_mode)
        value -> Application.put_env(:pairings_engine, :local_mode, value)
      end
    end)

    Publishing.put_endpoint(nil)
    Publishing.put_public_base(nil)
    Publishing.put_token(nil)
    # Shared: the requests are made by the LiveView and by the drain, not by
    # this process.
    Req.Test.set_req_test_to_shared(%{})
    Server.install(self())

    {:ok, tournament} =
      Tournaments.create_tournament(Scope.for_user(user), %{
        "name" => "Published Open",
        "type" => "swiss",
        "rounds_count" => "3"
      })

    for {name, n} <- [{"Alpha", 1}, {"Bravo", 2}] do
      Repo.insert!(%Player{tournament_id: tournament.id, name: name, pairing_number: n})
    end

    {:ok, _} = Engine.pair_next_round(tournament)

    {:ok, conn: conn, tournament: tournament}
  end

  test "agree, and the tournament reaches the results site", %{conn: conn, tournament: t} do
    conn =
      conn
      |> visit("/t/#{t.id}/settings/results")
      |> assert_has("body .phx-connected")
      |> click("#site-presence-link")
      |> assert_has("#public-consent", text: "Publish on openresults.cloud?")
      |> within("#public-consent", &click_button(&1, "Agree and publish"))
      |> assert_has("body", text: "registers with openresults.cloud")

    # Only the question went out before the answer; the rest is the drain's.
    assert Server.calls() == [{"GET", "/api/server"}]

    assert {1, 0} = Publishing.drain()

    assert Server.calls() == [
             {"POST", "/api/installations"},
             {"POST", "/api/tournaments"},
             {"POST", "/api/snapshots"}
           ]

    slug = Tournaments.get_tournament!(t.id).public_slug
    assert slug

    conn
    |> visit("/t/#{t.id}/settings/results")
    |> assert_has("body .phx-connected")
    |> assert_has("body", text: "https://openresults.cloud/t/#{slug}")
  end

  test "declining sends nothing", %{conn: conn, tournament: t} do
    conn
    |> visit("/t/#{t.id}/settings/results")
    |> assert_has("body .phx-connected")
    |> click("#site-presence-link")
    |> assert_has("#public-consent")
    |> within("#public-consent", &click_button(&1, "Do not publish"))
    |> assert_has("body", text: "Nothing was sent. Publishing is off for this tournament.")

    assert Server.calls() == [{"GET", "/api/server"}]
    assert {0, 0} = Publishing.drain()
    assert Server.requests() == []
    refute Tournaments.get_tournament!(t.id).publish_to_openresults
  end
end
