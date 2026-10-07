defmodule PairingsEngine.Fide.AutoSyncTest do
  # VCL4THP 135: while the program runs, the local list is never more than a
  # day behind FIDE's. One pass is `run_once/1`; the HEAD request goes to the
  # `Req.Test` stub `config/test.exs` names, and the download itself is
  # replaced by a function that reports it was asked for.
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{Fide, Meta}
  alias PairingsEngine.Fide.AutoSync

  defp sync_at(datetime) do
    Repo.query!(
      "INSERT INTO meta (key, value) VALUES ('fide_last_sync', ?) " <>
        "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
      [datetime]
    )
  end

  defp stub_head(last_modified) do
    Req.Test.stub(PairingsEngine.Fide.FreshnessTest, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("last-modified", last_modified)
      |> Plug.Conn.send_resp(200, "")
    end)
  end

  defp opts do
    test = self()
    [sync: fn -> send(test, :sync_started) end, busy?: fn -> false end]
  end

  test "on by default, and the setting can be switched off and back" do
    assert AutoSync.enabled?()
    AutoSync.put_enabled(false)
    refute AutoSync.enabled?()
    assert AutoSync.run_once(opts()) == :disabled
    refute_received :sync_started
    AutoSync.put_enabled(true)
    assert AutoSync.enabled?()
  end

  test "with no list at all it downloads one without asking FIDE" do
    assert AutoSync.run_once(opts()) == :updating
    assert_received :sync_started
  end

  test "a newer list at FIDE starts the download, once, and is not asked again within a day" do
    sync_at("2026-10-01 08:00:00")
    stub_head("Thu, 15 Oct 2026 12:00:00 GMT")

    assert AutoSync.run_once(opts()) == :updating
    assert_received :sync_started

    assert AutoSync.run_once(opts()) == :not_due
    refute_received :sync_started
  end

  test "a list that is already the newest starts nothing" do
    sync_at("2026-10-20 08:00:00")
    stub_head("Thu, 01 Oct 2026 12:00:00 GMT")

    assert AutoSync.run_once(opts()) == :current
    refute_received :sync_started
  end

  test "a look more than a day old is due again" do
    Meta.put("fide_last_check", "2020-01-01T00:00:00Z")
    assert AutoSync.due?()

    Meta.put("fide_last_check", DateTime.to_iso8601(DateTime.utc_now()))
    refute AutoSync.due?()
    assert AutoSync.due?(DateTime.add(DateTime.utc_now(), 25 * 3600))
  end

  test "an update already running is left alone" do
    assert AutoSync.run_once(sync: fn -> send(self(), :sync_started) end, busy?: fn -> true end) ==
             :busy

    refute_received :sync_started
  end

  test "an unreachable FIDE is silent and not counted as a look, so the next tick tries again" do
    sync_at("2026-10-01 08:00:00")
    Meta.put("fide_list_period", Fide.month_of(Date.utc_today()))

    Req.Test.stub(PairingsEngine.Fide.FreshnessTest, fn conn ->
      Req.Test.transport_error(conn, :econnrefused)
    end)

    assert AutoSync.run_once(opts()) == :unverified
    refute_received :sync_started
    assert Meta.get("fide_last_check") == nil
  end
end
