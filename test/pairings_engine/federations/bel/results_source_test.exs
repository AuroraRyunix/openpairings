defmodule PairingsEngine.Federations.BEL.ResultsSourceTest do
  @moduledoc """
  Pulling the Belgian roster through OpenResults' relay instead of the KBSB
  data platform directly - available?/0's precedence, the fetch itself, ETag
  reuse, and each error's wording.
  """
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.Federations.BEL.ResultsSource
  alias PairingsEngine.Meta
  alias PairingsEngine.Publishing

  setup do
    original_kbsb = Application.get_env(:pairings_engine, :kbsb)
    Application.delete_env(:pairings_engine, :kbsb)
    Publishing.put_endpoint("https://openresults.example")
    Publishing.put_token("op-token")
    Meta.delete(ResultsSource.etag_key())

    on_exit(fn ->
      if original_kbsb,
        do: Application.put_env(:pairings_engine, :kbsb, original_kbsb),
        else: Application.delete_env(:pairings_engine, :kbsb)

      Publishing.put_endpoint(nil)
      Publishing.put_token(nil)
      Meta.delete(ResultsSource.etag_key())
    end)

    :ok
  end

  defp stub(fun), do: Req.Test.stub(PairingsEngine.PublishingTest, fun)

  describe "available?/0" do
    test "true with an OpenResults connection and no direct data-platform key" do
      assert ResultsSource.available?()
    end

    test "false when the direct data-platform key is configured - it takes precedence" do
      Application.put_env(:pairings_engine, :kbsb, api_url: "https://kbsb.test", api_key: "k")
      refute ResultsSource.available?()
    end

    test "false with no OpenResults connection at all" do
      Publishing.put_token(nil)
      Publishing.put_endpoint(nil)
      refute Publishing.public_mode?()
      refute ResultsSource.available?()
    end
  end

  describe "fetch_all/0" do
    test "fetches and shapes rows, and remembers the ETag" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("etag", ~s("abc123"))
        |> Req.Test.json(%{
          "updated_at" => "2026-09-13T10:00:00Z",
          "count" => 1,
          "players" => [
            %{
              "national_id" => 12345,
              "last_name" => "Peeters",
              "first_name" => "An",
              "national_rating" => nil,
              "fide_id" => 2_500_123,
              "club_number" => 130,
              "club_name" => "KGSRL",
              "federation" => "BEL"
            }
          ]
        })
      end)

      assert {:ok, [row]} = ResultsSource.fetch_all()
      assert row.national_id == "12345"
      assert row.last_name == "Peeters"
      assert row.fide_id == 2_500_123
      assert row.club_number == 130
      refute Map.has_key?(row, :birth_year)
      refute Map.has_key?(row, :died)
      refute Map.has_key?(row, :affiliated)

      assert Meta.get(ResultsSource.etag_key()) == ~s("abc123")
    end

    test "sends the remembered ETag as If-None-Match, and :unchanged on a 304" do
      Meta.put(ResultsSource.etag_key(), ~s("abc123"))

      stub(fn conn ->
        assert Plug.Conn.get_req_header(conn, "if-none-match") == [~s("abc123")]
        Plug.Conn.send_resp(conn, 304, "")
      end)

      assert ResultsSource.fetch_all() == :unchanged
    end

    test "not_configured (404) is a clear message, not a generic one" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(404)
        |> Req.Test.json(%{"error" => "not_configured", "detail" => "no relay"})
      end)

      assert {:error, message} = ResultsSource.fetch_all()
      assert message =~ "does not relay a Belgian roster"
    end

    test "401 is worded as a credential problem" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 401, "") end)
      assert {:error, message} = ResultsSource.fetch_all()
      assert message =~ "rejected this installation's credential"
    end

    test "429 mentions the rate limit" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "30")
        |> Plug.Conn.send_resp(429, "")
      end)

      assert {:error, message} = ResultsSource.fetch_all()
      assert message =~ "rate-limiting"
      assert message =~ "30"
    end

    test "a network failure is worded as unreachable" do
      stub(fn conn -> Req.Test.transport_error(conn, :timeout) end)
      assert {:error, message} = ResultsSource.fetch_all()
      assert message =~ "could not reach the results site"
    end

    test "unavailable (no connection) is refused before any request is made" do
      Publishing.put_token(nil)
      Publishing.put_endpoint(nil)

      assert {:error, message} = ResultsSource.fetch_all()
      assert message =~ "no connection to a results site"
    end
  end
end
