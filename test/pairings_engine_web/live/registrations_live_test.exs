defmodule PairingsEngineWeb.RegistrationsLiveTest do
  @moduledoc """
  The review page: `/t/:id/registrations`.

  The context tests cover what a pull and a decision DO. These cover the
  promise the page makes on top of that - that a server the arbiter cannot
  reach produces a sentence on the screen rather than a crashed LiveView,
  and that "Accept" and "Discard" are genuinely different buttons.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias PairingsEngine.{Publishing, Registrations, Repo, Tournaments}
  alias PairingsEngine.Tournaments.Player

  setup :register_and_log_in_user

  setup do
    Publishing.put_endpoint("https://openresults.example/")
    Publishing.put_token("s3cret")

    # The request goes out from the LiveView process, not from the test's, so
    # a stub owned by this process would never be found.
    Req.Test.set_req_test_to_shared(%{})
    :ok
  end

  defp published_tournament(scope, opts \\ []) do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{
        "name" => "Gent Spring Open",
        "type" => "swiss",
        "rounds_count" => "5"
      })

    if Keyword.get(opts, :publish, true) do
      {:ok, tournament} = Tournaments.set_publish_to_openresults(tournament, true)
      tournament
    else
      tournament
    end
  end

  defp serve(entries) do
    Req.Test.stub(PairingsEngine.PublishingTest, fn conn ->
      Req.Test.json(conn, %{"registrations" => entries})
    end)
  end

  defp entry(id, overrides \\ %{}) do
    %{
      "id" => id,
      "received_at" => "2026-02-01T09:12:00Z",
      "payload" => %{
        "schema" => "openresults/registration",
        "version" => 1,
        "tournament_slug" => "gent-spring-open-2026",
        "player" =>
          Map.merge(
            %{
              "name" => "De Vos, Ilse",
              "rating" => 1804,
              "federation" => "BEL",
              "club" => "KGSRL",
              "email" => "ilse@example.com",
              "requested_byes" => [3]
            },
            overrides
          )
      }
    }
  end

  defp player_count(tournament) do
    Repo.aggregate(from(p in Player, where: p.tournament_id == ^tournament.id), :count, :id)
  end

  test "a tournament that is not published says so instead of offering a fetch", %{
    conn: conn,
    scope: scope
  } do
    tournament = published_tournament(scope, publish: false)

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/registrations")

    assert html =~ "not published to the results site"
    refute html =~ "Fetch entries"
  end

  test "fetching with nothing pending says so rather than showing an error", %{
    conn: conn,
    scope: scope
  } do
    tournament = published_tournament(scope)
    serve([])

    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/registrations")
    html = lv |> element("button", "Fetch entries") |> render_click()

    assert html =~ "Nothing has been submitted"
    refute html =~ "error-note"
  end

  test "fetching lists what came in, and nobody is a player yet", %{conn: conn, scope: scope} do
    tournament = published_tournament(scope)
    serve([entry(1), entry(2, %{"name" => "Peeters, Jan", "email" => "jan@example.com"})])

    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/registrations")
    html = lv |> element("button", "Fetch entries") |> render_click()

    assert html =~ "De Vos, Ilse"
    assert html =~ "Peeters, Jan"
    assert html =~ "2 new entries"
    # The email is why this page is behind a login: the arbiter needs it to
    # reach the person, and it appears nowhere else in the application.
    assert html =~ "ilse@example.com"

    assert player_count(tournament) == 0
  end

  test "accepting from the page creates the player", %{conn: conn, scope: scope} do
    tournament = published_tournament(scope)
    serve([entry(1)])

    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/registrations")
    lv |> element("button", "Fetch entries") |> render_click()

    html = lv |> element("button", "Accept") |> render_click()

    assert html =~ "Added De Vos, Ilse"
    assert player_count(tournament) == 1

    player = Repo.one(from p in Player, where: p.tournament_id == ^tournament.id)
    assert player.name == "De Vos, Ilse"
    assert player.absent
    assert player.absent_rounds == "3"

    # It leaves the waiting list and appears under the decisions.
    assert Registrations.pending(tournament.id) == []
    assert [%{status: "accepted"}] = Registrations.decided(tournament.id)
  end

  test "discarding from the page creates nothing", %{conn: conn, scope: scope} do
    tournament = published_tournament(scope)
    serve([entry(1)])

    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/registrations")
    lv |> element("button", "Fetch entries") |> render_click()

    html = lv |> element("button", "Discard") |> render_click()

    assert html =~ "No player was created"
    assert player_count(tournament) == 0
    assert Registrations.pending(tournament.id) == []

    # And a second fetch does not bring it back.
    html = lv |> element("button", "Fetch entries") |> render_click()
    assert html =~ "Nothing new"
    assert Registrations.pending(tournament.id) == []
  end

  test "a server that cannot be reached puts a sentence on the page, not a crash", %{
    conn: conn,
    scope: scope
  } do
    tournament = published_tournament(scope)

    Req.Test.stub(PairingsEngine.PublishingTest, fn conn ->
      Req.Test.transport_error(conn, :econnrefused)
    end)

    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/registrations")
    html = lv |> element("button", "Fetch entries") |> render_click()

    # The whole point of the phrasing rule: an arbiter in a school gym reads
    # this, not `%Req.TransportError{reason: :econnrefused}`.
    assert html =~ "connection was refused"
    refute html =~ "TransportError"

    # Still alive, and still usable once the wifi comes back.
    assert render(lv) =~ "Fetch entries"

    serve([entry(1)])
    html = lv |> element("button", "Fetch entries") |> render_click()
    assert html =~ "De Vos, Ilse"
    refute html =~ "connection was refused"
  end

  test "a rejected token is reported without losing the page", %{conn: conn, scope: scope} do
    tournament = published_tournament(scope)

    Req.Test.stub(PairingsEngine.PublishingTest, fn conn ->
      Plug.Conn.send_resp(conn, 401, ~s({"error":"unauthorized"}))
    end)

    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/registrations")
    html = lv |> element("button", "Fetch entries") |> render_click()

    assert html =~ "rejected the token"
    assert render(lv) =~ "Fetch entries"
  end

  test "a request for a round this tournament does not have is called out", %{
    conn: conn,
    scope: scope
  } do
    tournament = published_tournament(scope)
    serve([entry(1, %{"requested_byes" => [3, 9]})])

    {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/registrations")
    html = lv |> element("button", "Fetch entries") |> render_click()

    # Five rounds, so round 9 is a misreading somebody should see rather
    # than a value that silently disappears on accept.
    assert html =~ "no round"
    assert html =~ "9"

    lv |> element("button", "Accept") |> render_click()
    player = Repo.one(from p in Player, where: p.tournament_id == ^tournament.id)
    assert player.absent_rounds == "3"
  end
end
