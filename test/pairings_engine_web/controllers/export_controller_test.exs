defmodule PairingsEngineWeb.ExportControllerTest do
  use PairingsEngineWeb.ConnCase

  alias PairingsEngine.Repo
  alias Ainalrami.Trf
  alias PairingsEngine.Tournaments.{Tournament, Player, Round, Pairing}

  setup :register_and_log_in_user

  # 3 players, 2 paired rounds - mirrors PairingsEngine.TrfExportTest's fixture.
  defp fixture(scope) do
    {:ok, tournament} =
      PairingsEngine.Tournaments.create_tournament(scope, %{
        "name" => "Export Ctrl Test",
        "type" => "swiss",
        "round_dates" => ["2026-08-15", "2026-08-16", "2026-08-17", "2026-08-18", "2026-08-19"],
        "rounds_count" => "3"
      })

    alice = Repo.insert!(%Player{tournament_id: tournament.id, name: "Alice", pairing_number: 1})
    bob = Repo.insert!(%Player{tournament_id: tournament.id, name: "Bob", pairing_number: 2})

    r1 = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "finished"})
    r2 = Repo.insert!(%Round{tournament_id: tournament.id, number: 2, status: "finished"})

    Repo.insert!(%Pairing{
      round_id: r1.id,
      board: 1,
      white_player_id: alice.id,
      black_player_id: bob.id,
      result: "1-0"
    })

    Repo.insert!(%Pairing{
      round_id: r2.id,
      board: 1,
      white_player_id: bob.id,
      black_player_id: alice.id,
      result: "1/2-1/2"
    })

    {tournament, %{alice: alice, bob: bob}}
  end

  ## ---------- GET /t/:id/export/trf ----------

  describe "trf/2" do
    test "downloads a TRF16 text file with all paired rounds by default", %{
      conn: conn,
      scope: scope
    } do
      {tournament, _} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/export/trf")

      assert response_content_type(conn, :text) =~ "text/plain"

      # VCL.12 ("it is recommended that such export is done using UTF-8
      # encoding") - the response declares it explicitly, not just "the
      # bytes happen to be UTF-8": a downstream tool trusting only the
      # Content-Type header (not sniffing the bytes) still reads accented
      # names correctly.
      [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "charset=utf-8"

      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
      assert disposition =~ "S_export-ctrl-test_r1-2.trf"

      body = response(conn, 200)
      parsed = Trf.parse(body)
      assert length(parsed.players) == 2
      alice = Enum.find(parsed.players, &(String.trim(&1.name) == "Alice"))
      assert length(alice.games) == 2
    end

    test "?rounds=1 downloads only round 1's column", %{conn: conn, scope: scope} do
      {tournament, _} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/export/trf?rounds=1")

      parsed = conn |> response(200) |> Trf.parse()
      alice = Enum.find(parsed.players, &(String.trim(&1.name) == "Alice"))
      assert length(alice.games) == 1
      assert hd(alice.games).result == "1"
    end

    test "an invalid rounds param falls back to every round rather than erroring", %{
      conn: conn,
      scope: scope
    } do
      {tournament, _} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/export/trf?rounds=garbage")

      parsed = conn |> response(200) |> Trf.parse()
      alice = Enum.find(parsed.players, &(String.trim(&1.name) == "Alice"))
      assert length(alice.games) == 2
    end

    test "an inconsistent roster surfaces a clean flash + redirect, not a 500", %{
      conn: conn,
      scope: scope
    } do
      tournament =
        Repo.insert!(%Tournament{
          name: "Corrupt Ctrl",
          type: "swiss",
          rounds_count: 1,
          user_id: scope.user.id
        })

      a = Repo.insert!(%Player{tournament_id: tournament.id, name: "A", pairing_number: 1})
      x = Repo.insert!(%Player{tournament_id: tournament.id, name: "X", pairing_number: 2})
      y = Repo.insert!(%Player{tournament_id: tournament.id, name: "Y", pairing_number: 2})

      round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "finished"})

      Repo.insert!(%Pairing{
        round_id: round.id,
        board: 1,
        white_player_id: a.id,
        black_player_id: x.id,
        result: "1-0"
      })

      Repo.insert!(%Pairing{
        round_id: round.id,
        board: 2,
        white_player_id: a.id,
        black_player_id: y.id,
        result: "0-1"
      })

      conn = get(conn, ~p"/t/#{tournament.id}/export/trf")

      assert redirected_to(conn) == ~p"/t/#{tournament.id}/pairings"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Could not export TRF"
    end

    test "a tournament belonging to another user 404s", %{conn: conn} do
      other_scope = PairingsEngine.AccountsFixtures.user_scope_fixture()
      {tournament, _} = fixture(other_scope)

      assert_error_sent 404, fn -> get(conn, ~p"/t/#{tournament.id}/export/trf") end
    end

    ## ---------- filename convention: <X>_<fideid>_<slug>_<rounds>.trf ----------

    test "filename defaults to the S (standard) prefix, no FIDE ID segment, and covers all paired rounds",
         %{
           conn: conn,
           scope: scope
         } do
      {tournament, _} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/export/trf")

      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "S_export-ctrl-test_r1-2.trf"
    end

    test "filename uses the B/R prefix for blitz/rapid tournaments", %{conn: conn, scope: scope} do
      {tournament, _} = fixture(scope)

      {:ok, tournament} =
        PairingsEngine.Tournaments.update_tournament(tournament, %{"standard" => "blitz"})

      conn = get(conn, ~p"/t/#{tournament.id}/export/trf")
      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "B_export-ctrl-test_r1-2.trf"

      {:ok, tournament} =
        PairingsEngine.Tournaments.update_tournament(tournament, %{"standard" => "rapid"})

      conn = get(conn, ~p"/t/#{tournament.id}/export/trf")
      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "R_export-ctrl-test_r1-2.trf"
    end

    test "filename includes the resolved FIDE ID and narrows the rounds descriptor with ?rounds=",
         %{
           conn: conn,
           scope: scope
         } do
      {tournament, _} = fixture(scope)

      {:ok, tournament} =
        PairingsEngine.Tournaments.update_tournament(tournament, %{
          "fide_tournament_id" => "12345"
        })

      conn = get(conn, ~p"/t/#{tournament.id}/export/trf?rounds=1")
      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "S_12345_export-ctrl-test_r1.trf"
    end
  end

  ## ---------- GET /t/:id/export/pgn ----------

  describe "pgn/2" do
    test "downloads a PGN text file with every round by default", %{conn: conn, scope: scope} do
      {tournament, _} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/export/pgn")

      [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/x-chess-pgn"
      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
      assert disposition =~ "export-ctrl-test.pgn"

      body = response(conn, 200)
      assert body =~ ~s([Round "1"])
      assert body =~ ~s([Round "2"])
      assert body =~ ~s([White "Alice"])
    end

    test "?round=1 downloads only round 1's game", %{conn: conn, scope: scope} do
      {tournament, _} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/export/pgn?round=1")

      body = response(conn, 200)
      assert body =~ ~s([Round "1"])
      refute body =~ ~s([Round "2"])
    end

    test "?board=1 adds a [Board] tag; omitted leaves it off", %{conn: conn, scope: scope} do
      {tournament, _} = fixture(scope)

      without = get(conn, ~p"/t/#{tournament.id}/export/pgn?round=1") |> response(200)
      refute without =~ "[Board "

      with_board = get(conn, ~p"/t/#{tournament.id}/export/pgn?round=1&board=1") |> response(200)
      assert with_board =~ "[Board "
    end

    test "an invalid round param falls back to every round rather than erroring", %{
      conn: conn,
      scope: scope
    } do
      {tournament, _} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/export/pgn?round=garbage")

      body = response(conn, 200)
      assert body =~ ~s([Round "1"])
      assert body =~ ~s([Round "2"])
    end

    test "a tournament belonging to another user 404s", %{conn: conn} do
      other_scope = PairingsEngine.AccountsFixtures.user_scope_fixture()
      {tournament, _} = fixture(other_scope)

      assert_error_sent 404, fn -> get(conn, ~p"/t/#{tournament.id}/export/pgn") end
    end
  end

  ## ---------- GET /t/:id/export/swar ----------

  describe "swar/2" do
    # The .swar download belongs to the Belgian pack and the route refuses it
    # for an account that has not switched it on - see `PairingsEngine.Features`.
    setup :enable_federation_features

    test "downloads a .swar binary that SwarImport.parse/1 can read back", %{
      conn: conn,
      scope: scope
    } do
      {tournament, _} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/export/swar")

      [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/octet-stream"
      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
      assert disposition =~ "export-ctrl-test.swar"

      body = response(conn, 200)
      assert {:ok, parsed} = PairingsEngine.Federations.BEL.SwarImport.parse(body)
      assert parsed.version == "v7.00"
      assert parsed.tournament.name == "Export Ctrl Test"
      assert length(parsed.players) == 2
    end

    test "a tournament belonging to another user 404s", %{conn: conn} do
      other_scope = PairingsEngine.AccountsFixtures.user_scope_fixture()
      {tournament, _} = fixture(other_scope)

      assert_error_sent 404, fn -> get(conn, ~p"/t/#{tournament.id}/export/swar") end
    end
  end

  ## ---------- GET /t/:id/export/swar_html ----------

  describe "swar_html/2" do
    # Belongs to the Belgian pack, same as swar/2 above - the route refuses
    # it for an account that has not switched it on.
    setup :enable_federation_features

    test "downloads a SWAR-compatible HTML results page, named after its guid", %{
      conn: conn,
      scope: scope
    } do
      {tournament, _} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/export/swar_html")

      [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "text/html"
      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"

      body = response(conn, 200)
      reloaded = PairingsEngine.Tournaments.get_tournament!(tournament.id)
      assert is_binary(reloaded.swar_guid) and reloaded.swar_guid != ""
      assert disposition =~ "#{reloaded.swar_guid}.html"
      assert body =~ "<meta name='Guid' content='#{reloaded.swar_guid}'>"
      assert body =~ "Export Ctrl Test"
    end

    test "a tournament belonging to another user 404s", %{conn: conn} do
      other_scope = PairingsEngine.AccountsFixtures.user_scope_fixture()
      {tournament, _} = fixture(other_scope)

      assert_error_sent 404, fn -> get(conn, ~p"/t/#{tournament.id}/export/swar_html") end
    end
  end

  describe "swar_html/2 - feature switched off" do
    test "refused (403), same as the .swar download, for an account that has not enabled it",
         %{conn: conn, scope: scope} do
      {tournament, _} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/export/swar_html")

      assert response(conn, 403)
    end
  end

  ## ---------- GET /t/:id/export/json and /export/tournaments.json ----------

  describe "json/2" do
    test "downloads a JSON backup of a single tournament", %{conn: conn, scope: scope} do
      {tournament, _} = fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/export/json")

      assert response_content_type(conn, :json) =~ "application/json"
      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "export-ctrl-test.json"

      body = conn |> response(200) |> Jason.decode!()
      assert body["format"] == "openpairings-export"
      assert [t_data] = body["tournaments"]
      assert t_data["tournament"]["name"] == "Export Ctrl Test"
    end

    test "a tournament belonging to another user 404s", %{conn: conn} do
      other_scope = PairingsEngine.AccountsFixtures.user_scope_fixture()
      {tournament, _} = fixture(other_scope)

      assert_error_sent 404, fn -> get(conn, ~p"/t/#{tournament.id}/export/json") end
    end

    # The slug's character class is ASCII-only, so a name written entirely in
    # a non-Latin script reduced to "" and the download came out named
    # ".json" - a stem-less dotfile some browsers and file managers hide.
    test "a name with no Latin characters falls back to the tournament id", %{
      conn: conn,
      scope: scope
    } do
      {tournament, _} = fixture(scope)

      {:ok, tournament} =
        PairingsEngine.Tournaments.update_tournament(tournament, %{"name" => "大会"})

      conn = get(conn, ~p"/t/#{tournament.id}/export/json")

      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "tournament-#{tournament.id}.json"
      refute disposition =~ ~s(filename=".json")
    end
  end

  describe "all_json/2" do
    test "downloads a JSON backup of every tournament the current user owns", %{
      conn: conn,
      scope: scope
    } do
      {t1, _} = fixture(scope)

      other_scope = PairingsEngine.AccountsFixtures.user_scope_fixture()
      fixture(other_scope)

      conn = get(conn, ~p"/export/tournaments.json")

      assert response_content_type(conn, :json) =~ "application/json"
      body = conn |> response(200) |> Jason.decode!()
      names = Enum.map(body["tournaments"], & &1["tournament"]["name"])
      assert names == [t1.name]
    end
  end
end
