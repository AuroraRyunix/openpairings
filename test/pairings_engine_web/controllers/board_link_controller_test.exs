defmodule PairingsEngineWeb.BoardLinkControllerTest do
  @moduledoc """
  `/api/boards/v1` as a hall box meets it - the contract in
  docs/board-link-api.md, request by request.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import PairingsEngine.AccountsFixtures
  import PairingsEngine.BoardLinkFixtures

  alias PairingsEngine.{BoardLink, RateLimit, Repo, TournamentGroups, Tournaments}
  alias PairingsEngine.BoardLink.Link
  alias PairingsEngine.Tournaments.Pairing

  setup do
    scope = user_scope_fixture()
    fixture = paired_tournament(scope)
    {:ok, link, secret} = BoardLink.create_link(scope, fixture.tournament)

    fixture |> Map.put(:scope, scope) |> Map.put(:link, link) |> Map.put(:secret, secret)
  end

  defp box(conn, secret, headers \\ []) do
    Enum.reduce(
      [{"authorization", "Bearer " <> secret} | headers],
      conn,
      fn {name, value}, conn -> put_req_header(conn, name, value) end
    )
  end

  defp etag(conn), do: conn |> get_resp_header("etag") |> List.first()

  describe "the code" do
    test "no code, a wrong code and a withdrawn code are all 401", %{
      conn: conn,
      scope: scope,
      tournament: t,
      link: link,
      secret: secret
    } do
      assert %{"error" => "unauthorized"} =
               conn |> get(~p"/api/boards/v1/link") |> json_response(401)

      assert %{"error" => "unauthorized"} =
               conn |> box("oplt_nope") |> get(~p"/api/boards/v1/link") |> json_response(401)

      assert conn |> box(secret) |> get(~p"/api/boards/v1/link") |> json_response(200)

      {:ok, _} = BoardLink.revoke_link(scope, t, link.id)

      assert %{"error" => "unauthorized"} =
               conn |> box(secret) |> get(~p"/api/boards/v1/link") |> json_response(401)
    end

    test "there is no session and no CSRF token to it", %{
      conn: conn,
      secret: secret,
      tournament: t
    } do
      # A POST with nothing but the bearer secret: a browser pipeline would
      # have refused it for the missing token.
      conn =
        conn
        |> box(secret)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/boards/v1/tournaments/#{t.id}/games", Jason.encode!(%{}))

      assert %{"error" => "invalid_request"} = json_response(conn, 422)
      assert get_resp_header(conn, "set-cookie") == []
    end

    test "refused codes are rationed by address", %{conn: conn, secret: secret} do
      max = RateLimit.config(:board_link_auth).max

      for _ <- 1..max do
        assert conn |> box("oplt_wrong") |> get(~p"/api/boards/v1/link") |> json_response(401)
      end

      refused = conn |> box("oplt_wrong") |> get(~p"/api/boards/v1/link")
      assert %{"error" => "rate_limited"} = json_response(refused, 429)
      assert get_resp_header(refused, "retry-after") == ["600"]

      # The box in the same hall, behind the same address, is not switched
      # off by somebody else's guessing.
      assert conn |> box(secret) |> get(~p"/api/boards/v1/link") |> json_response(200)
    end

    test "an accepted code has a budget of its own", %{conn: conn, secret: secret, link: link} do
      max = RateLimit.config(:board_link).max
      for _ <- 1..max, do: RateLimit.record(:board_link, Integer.to_string(link.id))

      assert %{"error" => "rate_limited"} =
               conn |> box(secret) |> get(~p"/api/boards/v1/link") |> json_response(429)
    end
  end

  describe "GET /link" do
    test "says what the code reaches, each tournament with a version", %{
      conn: conn,
      secret: secret,
      tournament: t
    } do
      conn = conn |> box(secret) |> get(~p"/api/boards/v1/link")
      body = json_response(conn, 200)

      assert %{"api" => 1, "kind" => "tournament", "group" => nil, "poll_seconds" => 5} = body
      assert body["server"]["name"] == "OpenPairings"

      assert [%{"id" => id, "name" => "Board Link Open", "state" => _, "version" => version}] =
               body["tournaments"]

      assert id == t.id
      assert is_binary(version) and version != ""
      assert etag(conn)
    end

    test "an unchanged listing is a 304, a changed one is not", %{
      conn: conn,
      secret: secret,
      boards: [board1 | _]
    } do
      first = conn |> box(secret) |> get(~p"/api/boards/v1/link")
      tag = etag(first)

      again =
        conn |> box(secret, [{"if-none-match", tag}]) |> get(~p"/api/boards/v1/link")

      assert response(again, 304) == ""

      {:ok, _} = Tournaments.update_pairing_result(board1, "1-0")

      changed =
        conn |> box(secret, [{"if-none-match", tag}]) |> get(~p"/api/boards/v1/link")

      assert json_response(changed, 200)
      refute etag(changed) == tag
    end

    test "a group code lists the group, and a tournament added to it later", %{
      conn: conn,
      scope: scope,
      tournament: t
    } do
      {:ok, group} = TournamentGroups.create_group(scope, t, "The Event")
      {:ok, _link, secret} = BoardLink.create_group_link(scope, t)

      body = conn |> box(secret) |> get(~p"/api/boards/v1/link") |> json_response(200)
      assert %{"kind" => "group", "group" => %{"name" => "The Event"}} = body
      assert [t.id] == Enum.map(body["tournaments"], & &1["id"])

      later = paired_tournament(scope, %{name: "Added Later"}).tournament
      {:ok, _group} = TournamentGroups.join_group(scope, later, group.id)

      body = conn |> box(secret) |> get(~p"/api/boards/v1/link") |> json_response(200)
      assert [t.id, later.id] == Enum.map(body["tournaments"], & &1["id"])

      # One code, both tournaments' boards.
      assert conn
             |> box(secret)
             |> get(~p"/api/boards/v1/tournaments/#{later.id}")
             |> json_response(200)
    end

    test "the box's name and version are remembered", %{conn: conn, secret: secret, link: link} do
      conn
      |> box(secret, [{"x-board-box", "Hall A"}, {"x-board-box-version", "0.4.0"}])
      |> get(~p"/api/boards/v1/link")
      |> json_response(200)

      assert %Link{box_name: "Hall A", box_version: "0.4.0", last_seen_at: %DateTime{}} =
               Repo.get!(Link, link.id)
    end
  end

  describe "POST /box" do
    test "stores what the box says about itself", %{
      conn: conn,
      secret: secret,
      link: link,
      tournament: t
    } do
      assert %{"status" => "ok"} =
               conn
               |> box(secret)
               |> post(~p"/api/boards/v1/box", %{
                 "name" => "Hall A",
                 "version" => "0.4.0",
                 "boards" => %{to_string(t.id) => 4, "999999" => 12}
               })
               |> json_response(200)

      link = Repo.get!(Link, link.id)
      assert link.box_name == "Hall A"
      # A tournament the code does not reach is not counted.
      assert link.box_boards == %{to_string(t.id) => 4}
    end
  end

  describe "GET /tournaments/:id" do
    test "the document, and a 304 for a box that already has it", %{
      conn: conn,
      secret: secret,
      tournament: t,
      boards: [board1 | _]
    } do
      conn1 = conn |> box(secret) |> get(~p"/api/boards/v1/tournaments/#{t.id}")
      doc = json_response(conn1, 200)

      assert doc["current_round"] == 1
      assert [%{"boards" => [%{"game" => game} | _]}] = doc["rounds"]
      assert game == board1.game_uid
      assert etag(conn1) == ~s("#{doc["version"]}")

      assert conn
             |> box(secret, [{"if-none-match", etag(conn1)}])
             |> get(~p"/api/boards/v1/tournaments/#{t.id}")
             |> response(304) == ""
    end

    test "a tournament the code does not reach does not exist", %{
      conn: conn,
      scope: scope,
      secret: secret
    } do
      other = paired_tournament(scope, %{name: "Another"}).tournament

      for id <- [other.id, 999_999, "x"] do
        assert %{"error" => "tournament_not_found"} =
                 conn
                 |> box(secret)
                 |> get(~p"/api/boards/v1/tournaments/#{id}")
                 |> json_response(404)
      end
    end
  end

  describe "POST /tournaments/:id/games" do
    test "a game is stored, and posting it twice is the same as once", %{
      conn: conn,
      secret: secret,
      tournament: t,
      boards: [board1 | _]
    } do
      report = report_for(board1, %{"seq" => 4, "status" => "finished", "result" => "1-0"})

      assert %{"status" => "ok", "applied" => true, "seq" => 4, "game" => game} =
               conn
               |> box(secret)
               |> post(~p"/api/boards/v1/tournaments/#{t.id}/games", report)
               |> json_response(200)

      assert game == board1.game_uid

      assert %{"applied" => false, "reason" => "duplicate", "seq" => 4} =
               conn
               |> box(secret)
               |> post(~p"/api/boards/v1/tournaments/#{t.id}/games", report)
               |> json_response(200)

      assert %{"applied" => false, "reason" => "stale", "seq" => 4} =
               conn
               |> box(secret)
               |> post(~p"/api/boards/v1/tournaments/#{t.id}/games", %{report | "seq" => 2})
               |> json_response(200)

      assert BoardLink.get_game(t.id, board1.game_uid).result == "1-0"
      # Reported. Not entered.
      assert Repo.get!(Pairing, board1.id).result == ""
    end

    test "a re-pairing reaches the box as a new version, and the old game is refused", %{
      conn: conn,
      secret: secret,
      tournament: t,
      round: round,
      boards: [board1, board2]
    } do
      before = conn |> box(secret) |> get(~p"/api/boards/v1/tournaments/#{t.id}")
      stale = report_for(board1)

      {:ok, _} =
        Tournaments.swap_players_in_round(
          Tournaments.get_round(t.id, round.number),
          board1.white_player_id,
          board2.white_player_id
        )

      # The box asking "anything new?" is told yes.
      after_swap =
        conn
        |> box(secret, [{"if-none-match", etag(before)}])
        |> get(~p"/api/boards/v1/tournaments/#{t.id}")

      doc = json_response(after_swap, 200)
      assert [%{"boards" => [%{"white" => white} | _]}] = doc["rounds"]
      assert white == board2.white_player_id

      # And what it still had in hand for the old pairing is refused by name.
      assert %{"error" => "pairing_changed"} =
               conn
               |> box(secret)
               |> post(~p"/api/boards/v1/tournaments/#{t.id}/games", stale)
               |> json_response(409)

      assert %{"error" => "pairing_gone"} =
               conn
               |> box(secret)
               |> post(~p"/api/boards/v1/tournaments/#{t.id}/games", %{stale | "game" => "gone"})
               |> json_response(409)

      assert %{} == BoardLink.games_by_uid(t.id)
    end

    test "several games in one request, each with its own answer", %{
      conn: conn,
      secret: secret,
      tournament: t,
      boards: [board1, board2]
    } do
      body = %{
        "games" => [
          report_for(board1),
          report_for(board2, %{"moves" => ["e4", "not a move"]}),
          report_for(board2, %{"game" => "gone"})
        ]
      }

      assert %{"status" => "ok", "results" => [first, second, third]} =
               conn
               |> box(secret)
               |> post(~p"/api/boards/v1/tournaments/#{t.id}/games", body)
               |> json_response(200)

      assert %{"status" => "ok", "applied" => true} = first
      assert %{"status" => "error", "error" => "invalid_request"} = second
      assert %{"status" => "error", "error" => "pairing_gone", "game" => "gone"} = third
      assert [board1.game_uid] == Map.keys(BoardLink.games_by_uid(t.id))
    end

    test "a game for a tournament the code does not reach is a 404", %{
      conn: conn,
      scope: scope,
      secret: secret
    } do
      other = paired_tournament(scope, %{name: "Another"})
      [theirs | _] = other.boards

      assert %{"error" => "tournament_not_found"} =
               conn
               |> box(secret)
               |> post(
                 ~p"/api/boards/v1/tournaments/#{other.tournament.id}/games",
                 report_for(theirs)
               )
               |> json_response(404)

      assert %{} == BoardLink.games_by_uid(other.tournament.id)
    end
  end
end
