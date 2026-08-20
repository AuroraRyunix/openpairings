defmodule PairingsEngine.Kbsb.ApiTest do
  # async: false — these swap the :kbsb application env, which is global.
  use ExUnit.Case, async: false

  alias PairingsEngine.Kbsb.Api

  setup do
    original = Application.get_env(:pairings_engine, :kbsb)

    on_exit(fn ->
      if original,
        do: Application.put_env(:pairings_engine, :kbsb, original),
        else: Application.delete_env(:pairings_engine, :kbsb)
    end)

    :ok
  end

  defp configure(opts) do
    Application.put_env(
      :pairings_engine,
      :kbsb,
      Keyword.merge([api_url: "https://kbsb.test", api_key: "secret"], opts)
    )
  end

  # A stand-in for the platform's /export endpoint. `pages` maps the cursor
  # it was called with (nil for the first request) to the body to return.
  defp plug(pages) do
    fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      cursor = conn.params["cursor"] && String.to_integer(conn.params["cursor"])

      case Map.fetch(pages, cursor) do
        {:ok, {status, body}} ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(status, Jason.encode!(body))

        :error ->
          raise "test plug called with an unexpected cursor: #{inspect(cursor)}"
      end
    end
  end

  defp player(id, attrs \\ %{}) do
    Map.merge(
      %{
        "national_id" => id,
        "first_name" => "First#{id}",
        "last_name" => "Last#{id}",
        "sex" => "m",
        "birthday" => 1985,
        "fed" => "VSF",
        "club" => 812,
        "club_name" => "Rokade",
        "affiliated" => true,
        "died" => false,
        "fide_id" => 900_000 + id
      },
      attrs
    )
  end

  describe "configured?/0" do
    test "needs both the URL and the key" do
      configure([])
      assert Api.configured?()

      configure(api_key: nil)
      refute Api.configured?()

      configure(api_url: nil)
      refute Api.configured?()

      # Blank strings are as unconfigured as nil — an env var set to "" is
      # the usual shape of "someone meant to set this and didn't".
      configure(api_key: "")
      refute Api.configured?()
    end
  end

  describe "fetch_all/1" do
    test "explains itself rather than crashing when unconfigured" do
      Application.delete_env(:pairings_engine, :kbsb)

      assert {:error, message} = Api.fetch_all()
      assert message =~ "not configured"
      assert message =~ "KBSB_API_URL"
    end

    test "follows next_cursor across pages and stops on null" do
      pages = %{
        nil => {200, %{"players" => [player(1), player(2)], "next_cursor" => 2}},
        2 => {200, %{"players" => [player(3)], "next_cursor" => nil}}
      }

      configure(req_options: [plug: plug(pages)])

      assert {:ok, rows} = Api.fetch_all()
      assert Enum.map(rows, & &1.national_id) == ["1", "2", "3"]
    end

    test "reports running progress per page" do
      pages = %{
        nil => {200, %{"players" => [player(1), player(2)], "next_cursor" => 2}},
        2 => {200, %{"players" => [player(3)], "next_cursor" => nil}}
      }

      configure(req_options: [plug: plug(pages)])

      me = self()
      assert {:ok, _} = Api.fetch_all(fn count -> send(me, {:progress, count}) end)

      assert_received {:progress, 2}
      assert_received {:progress, 3}
    end

    # The one failure mode in here that would HANG rather than error, which
    # is why it gets its own test: a cursor that repeats re-fetches the same
    # page forever.
    test "refuses a cursor that does not advance" do
      pages = %{
        nil => {200, %{"players" => [player(1)], "next_cursor" => 5}},
        5 => {200, %{"players" => [player(2)], "next_cursor" => 5}}
      }

      configure(req_options: [plug: plug(pages)])

      assert {:error, message} = Api.fetch_all()
      assert message =~ "did not advance"
    end

    test "a rejected key says so, and says which setting to look at" do
      configure(req_options: [plug: plug(%{nil => {401, %{"message" => "nope"}}})])

      assert {:error, message} = Api.fetch_all()
      assert message =~ "401"
      assert message =~ "KBSB_API_KEY"
    end

    test "a 404 points at the likeliest cause rather than the status code" do
      configure(req_options: [plug: plug(%{nil => {404, %{}}})])

      assert {:error, message} = Api.fetch_all()
      assert message =~ "base"
    end

    test "a 200 that is not a player list is not treated as an empty roster" do
      configure(req_options: [plug: plug(%{nil => {200, %{"hello" => "world"}}})])

      assert {:error, message} = Api.fetch_all()
      assert message =~ "no player list"
    end
  end

  describe "to_row/1" do
    test "maps the export onto the local mirror's columns" do
      row = Api.to_row(player(7))

      assert row.national_id == "7"
      assert row.last_name == "Last7"
      assert row.first_name == "First7"
      assert row.fide_id == 900_007
      assert row.club_number == 812
      assert row.club_name == "Rokade"
      assert row.federation == "VSF"
      # `birthday` is a YEAR on the platform, not a date — confirmed in
      # database_manager's players/player.ex (`birth && birth.year`).
      assert row.birth_year == 1985
      assert row.died == false
      assert row.affiliated == true
    end

    test "club 0 is 'no club', not club number zero" do
      row = Api.to_row(player(8, %{"club" => 0, "club_name" => nil}))

      # nil, so ClubRefresh's maybe_add skips it. Storing 0 would make the
      # club refresh propose "club number 0" for 5,836 members.
      assert row.club_number == nil
      assert row.club_name == ""
    end

    test "never carries a national rating" do
      row = Api.to_row(player(9, %{"national_rating" => 1750}))
      assert row.national_rating == nil
    end

    test "every row has identical keys, which insert_all requires" do
      keys = Api.to_row(player(1)) |> Map.keys() |> Enum.sort()
      sparse = Api.to_row(%{"national_id" => 2}) |> Map.keys() |> Enum.sort()

      assert keys == sparse
    end
  end
end
