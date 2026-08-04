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

    test "an arbiter beyond the 4 built-in deputy slots is in the download (real template row-insertion)",
         %{conn: conn, scope: scope} do
      tournament = tournament_fixture(scope)

      {:ok, tournament} =
        Tournaments.update_tournament(tournament, %{
          "officials" => %{
            "extra_arbiters_count" => "1",
            "arbiter1_name" => "Cornet, Luc",
            "arbiter1_fide_id" => "205494"
          }
        })

      conn = get(conn, ~p"/t/#{tournament.id}/norms/it3")

      assert conn.status == 200
      {:ok, members} = :zip.extract(conn.resp_body, [:memory])
      xml = Enum.map_join(members, fn {_name, bin} -> bin end)

      assert xml =~ "205494"
      assert xml =~ "CORNET, Luc"
    end
  end

  describe "GET /t/:id/norms/fa1 and /ia1" do
    test "returns the filled FA1 workbook with the candidate's name in the query", %{
      conn: conn,
      scope: scope
    } do
      tournament = tournament_fixture(scope)

      conn =
        get(conn, ~p"/t/#{tournament.id}/norms/fa1", %{
          "candidate" => %{
            "last_name" => "Smith",
            "first_name" => "Alice",
            "fide_id" => "123",
            "federation" => "NED"
          }
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
    test "returns the filled IT4 workbook even with no norm candidates", %{
      conn: conn,
      scope: scope
    } do
      tournament = tournament_fixture(scope)

      conn = get(conn, ~p"/t/#{tournament.id}/norms/it4")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["#{@xlsx_content_type}; charset=utf-8"]
      assert byte_size(conn.resp_body) > 0
    end
  end

  describe "combined reports (festival) — combine=/master= query params" do
    defp unzip_map(binary) do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "norms_controller_test_#{System.unique_integer([:positive])}.xlsx"
        )

      File.write!(tmp, binary)
      {:ok, entries} = :zip.unzip(String.to_charlist(tmp), [:memory])
      File.rm(tmp)
      Map.new(entries, fn {name, bin} -> {List.to_string(name), bin} end)
    end

    defp create_tournament(scope, attrs) do
      {:ok, tournament} =
        Tournaments.create_tournament(
          scope,
          Map.merge(
            %{"type" => "swiss", "start_date" => "2026-07-10", "end_date" => "2026-07-18"},
            attrs
          )
        )

      tournament
    end

    test "aggregates federations (union) across the combined tournaments, named/scheduled from the master",
         %{conn: conn, scope: scope} do
      open =
        create_tournament(scope, %{
          "name" => "Ghent Festival — Open",
          "federation" => "BEL",
          "round_dates" => ["2026-09-01", "2026-09-02", "2026-09-02"]
        })

      youth =
        create_tournament(scope, %{"name" => "Ghent Festival — Youth", "federation" => "BEL"})

      {:ok, _} =
        Tournaments.create_player(open.id, %{
          "name" => "Alpha, One",
          "fide_rating" => "2100",
          "federation" => "BEL"
        })

      {:ok, _} =
        Tournaments.create_player(open.id, %{
          "name" => "Bravo, Two",
          "fide_rating" => "2000",
          "federation" => "NED"
        })

      {:ok, _} =
        Tournaments.create_player(youth.id, %{"name" => "Charlie, Three", "federation" => "GER"})

      conn =
        get(conn, ~p"/t/#{open.id}/norms/it3", %{
          "combine" => "#{open.id},#{youth.id}",
          "master" => "#{open.id}"
        })

      assert conn.status == 200
      assert [disposition] = get_resp_header(conn, "content-disposition")
      # Filename is derived from the virtual ("... Festival") name.
      assert disposition =~ "ghent-festival-open-festival"

      members = unzip_map(conn.resp_body)
      sheet_xml = Map.fetch!(members, "xl/worksheets/sheet2.xml")

      assert sheet_xml =~
               ~r/<c r="B3"[^>]*t="inlineStr"><is><t xml:space="preserve">Ghent Festival — Open Festival<\/t><\/is><\/c>/

      # Schedule (B12) comes from the master's (open's) round_dates: two
      # distinct days, the second a double round -> "1-2".
      assert sheet_xml =~
               ~r/<c r="B12"[^>]*t="inlineStr"><is><t xml:space="preserve">1-2<\/t><\/is><\/c>/

      # Rated total across both tournaments: Alpha + Bravo = 2 (B27);
      # distinct federations BEL+NED = 2 (B28); host (BEL) = Alpha only = 1 (B29).
      assert sheet_xml =~ ~r/<c r="B27"[^>]*><v>2<\/v><\/c>/
      assert sheet_xml =~ ~r/<c r="B28"[^>]*><v>2<\/v><\/c>/
      assert sheet_xml =~ ~r/<c r="B29"[^>]*><v>1<\/v><\/c>/
    end

    test "master=<id> not the route id still drives the schedule/name", %{
      conn: conn,
      scope: scope
    } do
      # `open` (the route id) deliberately has no round_dates — if the
      # schedule field came from the route id instead of `master`, B12
      # would be left blank instead of showing youth's own schedule.
      open = create_tournament(scope, %{"name" => "Ghent Festival — Open", "federation" => "BEL"})

      youth =
        create_tournament(scope, %{
          "name" => "Ghent Festival — Youth",
          "federation" => "BEL",
          "round_dates" => ["2026-09-01", "2026-09-02"]
        })

      conn =
        get(conn, ~p"/t/#{open.id}/norms/it3", %{
          "combine" => "#{open.id},#{youth.id}",
          "master" => "#{youth.id}"
        })

      assert conn.status == 200
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "ghent-festival-youth-festival"

      members = unzip_map(conn.resp_body)
      sheet_xml = Map.fetch!(members, "xl/worksheets/sheet2.xml")

      assert sheet_xml =~
               ~r/<c r="B3"[^>]*t="inlineStr"><is><t xml:space="preserve">Ghent Festival — Youth Festival<\/t><\/is><\/c>/

      assert sheet_xml =~
               ~r/<c r="B12"[^>]*t="inlineStr"><is><t xml:space="preserve">1-1<\/t><\/is><\/c>/
    end

    test "duplicate player across the combined tournaments flashes a friendly error instead of a 500",
         %{
           conn: conn,
           scope: scope
         } do
      open = create_tournament(scope, %{"name" => "Ghent Festival — Open", "federation" => "BEL"})

      youth =
        create_tournament(scope, %{"name" => "Ghent Festival — Youth", "federation" => "BEL"})

      {:ok, _} =
        Tournaments.create_player(open.id, %{
          "name" => "Dupe, Player",
          "fide_id" => "999999",
          "federation" => "BEL"
        })

      {:ok, _} =
        Tournaments.create_player(youth.id, %{
          "name" => "Dupe, Player",
          "fide_id" => "999999",
          "federation" => "BEL"
        })

      conn =
        get(conn, ~p"/t/#{open.id}/norms/it3", %{
          "combine" => "#{open.id},#{youth.id}",
          "master" => "#{open.id}"
        })

      assert redirected_to(conn) == ~p"/t/#{open.id}/norms"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Dupe, Player"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "can't share players"
    end

    test "an unauthorized id inside combine= 404s, same as the route id would", %{
      conn: conn,
      scope: scope
    } do
      open = create_tournament(scope, %{"name" => "Ghent Festival — Open", "federation" => "BEL"})

      other_scope = PairingsEngine.AccountsFixtures.user_scope_fixture()
      forbidden = tournament_fixture(other_scope)

      assert_error_sent 404, fn ->
        get(conn, ~p"/t/#{open.id}/norms/it3", %{
          "combine" => "#{open.id},#{forbidden.id}",
          "master" => "#{open.id}"
        })
      end
    end

    test "combine= absent or blank behaves exactly like the single-tournament path", %{
      conn: conn,
      scope: scope
    } do
      tournament = tournament_fixture(scope)

      conn_without = get(conn, ~p"/t/#{tournament.id}/norms/it3")
      assert conn_without.status == 200
      assert [disposition_without] = get_resp_header(conn_without, "content-disposition")
      refute disposition_without =~ "festival"

      conn_blank = get(conn, ~p"/t/#{tournament.id}/norms/it3", %{"combine" => ""})
      assert conn_blank.status == 200
      assert [disposition_blank] = get_resp_header(conn_blank, "content-disposition")
      assert disposition_blank == disposition_without
      assert byte_size(conn_blank.resp_body) == byte_size(conn_without.resp_body)
    end
  end
end
