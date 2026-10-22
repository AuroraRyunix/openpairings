defmodule PairingsEngineWeb.AlnaslLinkContractTest do
  @moduledoc """
  The provider's half of `priv/contracts/alnasl-link-v1/`: the board link
  (`/api/boards/v1`, docs/board-link-api.md) a hall box such as Alnasl calls.
  Every answer is checked against its schema as the controller really
  builds it, every example against its schema, every request example is
  sent and taken, and `index.json` lists the directory exactly.

  The box always calls; OpenPairings never calls the box, so there is no
  message the other way to hold to a contract.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import PairingsEngine.AccountsFixtures
  import PairingsEngine.BoardLinkFixtures
  import PairingsEngineWeb.ContractHelpers

  alias PairingsEngine.{BoardLink, RateLimit}

  @contract "alnasl-link-v1"

  @request_examples ~w(
    box-request.json
    games-request.json
    games-request.single.json
    grant-request.json
  )

  setup do
    RateLimit.clear(:board_link_auth, "127.0.0.1")
    on_exit(fn -> RateLimit.clear(:board_link_auth, "127.0.0.1") end)

    scope = user_scope_fixture()
    fixture = paired_tournament(scope)
    {:ok, link, secret} = BoardLink.create_link(scope, fixture.tournament)

    fixture |> Map.put(:scope, scope) |> Map.put(:link, link) |> Map.put(:secret, secret)
  end

  defp box(conn, secret) do
    conn
    |> recycle()
    |> put_req_header("authorization", "Bearer " <> secret)
    |> put_req_header("x-board-box", "Hall A")
    |> put_req_header("x-board-box-version", "0.5.6")
  end

  # A report example made about this test's own boards.
  defp about(report, pairing, seq) do
    Map.merge(report, %{
      "game" => pairing.game_uid,
      "white" => pairing.white_player_id,
      "black" => pairing.black_player_id,
      "seq" => seq
    })
  end

  describe "the contract's files" do
    test "index.json lists exactly what is there" do
      assert_index!(@contract)
    end

    test "every example is valid against its schema, and every message has one" do
      examples = examples(@contract)

      for {file, schema, data} <- examples do
        assert File.exists?(Path.join(dir(@contract), schema)), "#{file}: no #{schema}"
        assert_valid!(@contract, schema, data)
      end

      covered = MapSet.new(examples, &elem(&1, 1))

      for schema <- files(@contract),
          String.ends_with?(schema, ".schema.json"),
          schema != "common.schema.json",
          do: assert(schema in covered, "#{schema} has no example")
    end

    test "the request examples are the ones these tests send" do
      present =
        for {"examples/" <> file, _schema, _data} <- examples(@contract),
            String.contains?(file, "-request"),
            do: file

      assert Enum.sort(present) == Enum.sort(@request_examples)
    end

    test "the report statuses are the three the Manubrium contract shows" do
      # The box's `status` reaches the app as `board_report.status`: one list.
      box = example_enum(@contract, "common.schema.json", ["definitions", "game_status", "enum"])

      app =
        example_enum("manubrium-v1", "common.schema.json", [
          "definitions",
          "board_report",
          "oneOf",
          Access.at(1),
          "properties",
          "status",
          "enum"
        ])

      assert box == app
      assert box == PairingsEngine.BoardLink.Game.statuses()
    end
  end

  defp example_enum(contract, file, path) do
    contract |> dir() |> Path.join(file) |> File.read!() |> Jason.decode!() |> get_in(path)
  end

  describe "a box's conversation" do
    test "listing, box, document, reports and refusals", %{
      conn: conn,
      tournament: t,
      boards: [b1, b2],
      secret: secret
    } do
      listing = conn |> box(secret) |> get(~p"/api/boards/v1/link") |> json_response(200)
      record_example(@contract, "link-response", listing)

      said =
        example(@contract, "box-request.json")
        |> Map.put("boards", %{to_string(t.id) => 2})

      told = conn |> box(secret) |> post(~p"/api/boards/v1/box", said) |> json_response(200)
      record_example(@contract, "box-response", told)

      document =
        conn |> box(secret) |> get(~p"/api/boards/v1/tournaments/#{t.id}") |> json_response(200)

      record_example(@contract, "tournament-response", document)

      %{"games" => [live, waiting]} = example(@contract, "games-request.json")
      reports = %{"games" => [about(live, b1, 41), about(waiting, b2, 1)]}

      answered =
        conn
        |> box(secret)
        |> post(~p"/api/boards/v1/tournaments/#{t.id}/games", reports)
        |> json_response(200)

      record_example(@contract, "games-response", answered)
      assert Enum.map(answered["results"], & &1["applied"]) == [true, true]

      # The same again: duplicates, and one game whose colours are the
      # other way round.
      turned = %{
        about(live, b1, 41)
        | "white" => b1.black_player_id,
          "black" => b1.white_player_id
      }

      mixed =
        conn
        |> box(secret)
        |> post(~p"/api/boards/v1/tournaments/#{t.id}/games", %{
          "games" => [about(waiting, b2, 1), turned]
        })
        |> json_response(200)

      record_example(@contract, "games-response.mixed", mixed)
      assert [%{"reason" => "duplicate"}, %{"error" => "pairing_changed"}] = mixed["results"]

      single = example(@contract, "games-request.single.json") |> about(b1, 63)

      one =
        conn
        |> box(secret)
        |> post(~p"/api/boards/v1/tournaments/#{t.id}/games", single)
        |> json_response(200)

      record_example(@contract, "games-response.single", one)

      refused =
        conn
        |> box(secret)
        |> post(~p"/api/boards/v1/tournaments/#{t.id}/games", %{
          single
          | "white" => b1.black_player_id,
            "black" => b1.white_player_id
        })
        |> json_response(409)

      record_example(@contract, "error.pairing-changed", refused)

      gone =
        conn |> box(secret) |> get(~p"/api/boards/v1/tournaments/999999") |> json_response(404)

      record_example(@contract, "error", gone)

      unauthorized =
        conn |> box("oplt_" <> String.duplicate("x", 43)) |> get(~p"/api/boards/v1/link")

      record_example(@contract, "error.unauthorized", json_response(unauthorized, 401))
    end

    test "connecting an account: the grant", %{conn: conn} do
      user = user_fixture()
      scope = PairingsEngine.Accounts.Scope.for_user(user)
      fixture = paired_tournament(scope)

      allowed =
        conn
        |> log_in_user(user)
        |> post(~p"/boards/connect", %{
          "return_to" => "https://hall.example.org/setup/openpairings/callback",
          "state" => "s-123",
          "box" => "Alnasl - Hall A",
          "decision" => "allow"
        })

      grant =
        allowed
        |> redirected_to(302)
        |> URI.parse()
        |> Map.get(:query)
        |> URI.decode_query()
        |> Map.fetch!("grant")

      body = example(@contract, "grant-request.json") |> Map.put("grant", grant)
      answer = build_conn() |> post(~p"/api/boards/v1/grant", body) |> json_response(200)
      record_example(@contract, "grant-response", answer)

      [_root, secret] = String.split(answer["code"], "#", parts: 2)
      listing = build_conn() |> box(secret) |> get(~p"/api/boards/v1/link") |> json_response(200)
      record_example(@contract, "link-response.account", listing)
      assert [%{"id" => id}] = listing["tournaments"]
      assert id == fixture.tournament.id

      again = build_conn() |> post(~p"/api/boards/v1/grant", body) |> json_response(401)
      record_example(@contract, "error.invalid-grant", again)
    end
  end
end
