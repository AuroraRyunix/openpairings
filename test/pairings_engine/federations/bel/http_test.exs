defmodule PairingsEngine.Federations.BEL.HttpTest do
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.Federations.BEL.{Http, Settings}
  alias PairingsEngine.Support.KbsbSqliteFixture, as: Fixture

  setup do
    previous = Application.get_env(:pairings_engine, :bel_http_req_plug)
    Application.put_env(:pairings_engine, :bel_http_req_plug, __MODULE__)

    on_exit(fn ->
      # Restored, not deleted: config/test.exs sets it for the whole suite.
      Application.put_env(:pairings_engine, :bel_http_req_plug, previous)
      Settings.put_players_url(nil)
      Settings.put_clubs_url(nil)
    end)

    :ok
  end

  defp stub(fun), do: Req.Test.stub(__MODULE__, fun)

  defp zip_response(conn, sqlite_bytes) do
    zip = Fixture.zip(sqlite_bytes)
    conn |> Plug.Conn.put_resp_header("etag", "\"v1\"") |> Plug.Conn.send_resp(200, zip)
  end

  describe "month fallback" do
    test "the current month answers 301 (not yet published), falls back to the previous one" do
      current =
        Date.utc_today() |> Date.to_string() |> String.slice(0, 7) |> String.replace("-", "")

      stub(fn conn ->
        if String.contains?(conn.request_path, current) do
          Plug.Conn.send_resp(conn, 301, "moved")
        else
          zip_response(conn, Fixture.build_sqlite([Fixture.default_row()]))
        end
      end)

      assert {:ok, %{rows: [_row], month_label: label}} = Http.fetch_players()
      refute label == nil
    end

    test "404 also falls back, same as 301" do
      current =
        Date.utc_today() |> Date.to_string() |> String.slice(0, 7) |> String.replace("-", "")

      stub(fn conn ->
        if String.contains?(conn.request_path, current) do
          Plug.Conn.send_resp(conn, 404, "not found")
        else
          zip_response(conn, Fixture.build_sqlite([Fixture.default_row()]))
        end
      end)

      assert {:ok, _result} = Http.fetch_players()
    end

    test "gives up after exhausting the fallback window" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 301, "moved") end)

      assert {:error, message} = Http.fetch_players()
      assert message =~ "No published"
    end
  end

  describe "conditional GET" do
    test "a 304 on the resolved URL is reported as :unchanged" do
      stub(fn conn -> zip_response(conn, Fixture.build_sqlite([Fixture.default_row()])) end)
      assert {:ok, _} = Http.fetch_players()

      stub(fn conn -> Plug.Conn.send_resp(conn, 304, "") end)
      assert Http.fetch_players() == :unchanged
    end
  end

  describe "fixed URL (no placeholder)" do
    test "is used exactly as configured, with no month walking" do
      Settings.put_players_url("https://mirror.example/fixed.zip")

      stub(fn conn ->
        assert conn.request_path == "/fixed.zip"
        zip_response(conn, Fixture.build_sqlite([Fixture.default_row()]))
      end)

      assert {:ok, %{rows: [_row]}} = Http.fetch_players()
    end
  end

  describe "caps" do
    test "a compressed download over the size cap is rejected" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 200, :binary.copy(<<0>>, 20_000_001)) end)

      assert {:error, message} = Http.fetch_players()
      assert message =~ "exceeded"
    end
  end

  describe "fetch_clubs_file/1" do
    test ":not_configured when no clubs URL is set" do
      assert Http.fetch_clubs_file() == :not_configured
    end

    test "parses a CSV clubs file" do
      Settings.put_clubs_url("https://mirror.example/clubs.csv")
      stub(fn conn -> Plug.Conn.send_resp(conn, 200, "number,name\n42,KGSRL\n7,Other Club\n") end)

      assert {:ok, %{42 => "KGSRL", 7 => "Other Club"}} = Http.fetch_clubs_file()
    end

    test "parses a JSON list clubs file" do
      Settings.put_clubs_url("https://mirror.example/clubs.json")

      stub(fn conn ->
        Plug.Conn.send_resp(conn, 200, ~s([{"number": 42, "name": "KGSRL"}]))
      end)

      assert {:ok, %{42 => "KGSRL"}} = Http.fetch_clubs_file()
    end

    test "parses a JSON object clubs file" do
      Settings.put_clubs_url("https://mirror.example/clubs.json")
      stub(fn conn -> Plug.Conn.send_resp(conn, 200, ~s({"42": "KGSRL"})) end)

      assert {:ok, %{42 => "KGSRL"}} = Http.fetch_clubs_file()
    end

    test "a malformed clubs file is an error, not a crash" do
      Settings.put_clubs_url("https://mirror.example/clubs.csv")
      stub(fn conn -> Plug.Conn.send_resp(conn, 200, "not,the,right,header\n1,2,3,4\n") end)

      assert {:error, _reason} = Http.fetch_clubs_file()
    end
  end
end
