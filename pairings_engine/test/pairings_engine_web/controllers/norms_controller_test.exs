defmodule PairingsEngineWeb.NormsControllerTest do
  use PairingsEngineWeb.ConnCase

  alias PairingsEngine.Tournaments

  setup :register_and_log_in_user

  @xlsx_content_type "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

  defp tournament_fixture(scope) do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{
        "name" => "Norms Test Open",
        "type" => "swiss",
        "federation" => "BEL",
        "start_date" => "2026-07-10",
        "end_date" => "2026-07-18"
      })

    {:ok, _player} =
      Tournaments.create_player(tournament.id, %{
        "name" => "Doe, Jane",
        "fide_rating" => "2000",
        "federation" => "BEL"
      })

    tournament
  end

  describe "GET /t/:id/norms/it3" do
    test "returns the filled IT3 workbook", %{conn: conn, scope: scope} do
      tournament = tournament_fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/norms/it3")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["#{@xlsx_content_type}; charset=utf-8"]
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
      assert disposition =~ ".xlsx"
      assert byte_size(conn.resp_body) > 0
    end

    test "404s for another user's tournament", %{conn: conn} do
      other_scope = PairingsEngine.AccountsFixtures.user_scope_fixture()
      tournament = tournament_fixture(other_scope)

      assert_error_sent 404, fn -> get(conn, ~p"/t/#{tournament.id}/norms/it3") end
    end
  end

  describe "GET /t/:id/norms/fa1 and /ia1" do
    test "returns the filled FA1 workbook with the candidate's name in the query", %{conn: conn, scope: scope} do
      tournament = tournament_fixture(scope)

      conn =
        get(conn, ~p"/t/#{tournament.id}/norms/fa1", %{
          "candidate" => %{"last_name" => "Smith", "first_name" => "Alice", "fide_id" => "123", "federation" => "NED"}
        })

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["#{@xlsx_content_type}; charset=utf-8"]
      assert byte_size(conn.resp_body) > 0
    end

    test "returns the filled IA1 workbook", %{conn: conn, scope: scope} do
      tournament = tournament_fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/norms/ia1")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["#{@xlsx_content_type}; charset=utf-8"]
    end
  end

  describe "GET /t/:id/norms/it4" do
    test "returns the filled IT4 workbook even with no norm candidates", %{conn: conn, scope: scope} do
      tournament = tournament_fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/norms/it4")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["#{@xlsx_content_type}; charset=utf-8"]
      assert byte_size(conn.resp_body) > 0
    end
  end
end
