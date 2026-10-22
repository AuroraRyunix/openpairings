defmodule PairingsEngineWeb.ManubriumContractTest do
  @moduledoc """
  The provider's half of `priv/contracts/manubrium-v1/`, the contract the
  Manubrium app vendors and checks itself against: every answer the API
  gives is checked against its schema as the controllers really produce it,
  every example against its schema, every request example is sent to the
  real endpoint and taken, and `index.json` lists the directory exactly.

  A field added to an answer fails here until the schema has it - which is
  the point: the app learns of it from the contract, not from a phone in a
  playing hall.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import PairingsEngine.AccountsFixtures
  import PairingsEngine.BoardLinkFixtures, only: [report_for: 2]
  import PairingsEngineWeb.ContractHelpers

  alias PairingsEngine.{BoardLink, Manubrium, Mobile, Repo, Tournaments}
  alias PairingsEngine.Fide.FidePlayer
  alias PairingsEngine.Mobile.Sync
  alias PairingsEngine.Tournaments.{Collaborator, Pairing}

  @contract "manubrium-v1"
  @api "/api/manubrium/v1"

  # Every request example, and so every one the tests below must send.
  @request_examples ~w(
    board-link-create-request.json
    byes-request.json
    connect-request.json
    edit-request.json
    expected-request.json
    finish-edits-request.json
    incident-update-request.json
    pair-request.json
    photo-request.json
    player-create-request.from-fide.json
    player-create-request.json
    player-update-request.json
    publish-request.json
    settings-request.json
    sync-request.json
    tournament-create-request.json
  )

  ## ---------- fixtures ----------

  defp tournament(scope, players) do
    dates = for r <- 1..3, do: Date.to_iso8601(Date.add(~D[2026-11-01], (r - 1) * 7))

    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "Contract Open #{System.unique_integer([:positive])}",
        "type" => "swiss",
        "rounds_count" => "3",
        "round_dates" => dates,
        "start_date" => hd(dates),
        "end_date" => List.last(dates),
        "city" => "Ghent"
      })

    for i <- 1..players do
      {:ok, _} =
        Tournaments.create_player(t.id, %{
          "name" => "Player #{i}",
          "fide_rating" => to_string(2200 - i * 50),
          "federation" => "BEL"
        })
    end

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
    |> recycle()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("accept", "application/json")
  end

  defp games(t, n \\ 1) do
    Tournaments.get_round(t.id, n).pairings
    |> Enum.reject(&(is_nil(&1.white_player_id) or is_nil(&1.black_player_id)))
    |> Enum.sort_by(& &1.board)
  end

  # A result entered on `/m` by a no-account code: Manubrium Lite.
  defp lite_result(t, p, result) do
    {:ok, e} = Mobile.create_enrollment(t.id, level: "helper", label: "Hall phone")

    {:ok, [%{status: :saved}]} =
      Sync.submit(e.id, [
        %{
          "cid" => Ecto.UUID.generate(),
          "enrollment" => e.id,
          "kind" => "result",
          "round" => 1,
          "pairing" => p.id,
          "board" => p.board,
          "white" => p.white_player_id,
          "black" => p.black_player_id,
          "result" => result,
          "expected" => ""
        }
      ])
  end

  # A request example with the ids of this test's own tournament put in.
  defp request(file, fun \\ & &1), do: @contract |> example(file) |> fun.()

  setup do
    owner = user_scope_fixture()
    %{owner: owner, token: token(owner)}
  end

  ## ---------- the files ----------

  describe "the contract's files" do
    test "index.json lists exactly what is there" do
      assert_index!(@contract)
    end

    test "every example is valid against its schema" do
      examples = examples(@contract)
      assert examples != []

      for {file, schema, data} <- examples do
        assert File.exists?(Path.join(dir(@contract), schema)), "#{file}: no #{schema}"
        assert_valid!(@contract, schema, data)
      end
    end

    test "every message has an example" do
      schemas =
        @contract
        |> files()
        |> Enum.filter(&String.ends_with?(&1, ".schema.json"))
        |> Enum.reject(&(&1 == "common.schema.json"))

      covered = @contract |> examples() |> Enum.map(&elem(&1, 1)) |> MapSet.new()

      for schema <- schemas, do: assert(schema in covered, "#{schema} has no example")
    end

    test "the request examples are the ones these tests send" do
      present =
        @contract
        |> examples()
        |> Enum.map(fn {"examples/" <> file, _schema, _data} -> file end)
        |> Enum.filter(&String.contains?(&1, "-request"))

      assert Enum.sort(present) == Enum.sort(@request_examples)
    end

    test "a schema that names a field the server never sends is caught" do
      # The guard on the guard: `additionalProperties: false` really bites.
      refute valid?(@contract, "board-verdict-response.schema.json", %{
               status: "cleared",
               extra: 1
             })

      refute valid?(@contract, "round-response.schema.json", %{round: %{}})
    end
  end

  ## ---------- the account ----------

  describe "the account" do
    test "connect, who am I, and a refusal", %{conn: conn, owner: owner} do
      {:ok, %{secret: secret}} = Manubrium.create_connect_code(owner, "http://test")
      body = request("connect-request.json", &Map.put(&1, "secret", secret))
      assert_valid!(@contract, "connect-request.schema.json", body)

      answer = conn |> post(@api <> "/connect", body) |> json_response(201)
      record_example(@contract, "connect-response", answer)

      refused = conn |> recycle() |> post(@api <> "/connect", body) |> json_response(401)
      record_example(@contract, "error.invalid-code", refused)

      me = conn |> phone(answer["token"]) |> get(@api <> "/me") |> json_response(200)
      record_example(@contract, "me-response", me)

      signed_out = conn |> phone(answer["token"]) |> delete(@api <> "/me")
      record_example(@contract, "sign-out-response", no_content(signed_out))
    end
  end

  ## ---------- tournaments and the hall ----------

  describe "a tournament, a round and the hall" do
    test "every answer on the way through a round", %{conn: conn, owner: owner, token: token} do
      options = conn |> phone(token) |> get(@api <> "/tournament-options") |> json_response(200)
      record_example(@contract, "tournament-options-response", options)

      created =
        conn
        |> phone(token)
        |> post(@api <> "/tournaments", request("tournament-create-request.json"))
        |> json_response(201)

      record_example(@contract, "tournament-create-response", created)
      assert created["tournament"]["name"] == "Autumn Open"

      # Five players: two boards and a bye.
      t = tournament(owner, 5)
      base = @api <> "/tournaments/#{t.id}"

      paired =
        conn
        |> phone(token)
        |> post(base <> "/rounds", request("pair-request.json"))
        |> json_response(201)

      assert_valid!(@contract, "round-response.schema.json", paired)
      t = Tournaments.get_tournament!(t.id)
      [b1, b2] = games(t)

      # A hall box reports a game in progress on board 1: three plies.
      {:ok, link, _secret} = BoardLink.create_link(owner, t)
      {:ok, _} = BoardLink.report(link, t, report_for(Repo.get!(Pairing, b1.id), %{}))
      # A Lite phone enters board 2.
      lite_result(t, b2, "1-0")

      round = conn |> phone(token) |> get(base <> "/rounds/1") |> json_response(200)
      record_example(@contract, "round-response", round)

      board = Enum.find(round["round"]["boards"], &(&1["id"] == b1.id))
      assert board["board_report"]["status"] == "live"
      # Full moves: 1.e4 e5 2.Nf3 has reached move 2.
      assert board["board_report"]["moves_count"] == 2

      assert Enum.find(round["round"]["boards"], &(&1["id"] == b2.id))["phone"]["state"] ==
               "unconfirmed"

      # A finished one, so the third status is seen too.
      {:ok, _} =
        BoardLink.report(
          link,
          t,
          report_for(Repo.get!(Pairing, b1.id), %{
            "seq" => 2,
            "status" => "finished",
            "result" => "0-1"
          })
        )

      finished = conn |> phone(token) |> get(base <> "/rounds/1") |> json_response(200)
      record_example(@contract, "round-response.board-finished", finished)

      tournament = conn |> phone(token) |> get(base) |> json_response(200)
      record_example(@contract, "tournament-response", tournament)

      arbiter = token(enlist(owner, t, "arbiter"))
      as_arbiter = conn |> phone(arbiter) |> get(base) |> json_response(200)
      record_example(@contract, "tournament-response.arbiter", as_arbiter)
      assert as_arbiter["tournament"]["next_round"] == nil

      list = conn |> phone(token) |> get(@api <> "/tournaments") |> json_response(200)
      record_example(@contract, "tournaments-response", list)

      # The queue: a result on board 1 and an incident there.
      entries =
        request("sync-request.json", fn %{"entries" => [result, incident]} ->
          %{
            "entries" => [
              Map.merge(result, %{
                "pairing" => b1.id,
                "board" => b1.board,
                "white" => b1.white_player_id,
                "black" => b1.black_player_id
              }),
              Map.merge(incident, %{"pairing" => b1.id, "board" => b1.board})
            ]
          }
        end)

      synced = conn |> phone(token) |> post(base <> "/sync", entries) |> json_response(200)
      record_example(@contract, "sync-response", synced)
      assert Enum.map(synced["results"], & &1["status"]) == ["saved", "saved"]

      # The Lite phone's result stands.
      confirm = request("expected-request.json")
      assert confirm["expected"] == "1-0"

      confirmed =
        conn
        |> phone(token)
        |> post(base <> "/rounds/1/boards/#{b2.id}/confirm", confirm)
        |> json_response(200)

      record_example(@contract, "board-verdict-response.confirmed", confirmed)

      # Clearing board 1 with a stale `expected`: the conflict.
      conflict =
        conn
        |> phone(token)
        |> post(base <> "/rounds/1/boards/#{b1.id}/clear", %{"expected" => "0-1"})
        |> json_response(409)

      record_example(@contract, "error.conflict", conflict)

      cleared =
        conn
        |> phone(token)
        |> post(base <> "/rounds/1/boards/#{b1.id}/clear", %{"expected" => "1-0"})
        |> json_response(200)

      record_example(@contract, "board-verdict-response", cleared)

      published =
        conn
        |> phone(token)
        |> put(base <> "/rounds/1/publish", request("publish-request.json"))
        |> json_response(200)

      record_example(@contract, "publish-response", published)

      standings = conn |> phone(token) |> get(base <> "/standings") |> json_response(200)
      record_example(@contract, "standings-response", standings)

      incidents = conn |> phone(token) |> get(base <> "/incidents") |> json_response(200)
      [%{"id" => incident_id}] = incidents["incidents"]

      photo =
        conn
        |> phone(token)
        |> post(base <> "/incidents/#{incident_id}/photo", request("photo-request.json"))
        |> json_response(201)

      record_example(@contract, "incident-response", photo)

      incidents = conn |> phone(token) |> get(base <> "/incidents?round=1") |> json_response(200)
      record_example(@contract, "incidents-response", incidents)

      amended =
        conn
        |> phone(token)
        |> patch(base <> "/incidents/#{incident_id}", request("incident-update-request.json"))
        |> json_response(200)

      assert_valid!(@contract, "incident-response.schema.json", amended)
      assert amended["incident"]["kind"] == "time_added"

      deleted = conn |> phone(token) |> delete(base <> "/incidents/#{incident_id}")
      record_example(@contract, "incident-delete-response", no_content(deleted))

      gone =
        conn
        |> phone(token)
        |> patch(base <> "/incidents/#{incident_id}", %{"note" => "again"})
        |> json_response(404)

      assert_valid!(@contract, "error.schema.json", gone)

      settings =
        conn
        |> phone(token)
        |> patch(base <> "/settings", request("settings-request.json"))
        |> json_response(200)

      record_example(@contract, "settings-response", settings)
      assert settings["settings"]["chief_arbiter"] == "IA Example"

      not_found =
        conn |> phone(token) |> get(@api <> "/tournaments/999999") |> json_response(404)

      record_example(@contract, "error", not_found)
    end

    test "standings in a Keizer tournament", %{conn: conn, owner: owner, token: token} do
      t = tournament(owner, 4)
      {:ok, t} = Tournaments.update_tournament(t, %{"pairing_system" => "keizer"})

      standings =
        conn
        |> phone(token)
        |> get(@api <> "/tournaments/#{t.id}/standings")
        |> json_response(200)

      record_example(@contract, "standings-response.keizer", standings)
    end
  end

  ## ---------- hand edits ----------

  describe "hand edits" do
    test "an edit, the question it may ask, and finishing", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      t = tournament(owner, 4)
      base = @api <> "/tournaments/#{t.id}"
      conn |> phone(token) |> post(base <> "/rounds", %{}) |> json_response(201)
      [b1, b2] = games(Tournaments.get_tournament!(t.id))

      edit =
        request("edit-request.json", fn body ->
          put_in(body, ["edit"], %{
            "kind" => "swap",
            "a" => b1.white_player_id,
            "b" => b2.white_player_id
          })
        end)

      assert_valid!(@contract, "edit-request.schema.json", edit)

      edited =
        case conn |> phone(token) |> post(base <> "/rounds/1/edits", edit) do
          %{status: 409} = asked ->
            question = json_response(asked, 409)
            record_example(@contract, "error.needs-acknowledgement", question)

            conn
            |> phone(token)
            |> post(base <> "/rounds/1/edits", Map.put(edit, "acknowledged", question["confirm"]))
            |> json_response(200)

          answered ->
            json_response(answered, 200)
        end

      assert_valid!(@contract, "round-response.schema.json", edited)
      assert edited["round"]["hand_edits"]["open"]

      # Without the PIBE acknowledged the checker may ask first.
      case conn |> phone(token) |> post(base <> "/rounds/1/edits/finish", %{}) do
        %{status: 409} = asked ->
          record_example(@contract, "error.checker", json_response(asked, 409))

          finished =
            conn
            |> phone(token)
            |> post(base <> "/rounds/1/edits/finish", request("finish-edits-request.json"))
            |> json_response(200)

          record_example(@contract, "finish-edits-response", finished)

        answered ->
          record_example(@contract, "finish-edits-response", json_response(answered, 200))
      end
    end
  end

  ## ---------- players ----------

  describe "players" do
    test "the list, a late entry, one from a list, a change and byes", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      t = tournament(owner, 4)
      base = @api <> "/tournaments/#{t.id}"
      conn |> phone(token) |> post(base <> "/rounds", %{}) |> json_response(201)

      added =
        conn
        |> phone(token)
        |> post(base <> "/players", request("player-create-request.json"))
        |> json_response(201)

      record_example(@contract, "player-response", added)

      Repo.insert!(%FidePlayer{
        fide_id: 4_000_001,
        name: "Zylvester, Anna",
        federation: "BEL",
        sex: "F",
        title: "WFM",
        standard_rating: 2105,
        rapid_rating: 2050,
        blitz_rating: 2000,
        birth_year: 1990
      })

      found =
        conn
        |> phone(token)
        |> get(
          base <> "/player-search?" <> URI.encode_query(%{"q" => "Zylv", "source" => "fide"})
        )
        |> json_response(200)

      record_example(@contract, "player-search-response", found)
      assert [%{"fide_id" => 4_000_001, "already_in" => false}] = found["results"]

      from_list =
        conn
        |> phone(token)
        |> post(base <> "/players", request("player-create-request.from-fide.json"))
        |> json_response(201)

      record_example(@contract, "player-response.from-fide", from_list)

      changed =
        conn
        |> phone(token)
        |> patch(
          base <> "/players/#{added["player"]["id"]}",
          request("player-update-request.json")
        )
        |> json_response(200)

      record_example(@contract, "player-response.updated", changed)
      refute changed["player"]["present"]

      %{"tournament" => %{"bye_kinds" => [%{"id" => kind} | _]}} =
        conn |> phone(token) |> get(base) |> json_response(200)

      byes =
        request("byes-request.json", fn body ->
          put_in(body, ["byes"], [%{"round" => 3, "kind" => kind}])
        end)

      byed =
        conn
        |> phone(token)
        |> put(base <> "/players/#{from_list["player"]["id"]}/byes", byes)
        |> json_response(200)

      record_example(@contract, "player-response.byes", byed)
      assert byed["player"]["byes"] == [%{"round" => 3, "kind" => kind}]

      players = conn |> phone(token) |> get(base <> "/players") |> json_response(200)
      record_example(@contract, "players-response", players)
    end
  end

  ## ---------- hall boxes ----------

  describe "hall-box codes" do
    test "make one with a name, list them, withdraw one", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      t = tournament(owner, 4)
      base = @api <> "/tournaments/#{t.id}"

      made =
        conn
        |> phone(token)
        |> post(base <> "/board-links", request("board-link-create-request.json"))
        |> json_response(201)

      record_example(@contract, "board-link-create-response", made)
      # The name the phone gave is the one listed.
      assert made["link"]["label"] == "Hall A, boards 1-6"

      plain = conn |> phone(token) |> post(base <> "/board-links", %{}) |> json_response(201)
      assert plain["link"]["label"] == "…" <> plain["link"]["hint"]

      links = conn |> phone(token) |> get(base <> "/board-links") |> json_response(200)
      record_example(@contract, "board-links-response", links)
      assert length(links["links"]) == 2

      revoked = conn |> phone(token) |> delete(base <> "/board-links/#{plain["link"]["id"]}")
      record_example(@contract, "board-link-revoke-response", no_content(revoked))

      again =
        conn
        |> phone(token)
        |> delete(base <> "/board-links/#{plain["link"]["id"]}")
        |> json_response(404)

      record_example(@contract, "error.link-not-found", again)
    end
  end

  describe "unpairing" do
    test "only the latest round, and it answers nothing", %{
      conn: conn,
      owner: owner,
      token: token
    } do
      t = tournament(owner, 4)
      base = @api <> "/tournaments/#{t.id}"

      conn |> phone(token) |> post(base <> "/rounds", %{}) |> json_response(201)

      for p <- games(Tournaments.get_tournament!(t.id)),
          do: {:ok, _} = Tournaments.update_pairing_result(p, "1-0")

      conn |> phone(token) |> post(base <> "/rounds", %{}) |> json_response(201)

      refused = conn |> phone(token) |> delete(base <> "/rounds/1") |> json_response(422)
      record_example(@contract, "error.refused", refused)

      unpaired = conn |> phone(token) |> delete(base <> "/rounds/2")
      record_example(@contract, "unpair-response", no_content(unpaired))
      refute Tournaments.get_round(t.id, 2)
    end
  end

  # A 204 described the only way JSON can: its status and its (empty) body.
  defp no_content(conn) do
    assert conn.status == 204
    %{"status" => conn.status, "body" => conn.resp_body}
  end
end
