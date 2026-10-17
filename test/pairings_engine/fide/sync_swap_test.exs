defmodule PairingsEngine.Fide.SyncSwapTest do
  @moduledoc """
  A sync killed in the middle must leave the previous, complete list in
  place. It used to delete `fide_players` first and refill it after, so a
  restart during the refill left a partial table (894,000 rows against 1.9
  million name-index entries, in production) until somebody ran another sync.
  """
  use ExUnit.Case, async: false

  alias PairingsEngine.Fide
  alias PairingsEngine.Fide.{FidePlayer, Sync}
  alias PairingsEngine.Repo

  @labels [
    "ID Number",
    "Name",
    "Fed",
    "Sex",
    "Tit",
    "WTit",
    "OTit",
    "FOA",
    "SRtng",
    "SGm",
    "SK",
    "RRtng",
    "RGm",
    "Rk",
    "BRtng",
    "BGm",
    "BK",
    "B-day",
    "Flag"
  ]
  @width 12

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    :sys.replace_state(Sync, fn _ -> struct(Sync) end)
    :ok
  end

  defp row(id, name) do
    values = %{"ID Number" => id, "Name" => name, "Fed" => "BEL"}

    Enum.map_join(@labels, "", fn l ->
      values |> Map.get(l, "") |> to_string() |> String.pad_trailing(@width)
    end)
  end

  defp text(rows) do
    header = Enum.map_join(@labels, "", &String.pad_trailing(&1, @width))
    Enum.join([header | rows], "\r\n")
  end

  defp names(sql), do: Repo.query!(sql).rows |> List.flatten()

  defp tables,
    do: names("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'fide_players%'")

  defp trigger_tables,
    do:
      names(
        "SELECT DISTINCT tbl_name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'fide_players_fts_%'"
      )

  defp row_indexes,
    do:
      names(
        "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'fide_players' AND sql IS NOT NULL ORDER BY name"
      )

  defp import!(rows), do: {:ok, _} = Sync.import_list(self(), text(rows), %Sync{})

  @tag :capture_log
  test "a run that dies mid-import leaves the old list complete and searchable" do
    import!([row(1, "Oldie, Alpha"), row(2, "Oldie, Beta")])
    before = Repo.query!("SELECT count(*) FROM fide_players").rows

    # The victim name belongs to this test process until the child takes it.
    Process.register(self(), :sync_swap_victim)
    rows = for i <- 1..50_100, do: row(8_000_000 + i, "Doomed, N#{i}")
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        send(parent, {:child, self()})
        Sync.import_list(:sync_swap_victim, text(rows), %Sync{})
      end)

    # Let the first update (the total) through to us, then pull the name.
    assert_receive {:sync_update, %Sync{total_rows: 50_100}}, 30_000
    Process.unregister(:sync_swap_victim)

    assert_receive {:DOWN, ^ref, :process, ^pid, {:badarg, _}}, 120_000

    assert Repo.query!("SELECT count(*) FROM fide_players").rows == before
    assert Fide.search("Oldie") |> Enum.map(& &1.fide_id) |> Enum.sort() == [1, 2]
    assert Fide.search("Doomed") == []

    assert "fide_players_new" in tables()
    assert "fide_players_fts_new" in tables()
    assert Sync.damage() == :interrupted
    assert trigger_tables() == ["fide_players"]
  end

  test "the next run repairs it: scratch tables gone, new list live, triggers and indexes in place" do
    import!([row(1, "Oldie, Alpha")])
    indexes_before = length(row_indexes())

    Repo.query!("CREATE TABLE fide_players_new (fide_id INTEGER PRIMARY KEY, name TEXT)")
    Repo.query!("INSERT INTO fide_players_new VALUES (99, 'Leftover, Ghost')")
    assert Sync.damage() == :interrupted

    import!([row(3, "Fresh, Gamma"), row(4, "Fresh, Delta")])

    assert Sync.damage() == nil

    assert tables() |> Enum.sort() ==
             ["fide_players", "fide_players_fts" | shadow_tables()] |> Enum.sort()

    assert Fide.search("Fresh") |> Enum.map(& &1.fide_id) |> Enum.sort() == [3, 4]
    assert Fide.search("Oldie") == []
    assert length(row_indexes()) == indexes_before
    assert trigger_tables() == ["fide_players"]

    # The triggers are on the live table and working: a single-row write
    # reaches the name index.
    Repo.insert_all(FidePlayer, [%{fide_id: 5, name: "Single, Epsilon", federation: "BEL"}])
    assert Enum.map(Fide.search("Epsilon"), & &1.fide_id) == [5]

    # And a second swap, which flips the index names back, is as good.
    import!([row(6, "Again, Zeta")])
    assert length(row_indexes()) == indexes_before
    assert Enum.map(Fide.search("Zeta"), & &1.fide_id) == [6]
    assert Fide.search("Fresh") == []
  end

  defp shadow_tables do
    ~w(fide_players_fts_config fide_players_fts_content fide_players_fts_data fide_players_fts_docsize fide_players_fts_idx)
  end

  test "the damage check flags a row table far below its name index" do
    import!([row(1, "Only, One")])
    assert Sync.damage() == nil

    for i <- 100..110 do
      Repo.query!("INSERT INTO fide_players_fts(fide_id, name) VALUES (?, ?)", [i, "Ghost, G#{i}"])
    end

    assert Sync.damage() == :incomplete
  end

  # Stops the named server and waits until the supervisor has a new one.
  defp restart_sync do
    old = Process.whereis(Sync)
    ref = Process.monitor(old)
    GenServer.stop(old)
    assert_receive {:DOWN, ^ref, _, _, _}
    wait_for_new(old)
  end

  defp wait_for_new(old) do
    case Process.whereis(Sync) do
      pid when is_pid(pid) and pid != old ->
        pid

      _ ->
        receive do
        after
          10 -> wait_for_new(old)
        end
    end
  end

  describe "at boot" do
    setup do
      Application.put_env(:pairings_engine, :fide_boot_check, true)
      on_exit(fn -> Application.put_env(:pairings_engine, :fide_boot_check, false) end)
    end

    test "the server flags a broken state, surfaces it in status/0, and a finished sync clears it" do
      import!([row(1, "Only, One")])

      for i <- 100..110 do
        Repo.query!("INSERT INTO fide_players_fts(fide_id, name) VALUES (?, ?)", [
          i,
          "Ghost, G#{i}"
        ])
      end

      restart_sync()

      # The call is answered only after the restarted server's continue.
      assert Sync.status().damage == :incomplete

      # Hosted/auto-sync is off in tests, so nothing started on its own.
      assert Sync.status().status == :idle
    end

    test "a healthy list leaves status/0 clean" do
      import!([row(1, "Only, One")])
      restart_sync()
      assert Sync.status().damage == nil
    end
  end
end
