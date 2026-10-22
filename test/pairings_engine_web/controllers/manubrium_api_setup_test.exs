defmodule PairingsEngineWeb.ManubriumApiSetupTest do
  @moduledoc """
  The Manubrium app's third batch of routes (docs/manubrium.md, "Full
  app"): a new tournament, players from the rating lists, check-in,
  requested byes, the results-site link, and the hall boxes.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import PairingsEngine.AccountsFixtures
  import PairingsEngine.BoardLinkFixtures, only: [report_for: 2]

  alias PairingsEngine.{Audit, BoardLink, ByeTypes, Features, Manubrium, Repo, Tournaments}
  alias PairingsEngine.BoardLink.Link
  alias PairingsEngine.Federations.BEL.Member
  alias PairingsEngine.Fide.FidePlayer
  alias PairingsEngine.Pairing, as: Engine
  alias PairingsEngine.Tournaments.{Collaborator, Pairing, Tournament}

  @api "/api/manubrium/v1"

  ## ---------- fixtures ----------

  defp tournament(scope, players \\ 4, attrs \\ %{}) do
    dates = for r <- 1..3, do: Date.to_iso8601(Date.add(~D[2026-11-01], (r - 1) * 7))

    {:ok, t} =
      Tournaments.create_tournament(
        scope,
        Map.merge(
          %{
            "name" => "Setup Open #{System.unique_integer([:positive])}",
            "type" => "swiss",
            "rounds_count" => "3",
            "round_dates" => dates
          },
          attrs
        )
      )

    for i <- 1..players//1 do
      {:ok, _} =
        Tournaments.create_player(t.id, %{
          "name" => "Player #{i}",
          "fide_rating" => to_string(2200 - i * 50)
        })
    end

    Tournaments.get_tournament!(t.id)
  end

  defp paired(scope, attrs \\ %{}) do
    t = tournament(scope, 4, attrs)
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

  defp fide_player(attrs \\ %{}) do
    Repo.insert!(
      struct!(
        %FidePlayer{
          fide_id: 4_000_001,
          name: "Zylvester, Anna",
          federation: "BEL",
          sex: "F",
          title: "WFM",
          standard_rating: 2105,
          rapid_rating: 2050,
          blitz_rating: 2000,
          birth_year: 1990
        },
        attrs
      )
    )
  end

  defp member(attrs \\ %{}) do
    Repo.insert!(
      struct!(
        %Member{
          national_id: "77001",
          last_name: "Quaxley",
          first_name: "Bram",
          national_rating: 1830,
          club_name: "Test Club",
          club_number: 999,
          federation: "BEL",
          birth_year: 2001,
          sex: "m"
        },
        attrs
      )
    )
  end

  defp bel_lookup_on(scope) do
    {:ok, _user} = Features.set_enabled(scope.user, ["bel_player_lookup"])
    :ok
  end

  setup do
    owner = user_scope_fixture()
    %{owner: owner, token: token(owner)}
  end

  ## ---------- a new tournament ----------

  describe "tournament options" do
    test "the form's systems, FIDE only without the Belgian list, and the defaults", %{
      conn: conn,
      token: token
    } do
      body = conn |> phone(token) |> get(@api <> "/tournament-options") |> json_response(200)

      assert Enum.map(body["systems"], & &1["id"]) == Tournament.pairing_systems()
      assert Enum.map(body["player_sources"], & &1["id"]) == ["fide"]
      assert body["defaults"]["system"] == "swiss"
      assert body["defaults"]["rounds_count"] == 9
      assert body["defaults"]["rated"] == false
    end

    test "the Belgian list is offered once it is on and has members", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      bel_lookup_on(owner)

      body = conn |> phone(token) |> get(@api <> "/tournament-options") |> json_response(200)
      assert Enum.map(body["player_sources"], & &1["id"]) == ["fide"]

      member()
      body = conn |> phone(token) |> get(@api <> "/tournament-options") |> json_response(200)
      assert Enum.map(body["player_sources"], & &1["id"]) == ["fide", "bel"]
    end
  end

  describe "creating a tournament" do
    test "creates as the form does, owned by the phone's account", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      body =
        conn
        |> phone(token)
        |> post(@api <> "/tournaments", %{
          "tournament" => %{
            "name" => "Phone Open",
            "start_date" => "2026-12-01",
            "end_date" => "2026-12-03",
            "city" => "Gent",
            "venue" => "Town hall",
            "system" => "swiss",
            "rounds_count" => 5,
            "time_control" => "90min+30sec/move",
            "federation" => "bel",
            "rated" => true
          }
        })
        |> json_response(201)

      line = body["tournament"]
      assert line["name"] == "Phone Open"
      assert line["role"] == "owner"
      assert line["rounds_count"] == 5
      assert line["start_date"] == "2026-12-01"
      assert line["end_date"] == "2026-12-03"

      t = Tournaments.get_tournament!(line["id"])
      assert t.user_id == owner.user.id
      assert t.type == "swiss"
      assert t.venue == "Town hall"
      assert t.federation == "BEL"
      assert t.rate_of_play == "90min+30sec/move"
      assert t.fide_homologated
      assert t.round_dates == ~w(2026-12-01 2026-12-01 2026-12-01 2026-12-01 2026-12-03)
      assert t.round_one_absentees_late

      assert Enum.any?(Audit.list_for_tournament(t.id), &(&1.action == "tournament.created"))
    end

    test "a missing name is refused with a sentence", %{conn: conn, token: token} do
      assert %{"error" => "invalid", "message" => message} =
               conn
               |> phone(token)
               |> post(@api <> "/tournaments", %{"tournament" => %{"system" => "swiss"}})
               |> json_response(422)

      assert message =~ ~r/name/i
    end

    test "an unknown system, a bad date and an end before the start are refused", %{
      conn: conn,
      token: token
    } do
      for attrs <- [
            %{"name" => "X", "system" => "lottery"},
            %{"name" => "X", "start_date" => "1 December"},
            %{"name" => "X", "start_date" => "2026-12-03", "end_date" => "2026-12-01"}
          ] do
        assert %{"error" => _code, "message" => _sentence} =
                 conn
                 |> phone(token)
                 |> post(@api <> "/tournaments", %{"tournament" => attrs})
                 |> json_response(422)
      end
    end

    test "the hosted edition's limit applies", %{conn: conn, owner: owner, token: token} do
      max = Application.get_env(:pairings_engine, :max_tournaments_per_account)

      on_exit(fn ->
        if max,
          do: Application.put_env(:pairings_engine, :max_tournaments_per_account, max),
          else: Application.delete_env(:pairings_engine, :max_tournaments_per_account)
      end)

      _ = tournament(owner, 0)
      Application.put_env(:pairings_engine, :max_tournaments_per_account, 1)

      assert %{"error" => "tournament_quota"} =
               conn
               |> phone(token)
               |> post(@api <> "/tournaments", %{"tournament" => %{"name" => "One too many"}})
               |> json_response(409)
    end
  end

  ## ---------- players from the lists ----------

  describe "player search" do
    test "finds FIDE players with what a pick fills in", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      t = tournament(owner)
      fide_player()

      body =
        conn
        |> phone(token)
        |> get(@api <> "/tournaments/#{t.id}/player-search", %{"q" => "zylv"})
        |> json_response(200)

      assert [row] = body["results"]
      assert row["source"] == "fide"
      assert row["fide_id"] == 4_000_001
      assert row["name"] == "Zylvester, Anna"
      assert row["sex"] == "w"
      assert row["title"] == "WFM"
      assert row["fide_rating"] == 2105
      assert row["already_in"] == false
    end

    test "says when the player is already in", %{conn: conn, owner: owner, token: token} do
      t = tournament(owner)
      fide_player()

      {:ok, _} =
        Tournaments.create_player(t.id, %{"name" => "Zylvester, Anna", "fide_id" => 4_000_001})

      assert %{"results" => [%{"already_in" => true}]} =
               conn
               |> phone(token)
               |> get(@api <> "/tournaments/#{t.id}/player-search", %{"q" => "zylvester"})
               |> json_response(200)
    end

    test "searches the Belgian list when it is on", %{conn: conn, owner: owner, token: token} do
      t = tournament(owner)
      bel_lookup_on(owner)
      member()

      body =
        conn
        |> phone(token)
        |> get(@api <> "/tournaments/#{t.id}/player-search", %{"q" => "quax", "source" => "bel"})
        |> json_response(200)

      assert [row] = body["results"]
      assert row["source"] == "bel"
      assert row["national_id"] == "77001"
      assert row["name"] == "Quaxley, Bram"
      assert row["national_rating"] == 1830
      assert row["club"] == "Test Club"
    end

    test "refuses a short query, an unavailable list, an arbiter and a stranger", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      t = tournament(owner)
      path = @api <> "/tournaments/#{t.id}/player-search"

      assert %{"error" => "query_too_short"} =
               conn |> phone(token) |> get(path, %{"q" => "zy"}) |> json_response(422)

      assert %{"error" => "unknown_source"} =
               conn
               |> phone(token)
               |> get(path, %{"q" => "quax", "source" => "bel"})
               |> json_response(422)

      arbiter = enlist(owner, t, "arbiter")

      assert %{"error" => "arbiter_role"} =
               conn |> phone(token(arbiter)) |> get(path, %{"q" => "zylv"}) |> json_response(403)

      stranger = user_scope_fixture()

      assert %{"error" => "tournament_not_found"} =
               conn |> phone(token(stranger)) |> get(path, %{"q" => "zylv"}) |> json_response(404)
    end
  end

  describe "adding from a list" do
    test "a FIDE pick fills the player as the add form would", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      t = tournament(owner)
      fide_player()

      body =
        conn
        |> phone(token)
        |> post(@api <> "/tournaments/#{t.id}/players", %{
          "player" => %{"from" => %{"source" => "fide", "fide_id" => 4_000_001}}
        })
        |> json_response(201)

      p = body["player"]
      assert p["name"] == "Zylvester, Anna"
      assert p["fide_id"] == 4_000_001
      assert p["fide_rating"] == 2105
      assert p["sex"] == "w"
      assert p["title"] == "WFM"
      assert p["present"] == true

      assert Enum.any?(Audit.list_for_tournament(t.id), &(&1.action == "player.created"))
    end

    test "a member pick fills the national details", %{conn: conn, owner: owner, token: token} do
      t = tournament(owner)
      bel_lookup_on(owner)
      member()

      body =
        conn
        |> phone(token)
        |> post(@api <> "/tournaments/#{t.id}/players", %{
          "player" => %{"from" => %{"source" => "bel", "national_id" => "77001"}}
        })
        |> json_response(201)

      assert body["player"]["name"] == "Quaxley, Bram"
      assert body["player"]["club"] == "Test Club"
      assert body["player"]["national_rating"] == 1830
      assert Tournaments.get_player(t.id, body["player"]["id"]).national_id == "77001"
    end

    test "a duplicate, an unknown id and an unavailable list are refused", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      t = tournament(owner)
      fide_player()
      path = @api <> "/tournaments/#{t.id}/players"
      from = %{"player" => %{"from" => %{"source" => "fide", "fide_id" => 4_000_001}}}

      conn |> phone(token) |> post(path, from) |> json_response(201)

      assert %{"error" => "duplicate_player", "message" => _} =
               conn |> phone(token) |> post(path, from) |> json_response(422)

      assert %{"error" => "not_in_list"} =
               conn
               |> phone(token)
               |> post(path, %{"player" => %{"from" => %{"source" => "fide", "fide_id" => 9}}})
               |> json_response(404)

      member()

      assert %{"error" => "unknown_source"} =
               conn
               |> phone(token)
               |> post(path, %{
                 "player" => %{"from" => %{"source" => "bel", "national_id" => "77001"}}
               })
               |> json_response(422)
    end

    test "an archived tournament takes no player", %{conn: conn, owner: owner, token: token} do
      t = tournament(owner)
      fide_player()
      {:ok, _} = Tournaments.archive_tournament(t)

      assert %{"error" => "archived"} =
               conn
               |> phone(token)
               |> post(@api <> "/tournaments/#{t.id}/players", %{
                 "player" => %{"from" => %{"source" => "fide", "fide_id" => 4_000_001}}
               })
               |> json_response(409)
    end
  end

  ## ---------- check-in ----------

  describe "check-in" do
    test "present is the whole-event absence, and writable", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      t = tournament(owner)
      [p | _] = Tournaments.list_players(t.id)
      path = @api <> "/tournaments/#{t.id}/players/#{p.id}"

      body =
        conn
        |> phone(token)
        |> patch(path, %{"player" => %{"present" => false}})
        |> json_response(200)

      assert body["player"]["present"] == false
      assert Tournaments.get_player(t.id, p.id).absent

      body =
        conn
        |> phone(token)
        |> patch(path, %{"player" => %{"present" => true}})
        |> json_response(200)

      assert body["player"]["present"] == true
      refute Tournaments.get_player(t.id, p.id).absent
    end
  end

  ## ---------- byes ----------

  describe "byes" do
    test "the player list shows requested byes; the tournament its bye kinds", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      t = tournament(owner)
      [p | _] = Tournaments.list_players(t.id)
      {:ok, _} = Tournaments.update_player(p, %{"absent_rounds" => "2,3"})

      body = conn |> phone(token) |> get(@api <> "/tournaments/#{t.id}") |> json_response(200)
      assert [%{"id" => "absent"}] = body["tournament"]["bye_kinds"]

      %{"players" => players} =
        conn |> phone(token) |> get(@api <> "/tournaments/#{t.id}/players") |> json_response(200)

      row = Enum.find(players, &(&1["id"] == p.id))

      assert row["byes"] == [
               %{"round" => 2, "kind" => "absent"},
               %{"round" => 3, "kind" => "absent"}
             ]
    end

    test "replacing the requests writes absences and typed byes", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      t = tournament(owner, 4, %{"ask_bye_type" => true})
      [p | _] = Tournaments.list_players(t.id)

      body = conn |> phone(token) |> get(@api <> "/tournaments/#{t.id}") |> json_response(200)

      assert Enum.map(body["tournament"]["bye_kinds"], & &1["id"]) ==
               ~w(requested-half requested-zero full-point)

      body =
        conn
        |> phone(token)
        |> put(@api <> "/tournaments/#{t.id}/players/#{p.id}/byes", %{
          "byes" => [
            %{"round" => 3, "kind" => "requested-zero"},
            %{"round" => 2, "kind" => "requested-half"}
          ]
        })
        |> json_response(200)

      assert body["player"]["byes"] == [
               %{"round" => 2, "kind" => "requested-half"},
               %{"round" => 3, "kind" => "requested-zero"}
             ]

      assert Tournaments.get_player(t.id, p.id).absent_rounds == "2,3"
      assert ByeTypes.stored(t.id, p.id) == %{2 => "requested-half", 3 => "requested-zero"}

      # Replacing: round 2 alone stays.
      body =
        conn
        |> phone(token)
        |> put(@api <> "/tournaments/#{t.id}/players/#{p.id}/byes", %{
          "byes" => [%{"round" => 2, "kind" => "requested-half"}]
        })
        |> json_response(200)

      assert body["player"]["byes"] == [%{"round" => 2, "kind" => "requested-half"}]
    end

    test "a paired round, an unknown kind, a bad list and an arbiter are refused", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      t = paired(owner)
      [p | _] = Tournaments.list_players(t.id)
      path = @api <> "/tournaments/#{t.id}/players/#{p.id}/byes"

      assert %{"error" => "round_paired", "message" => _} =
               conn
               |> phone(token)
               |> put(path, %{"byes" => [%{"round" => 1, "kind" => "absent"}]})
               |> json_response(422)

      assert %{"error" => "unknown_bye_kind"} =
               conn
               |> phone(token)
               |> put(path, %{"byes" => [%{"round" => 2, "kind" => "full-point"}]})
               |> json_response(422)

      assert %{"error" => "bad_request"} =
               conn
               |> phone(token)
               |> put(path, %{"byes" => [%{"round" => 9, "kind" => "absent"}]})
               |> json_response(400)

      assert %{"error" => "bad_request"} =
               conn |> phone(token) |> put(path, %{"byes" => "2"}) |> json_response(400)

      arbiter = enlist(owner, t, "arbiter")

      assert %{"error" => "arbiter_role"} =
               conn
               |> phone(token(arbiter))
               |> put(path, %{"byes" => [%{"round" => 2, "kind" => "absent"}]})
               |> json_response(403)

      assert Tournaments.get_player(t.id, p.id).absent_rounds == ""
    end

    test "a later round of a paired tournament is accepted", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      t = paired(owner)
      [p | _] = Tournaments.list_players(t.id)

      assert %{"player" => %{"byes" => [%{"round" => 3, "kind" => "absent"}]}} =
               conn
               |> phone(token)
               |> put(@api <> "/tournaments/#{t.id}/players/#{p.id}/byes", %{
                 "byes" => [%{"round" => 3, "kind" => "absent"}]
               })
               |> json_response(200)
    end

    test "an archived tournament takes no byes", %{conn: conn, owner: owner, token: token} do
      t = tournament(owner)
      [p | _] = Tournaments.list_players(t.id)
      {:ok, _} = Tournaments.archive_tournament(t)

      assert %{"error" => "archived"} =
               conn
               |> phone(token)
               |> put(@api <> "/tournaments/#{t.id}/players/#{p.id}/byes", %{
                 "byes" => [%{"round" => 2, "kind" => "absent"}]
               })
               |> json_response(409)
    end
  end

  ## ---------- sharing ----------

  describe "sharing" do
    test "an unpublished tournament has no results-site link", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      t = tournament(owner)
      body = conn |> phone(token) |> get(@api <> "/tournaments/#{t.id}") |> json_response(200)
      assert Map.has_key?(body["tournament"], "openresults_url")
      assert body["tournament"]["openresults_url"] == nil
    end
  end

  ## ---------- hall boxes ----------

  describe "board reports" do
    test "a board's report sits beside the result, mismatch in red", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      t = paired(owner)

      [board | _] =
        Tournaments.get_round(t.id, 1).pairings
        |> Enum.reject(&is_nil(&1.black_player_id))
        |> Enum.sort_by(& &1.board)

      board = Repo.get!(Pairing, board.id)
      {:ok, link, _secret} = BoardLink.create_link(owner, t)

      {:ok, _} =
        BoardLink.report(link, t, report_for(board, %{"status" => "finished", "result" => "1-0"}))

      round = fn ->
        conn
        |> phone(token)
        |> get(@api <> "/tournaments/#{t.id}/rounds/1")
        |> json_response(200)
        |> get_in(["round", "boards"])
        |> Enum.find(&(&1["id"] == board.id))
      end

      report = round.()["board_report"]
      assert report["status"] == "finished"
      assert report["result"] == "1-0"
      assert report["moves_count"] == 2
      assert report["mismatch"] == false
      assert report["updated_at"]

      board |> Ecto.Changeset.change(result: "0-1") |> Repo.update!()
      assert round.()["board_report"]["mismatch"] == true
      # The board never entered it.
      assert Repo.get!(Pairing, board.id).result == "0-1"
    end

    test "a board with nothing reported says null", %{conn: conn, owner: owner, token: token} do
      t = paired(owner)

      boards =
        conn
        |> phone(token)
        |> get(@api <> "/tournaments/#{t.id}/rounds/1")
        |> json_response(200)
        |> get_in(["round", "boards"])

      assert Enum.all?(boards, &is_nil(&1["board_report"]))
    end
  end

  describe "board links" do
    test "make, list and withdraw a code", %{conn: conn, owner: owner, token: token} do
      t = tournament(owner)
      path = @api <> "/tournaments/#{t.id}/board-links"

      body = conn |> phone(token) |> post(path, %{}) |> json_response(201)
      assert %{"link" => %{"id" => id, "kind" => "tournament", "reach" => "server"}} = body
      assert body["code"] =~ "#oplt_"

      [_address, secret] = String.split(body["code"], "#")
      assert {:ok, %Link{id: ^id}} = BoardLink.authenticate(secret)

      %{"links" => links} = conn |> phone(token) |> get(path) |> json_response(200)
      assert [%{"id" => ^id, "created_at" => _, "last_seen_at" => nil}] = links
      refute Enum.any?(links, &Map.has_key?(&1, "code"))

      assert conn |> phone(token) |> delete(path <> "/#{id}") |> response(204)
      assert :error = BoardLink.authenticate(secret)

      assert %{"error" => "link_not_found"} =
               conn |> phone(token) |> delete(path <> "/#{id}") |> json_response(404)
    end

    test "the ceiling, an archived tournament, an arbiter and a stranger are refused", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      t = tournament(owner)
      path = @api <> "/tournaments/#{t.id}/board-links"

      for _ <- 1..BoardLink.max_links(), do: {:ok, _, _} = BoardLink.create_link(owner, t)

      assert %{"error" => "too_many_codes", "message" => _} =
               conn |> phone(token) |> post(path, %{}) |> json_response(409)

      arbiter = enlist(owner, t, "arbiter")

      assert %{"error" => "arbiter_role"} =
               conn |> phone(token(arbiter)) |> get(path) |> json_response(403)

      assert %{"error" => "tournament_not_found"} =
               conn |> phone(token(user_scope_fixture())) |> post(path, %{}) |> json_response(404)

      other = tournament(owner, 0)
      {:ok, _} = Tournaments.archive_tournament(other)

      assert %{"error" => "archived"} =
               conn
               |> phone(token)
               |> post(@api <> "/tournaments/#{other.id}/board-links", %{})
               |> json_response(409)
    end

    test "another tournament's code cannot be withdrawn from this one", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      t = tournament(owner, 0)
      other = tournament(owner, 0)
      {:ok, link, _secret} = BoardLink.create_link(owner, other)

      assert %{"error" => "link_not_found"} =
               conn
               |> phone(token)
               |> delete(@api <> "/tournaments/#{t.id}/board-links/#{link.id}")
               |> json_response(404)

      assert Repo.get(Link, link.id)
    end
  end
end
