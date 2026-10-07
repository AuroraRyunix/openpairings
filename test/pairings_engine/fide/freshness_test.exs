defmodule PairingsEngine.Fide.FreshnessTest do
  # VCL4THP 141 and 135: is the local list as new as the one FIDE serves,
  # asked with one HEAD request. `config/test.exs` routes the request to this
  # module's `Req.Test` stub, so nothing here reaches the network.
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{Fide, Meta}
  alias PairingsEngine.Fide.Freshness

  defp stub_head(last_modified) do
    Req.Test.stub(__MODULE__, fn conn ->
      conn =
        if last_modified,
          do: Plug.Conn.put_resp_header(conn, "last-modified", last_modified),
          else: conn

      Plug.Conn.send_resp(conn, 200, "")
    end)
  end

  defp sync_at(datetime) do
    Repo.query!(
      "INSERT INTO meta (key, value) VALUES ('fide_last_sync', ?) " <>
        "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
      [datetime]
    )
  end

  test "no list downloaded: nothing to compare, and the server is not asked" do
    assert Fide.last_sync() == nil
    assert Freshness.check() == :unverified
  end

  test "the server's list is newer than the local copy: stale" do
    sync_at("2026-10-01 08:00:00")
    stub_head("Thu, 01 Oct 2026 12:00:00 GMT")
    assert Freshness.check() == :stale
  end

  test "the server's list is not newer than the local copy: current" do
    sync_at("2026-10-02 08:00:00")
    stub_head("Thu, 01 Oct 2026 12:00:00 GMT")
    assert Freshness.check() == :current
  end

  test "an unreachable server on this month's list is unverified, not an error" do
    sync_at("2026-10-02 08:00:00")
    Meta.put("fide_list_period", Fide.month_of(Date.utc_today()))
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
    assert Freshness.check() == :unverified
  end

  test "a server that does not date its list: an earlier month is stale, this month unverified" do
    sync_at("2026-01-02 08:00:00")
    Meta.put("fide_list_period", "2026-01")
    stub_head(nil)
    assert Freshness.check() == :stale

    Meta.put("fide_list_period", Fide.month_of(Date.utc_today()))
    assert Freshness.check() == :unverified
  end

  test "Last-Modified parses to UTC, junk to nil" do
    assert %DateTime{year: 2026, month: 10, day: 1, hour: 12} =
             Fide.parse_http_date("Thu, 01 Oct 2026 12:00:00 GMT")

    assert Fide.parse_http_date("yesterday") == nil
    assert Fide.parse_http_date(nil) == nil
  end
end
