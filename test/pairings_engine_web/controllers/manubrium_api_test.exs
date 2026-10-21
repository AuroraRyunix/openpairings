defmodule PairingsEngineWeb.ManubriumApiTest do
  @moduledoc """
  `/api/manubrium/v1` as the app meets it (docs/manubrium.md, "Full app"):
  the token, the roles, the walls between tournaments, and every route's
  happy path with at least one refusal.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.{Audit, Manubrium, Repo, Tournaments}
  alias PairingsEngine.Pairing, as: Engine
  alias PairingsEngine.Tournaments.{Collaborator, Pairing}

  @api "/api/manubrium/v1"

  ## ---------- fixtures ----------

  defp tournament(scope, attrs \\ %{}) do
    dates = for r <- 1..3, do: Date.to_iso8601(Date.add(~D[2026-11-01], (r - 1) * 7))

    {:ok, t} =
      Tournaments.create_tournament(
        scope,
        Map.merge(
          %{
            "name" => "Phone Open #{System.unique_integer([:positive])}",
            "type" => "swiss",
            "rounds_count" => "3",
            "round_dates" => dates,
            "start_date" => hd(dates),
            "end_date" => List.last(dates)
          },
          attrs
        )
      )

    for {name, rating} <- [{"Anna", 2100}, {"Bert", 2000}, {"Cleo", 1900}, {"Dirk", 1800}] do
      {:ok, _} =
        Tournaments.create_player(t.id, %{"name" => name, "fide_rating" => to_string(rating)})
    end

    Tournaments.get_tournament!(t.id)
  end

  defp paired(scope) do
    t = tournament(scope)
    {:ok, _round} = Engine.pair_next_round(t)
    Tournaments.get_tournament!(t.id)
  end

  defp token(scope) do
    {:ok, %{secret: secret}} = Manubrium.create_connect_code(scope, "http://test")
    {:ok, _device, token} = Manubrium.redeem(secret, %{"name" => "Test phone"}, "10.1.1.1")
    token
  end

  defp enlist(owner, t, role) do
    scope = user_scope_fixture()
    {:ok, c} = Tournaments.add_collaborator(owner, t, scope.user.email, role)
    {:ok, _} = Tournaments.accept_invitation(scope, c.invite_token)
    _ = Repo.get!(Collaborator, c.id)
    scope
  end

  defp phone(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("accept", "application/json")
  end

  defp first_board(t) do
    Tournaments.get_round(t.id, 1).pairings
    |> Enum.reject(&is_nil(&1.black_player_id))
    |> Enum.min_by(& &1.board)
  end

  defp result_entry(p, result, expected \\ "") do
    %{
      "cid" => Ecto.UUID.generate(),
      "kind" => "result",
      "round" => 1,
      "pairing" => p.id,
      "board" => p.board,
      "white" => p.white_player_id,
      "black" => p.black_player_id,
      "result" => result,
      "expected" => expected
    }
  end

  setup do
    owner = user_scope_fixture()
    %{owner: owner, token: token(owner)}
  end

  ## ---------- the token ----------

  describe "connecting" do
    test "a connect code becomes a device token, once", %{conn: conn, owner: owner} do
      {:ok, %{secret: secret}} = Manubrium.create_connect_code(owner, "http://test")

      body =
        conn
        |> post(@api <> "/connect", %{"secret" => secret, "name" => "iPhone"})
        |> json_response(201)

      assert "mnb_" <> _ = body["token"]
      assert body["device"]["name"] == "iPhone"
      assert body["user"]["email"] == owner.user.email
      assert body["server"]["api"] == 1

      assert %{"error" => "invalid_code"} =
               conn |> post(@api <> "/connect", %{"secret" => secret}) |> json_response(401)

      assert %{"error" => "bad_request"} =
               conn |> post(@api <> "/connect", %{}) |> json_response(400)
    end

    test "sets no cookie", %{conn: conn, token: token} do
      conn = conn |> phone(token) |> get(@api <> "/me")
      assert json_response(conn, 200)
      assert get_resp_header(conn, "set-cookie") == []
    end
  end

  describe "the token" do
    test "no token, a wrong one and a withdrawn one are 401", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      assert %{"error" => "unauthorized"} = conn |> get(@api <> "/me") |> json_response(401)

      assert %{"error" => "unauthorized"} =
               conn |> phone("mnb_nope") |> get(@api <> "/me") |> json_response(401)

      assert %{"user" => %{"email" => email}} =
               conn |> phone(token) |> get(@api <> "/me") |> json_response(200)

      assert email == owner.user.email

      [device] = Manubrium.list_devices(owner)
      {:ok, _} = Manubrium.revoke_device(owner, device.id)

      assert %{"error" => "unauthorized"} =
               conn |> phone(token) |> get(@api <> "/me") |> json_response(401)

      assert %{"error" => "unauthorized"} =
               conn |> phone(token) |> get(@api <> "/tournaments") |> json_response(401)
    end

    test "signing out from the phone withdraws it", %{conn: conn, token: token} do
      assert conn |> phone(token) |> delete(@api <> "/me") |> response(204)

      assert %{"error" => "unauthorized"} =
               conn |> phone(token) |> get(@api <> "/me") |> json_response(401)
    end
  end

  ## ---------- reading ----------

  describe "tournaments" do
    test "lists the account's tournaments with the role, and nobody else's", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      mine = tournament(owner)
      other_owner = user_scope_fixture()
      theirs = tournament(other_owner)
      shared = tournament(other_owner)
      _ = enlist_existing(other_owner, shared, owner, "arbiter")

      rows = conn |> phone(token) |> get(@api <> "/tournaments") |> json_response(200)
      roles = Map.new(rows["tournaments"], &{&1["id"], &1["role"]})

      assert roles[mine.id] == "owner"
      assert roles[shared.id] == "arbiter"
      refute Map.has_key?(roles, theirs.id)
    end

    test "one tournament says what the role may do; another account's is 404", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      t = tournament(owner)

      body = conn |> phone(token) |> get(@api <> "/tournaments/#{t.id}") |> json_response(200)
      assert "pair" in body["tournament"]["can"]
      assert body["tournament"]["next_round"]["number"] == 1
      assert body["tournament"]["next_round"]["blocker"] == nil

      theirs = tournament(user_scope_fixture())

      assert %{"error" => "tournament_not_found"} =
               conn
               |> phone(token)
               |> get(@api <> "/tournaments/#{theirs.id}")
               |> json_response(404)

      assert %{"error" => "tournament_not_found"} =
               conn |> phone(token) |> get(@api <> "/tournaments/nope") |> json_response(404)
    end

    test "a round lists its boards; an unpaired one is 404", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      t = paired(owner)

      body =
        conn |> phone(token) |> get(@api <> "/tournaments/#{t.id}/rounds/1") |> json_response(200)

      assert length(body["round"]["boards"]) == 2
      assert body["round"]["latest"]
      assert "1-0" in body["round"]["results"]

      assert %{"error" => "not_paired"} =
               conn
               |> phone(token)
               |> get(@api <> "/tournaments/#{t.id}/rounds/2")
               |> json_response(404)
    end

    test "standings carry the tournament's tie-breaks", %{conn: conn, owner: owner, token: token} do
      t = paired(owner)

      body =
        conn
        |> phone(token)
        |> get(@api <> "/tournaments/#{t.id}/standings")
        |> json_response(200)

      assert length(body["standings"]["rows"]) == 4
      assert body["standings"]["tiebreaks"] != []
    end
  end

  ## ---------- roles ----------

  describe "an arbiter" do
    setup %{owner: owner} do
      t = paired(owner)
      arbiter = enlist(owner, t, "arbiter")
      %{t: t, arbiter_token: token(arbiter)}
    end

    test "sees the round and enters results, and nothing of the desk's", %{
      conn: conn,
      t: t,
      arbiter_token: token
    } do
      body = conn |> phone(token) |> get(@api <> "/tournaments/#{t.id}") |> json_response(200)
      assert body["tournament"]["can"] == ["results", "incidents"]
      assert body["tournament"]["next_round"] == nil

      assert conn
             |> phone(token)
             |> get(@api <> "/tournaments/#{t.id}/rounds/1")
             |> json_response(200)

      p = first_board(t)

      assert %{"results" => [%{"status" => "saved"}]} =
               conn
               |> phone(token)
               |> post(@api <> "/tournaments/#{t.id}/sync", %{
                 "entries" => [result_entry(p, "1-0")]
               })
               |> json_response(200)

      for {method, path, params} <- [
            {:post, "/rounds", %{}},
            {:delete, "/rounds/1", %{}},
            {:put, "/rounds/1/publish", %{"level" => 1}},
            {:get, "/standings", %{}},
            {:get, "/incidents", %{}},
            {:get, "/players", %{}},
            {:post, "/players", %{"player" => %{"name" => "Late"}}}
          ] do
        conn =
          conn |> phone(token) |> dispatch_api(method, "/tournaments/#{t.id}" <> path, params)

        assert %{"error" => "arbiter_role"} = json_response(conn, 403), "#{method} #{path}"
      end

      assert Tournaments.get_round(t.id, 1)
    end
  end

  describe "an editor" do
    test "may pair and edit players", %{conn: conn, owner: owner} do
      t = tournament(owner)
      editor = enlist(owner, t, "editor")
      token = token(editor)

      assert %{"round" => %{"number" => 1}} =
               conn
               |> phone(token)
               |> post(@api <> "/tournaments/#{t.id}/rounds", %{})
               |> json_response(201)

      assert %{"players" => [_, _, _, _]} =
               conn
               |> phone(token)
               |> get(@api <> "/tournaments/#{t.id}/players")
               |> json_response(200)
    end
  end

  ## ---------- the hall: results and incidents ----------

  describe "sync" do
    test "saves a result under the account's name, and is idempotent", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      t = paired(owner)
      p = first_board(t)
      entry = result_entry(p, "1/2-1/2")

      body =
        conn
        |> phone(token)
        |> post(@api <> "/tournaments/#{t.id}/sync", %{"entries" => [entry]})
        |> json_response(200)

      assert [%{"cid" => cid, "status" => "saved"}] = body["results"]
      assert cid == entry["cid"]
      assert Repo.get!(Pairing, p.id).result == "1/2-1/2"

      # The same entry again, as an app does after a lost answer.
      assert %{"results" => [%{"status" => "saved"}]} =
               conn
               |> phone(token)
               |> post(@api <> "/tournaments/#{t.id}/sync", %{"entries" => [entry]})
               |> json_response(200)
    end

    test "refuses an entry that does not expect what the board says", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      t = paired(owner)
      p = first_board(t)
      {:ok, _} = Tournaments.update_pairing_result(p, "0-1")

      assert %{"results" => [%{"status" => "refused"}]} =
               conn
               |> phone(token)
               |> post(@api <> "/tournaments/#{t.id}/sync", %{
                 "entries" => [result_entry(p, "1-0")]
               })
               |> json_response(200)

      assert Repo.get!(Pairing, p.id).result == "0-1"
    end

    test "logs an incident the desk then lists", %{conn: conn, owner: owner, token: token} do
      t = paired(owner)
      p = first_board(t)

      incident = %{
        "cid" => Ecto.UUID.generate(),
        "kind" => "incident",
        "round" => 1,
        "pairing" => p.id,
        "board" => p.board,
        "type" => "clock",
        "note" => "Flag fell, nobody noticed"
      }

      assert %{"results" => [%{"status" => "saved"}]} =
               conn
               |> phone(token)
               |> post(@api <> "/tournaments/#{t.id}/sync", %{"entries" => [incident]})
               |> json_response(200)

      assert %{"incidents" => [%{"kind" => "clock", "note" => "Flag fell, nobody noticed"}]} =
               conn
               |> phone(token)
               |> get(@api <> "/tournaments/#{t.id}/incidents")
               |> json_response(200)
    end

    test "another account's tournament and a malformed body are refused", %{
      conn: conn,
      token: token
    } do
      theirs = paired(user_scope_fixture())
      p = first_board(theirs)

      assert %{"error" => "tournament_not_found"} =
               conn
               |> phone(token)
               |> post(@api <> "/tournaments/#{theirs.id}/sync", %{
                 "entries" => [result_entry(p, "1-0")]
               })
               |> json_response(404)

      assert Repo.get!(Pairing, p.id).result in [nil, ""]

      mine = paired(user_scope_fixture())

      assert conn
             |> phone(token)
             |> post(@api <> "/tournaments/#{mine.id}/sync", %{"entries" => "x"})
             |> json_response(400)
    end
  end

  describe "clearing a result" do
    test "clears what the phone expects; a moved board is a conflict", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      t = paired(owner)
      p = first_board(t)
      {:ok, _} = Tournaments.update_pairing_result(p, "1-0")
      path = @api <> "/tournaments/#{t.id}/rounds/1/boards/#{p.id}/clear"

      assert %{"error" => "conflict", "current" => "1-0"} =
               conn |> phone(token) |> post(path, %{"expected" => "0-1"}) |> json_response(409)

      assert %{"status" => "cleared"} =
               conn |> phone(token) |> post(path, %{"expected" => "1-0"}) |> json_response(200)

      assert Repo.get!(Pairing, p.id).result in [nil, ""]
    end
  end

  ## ---------- the desk ----------

  describe "pairing" do
    test "pairs the next round, audited as the desk does", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      t = tournament(owner)

      body =
        conn
        |> phone(token)
        |> post(@api <> "/tournaments/#{t.id}/rounds", %{})
        |> json_response(201)

      assert body["round"]["number"] == 1
      assert length(body["round"]["boards"]) == 2
      assert Enum.any?(Audit.list_for_tournament(t.id), &(&1.action == "pairing.round_paired"))
    end

    test "refuses while the setup is incomplete", %{conn: conn, owner: owner, token: token} do
      {:ok, t} = Tournaments.create_tournament(owner, %{"name" => "Half done", "type" => "swiss"})

      assert %{"error" => "setup_incomplete"} =
               conn
               |> phone(token)
               |> post(@api <> "/tournaments/#{t.id}/rounds", %{})
               |> json_response(409)
    end

    test "unpairs the latest round; a round that is not the latest is refused", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      t = paired(owner)

      assert %{"error" => "refused"} =
               conn
               |> phone(token)
               |> delete(@api <> "/tournaments/#{t.id}/rounds/2")
               |> json_response(422)

      assert conn
             |> phone(token)
             |> delete(@api <> "/tournaments/#{t.id}/rounds/1")
             |> response(204)

      assert Tournaments.get_round(t.id, 1) == nil
    end
  end

  describe "publishing" do
    test "sets a round's public level; a level that does not exist is 400", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      t = paired(owner)
      path = @api <> "/tournaments/#{t.id}/rounds/1/publish"

      assert %{"publish_level" => 1} =
               conn |> phone(token) |> put(path, %{"level" => 1}) |> json_response(200)

      assert %{"error" => "bad_request"} =
               conn |> phone(token) |> put(path, %{"level" => 7}) |> json_response(400)

      assert %{"error" => "round_not_complete"} =
               conn |> phone(token) |> put(path, %{"level" => 3}) |> json_response(409)
    end
  end

  describe "players" do
    test "a late entry, and a duplicate FIDE ID refused", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      t = paired(owner)
      path = @api <> "/tournaments/#{t.id}/players"

      body =
        conn
        |> phone(token)
        |> post(path, %{"player" => %{"name" => "Late, Lou", "fide_id" => "12345678"}})
        |> json_response(201)

      assert body["player"]["name"] == "Late, Lou"
      assert body["player"]["status"] == "active"

      assert %{"error" => "duplicate_fide_id"} =
               conn
               |> phone(token)
               |> post(path, %{"player" => %{"name" => "Lou again", "fide_id" => "12345678"}})
               |> json_response(422)
    end

    test "withdraws, re-enters and asks for rounds off", %{conn: conn, owner: owner, token: token} do
      t = paired(owner)
      [player | _] = Tournaments.list_players(t.id)
      path = @api <> "/tournaments/#{t.id}/players/#{player.id}"

      assert %{"player" => %{"status" => "withdrawn"}} =
               conn
               |> phone(token)
               |> patch(path, %{"player" => %{"withdrawn" => true}})
               |> json_response(200)

      assert %{"player" => %{"status" => "active", "absent_rounds" => [3]}} =
               conn
               |> phone(token)
               |> patch(path, %{"player" => %{"withdrawn" => false, "absent_rounds" => [3]}})
               |> json_response(200)
    end

    test "a player of another tournament is 404", %{conn: conn, owner: owner, token: token} do
      t = paired(owner)
      other = paired(owner)
      [stranger | _] = Tournaments.list_players(other.id)

      assert %{"error" => "player_not_found"} =
               conn
               |> phone(token)
               |> patch(@api <> "/tournaments/#{t.id}/players/#{stranger.id}", %{
                 "player" => %{"name" => "Renamed"}
               })
               |> json_response(404)

      assert Repo.reload!(stranger).name == stranger.name
    end
  end

  ## ---------- helpers ----------

  # `existing` (an account already made) is invited to `t` as `role` and
  # accepts.
  defp enlist_existing(owner, t, existing, role) do
    {:ok, c} = Tournaments.add_collaborator(owner, t, existing.user.email, role)
    {:ok, _} = Tournaments.accept_invitation(existing, c.invite_token)
    c
  end

  defp dispatch_api(conn, :get, path, params), do: get(conn, @api <> path, params)
  defp dispatch_api(conn, :post, path, params), do: post(conn, @api <> path, params)
  defp dispatch_api(conn, :put, path, params), do: put(conn, @api <> path, params)
  defp dispatch_api(conn, :delete, path, params), do: delete(conn, @api <> path, params)
end
