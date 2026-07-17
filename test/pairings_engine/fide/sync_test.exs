defmodule PairingsEngine.Fide.SyncTest do
  # Sync is a singleton GenServer (named process) started by the application
  # supervisor, so tests here mutate shared global state via :sys and fake
  # OTP messages rather than spinning up isolated instances. Kept `async:
  # false` since nothing else in the suite touches this process, but there's
  # no reason to risk interleaving with itself.
  use ExUnit.Case, async: false

  alias PairingsEngine.Fide.Sync
  alias PairingsEngine.Fide.FidePlayer
  alias PairingsEngine.Repo

  setup do
    reset_state()
    Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Sync.topic())
    on_exit(fn -> reset_state() end)
    :ok
  end

  defp reset_state, do: :sys.replace_state(Sync, fn _ -> struct(Sync) end)
  defp raw_state, do: :sys.get_state(Sync)

  defp put_busy(status, extra \\ %{}) do
    fields = Map.merge(%{status: status}, extra) |> Map.to_list()
    :sys.replace_state(Sync, fn state -> struct(state, fields) end)
  end

  defp alive_dummy do
    spawn(fn -> Process.sleep(:infinity) end)
  end

  describe "task crash (:DOWN) handling" do
    test "an abnormal :DOWN for the current task resets state to :error and clears busy fields" do
      pid = alive_dummy()
      ref = make_ref()
      put_busy(:downloading, %{task_pid: pid, task_ref: ref})

      send(Sync, {:DOWN, ref, :process, pid, :killed})

      assert_receive {:fide_sync, %Sync{status: :error} = state}
      assert state.error =~ "crashed unexpectedly"
      assert state.task_pid == nil
      assert state.task_ref == nil
      assert state.watchdog_timer == nil

      assert raw_state().status == :error
    end

    test "a stale :DOWN (task_ref no longer matches) is ignored and does not clobber state" do
      stale_ref = make_ref()
      pid = alive_dummy()

      # Simulate: the sync already finished/was cancelled, so task_ref is nil.
      put_busy(:idle, %{task_ref: nil, task_pid: nil})

      send(Sync, {:DOWN, stale_ref, :process, pid, :killed})

      # No PubSub broadcast should have been triggered by the stale DOWN.
      refute_receive {:fide_sync, _}, 100
      assert raw_state().status == :idle
    end

    test "a :normal :DOWN is not treated as a crash" do
      pid = alive_dummy()
      ref = make_ref()
      put_busy(:downloading, %{task_pid: pid, task_ref: ref})

      send(Sync, {:DOWN, ref, :process, pid, :normal})

      refute_receive {:fide_sync, _}, 100
      assert raw_state().status == :downloading
    end
  end

  describe "watchdog" do
    test "firing while busy kills the task, fails the sync, and returns to a recoverable state" do
      pid = alive_dummy()
      put_busy(:downloading, %{task_pid: pid, task_ref: make_ref()})

      send(Sync, :watchdog_timeout)

      assert_receive {:fide_sync, %Sync{status: :error} = state}
      assert state.error =~ "stalled with no progress"
      assert state.task_pid == nil

      # Give the kill signal a moment to land.
      refute Process.alive?(pid)
    end

    test "firing while idle is a no-op" do
      put_busy(:idle)

      send(Sync, :watchdog_timeout)

      refute_receive {:fide_sync, _}, 100
      assert raw_state().status == :idle
    end
  end

  describe "cancel_sync/0" do
    test "kills the running task and resets to :idle" do
      pid = alive_dummy()
      put_busy(:importing, %{task_pid: pid, task_ref: make_ref()})

      Sync.cancel_sync()

      assert_receive {:fide_sync, %Sync{status: :idle} = state}
      assert state.task_pid == nil
      refute Process.alive?(pid)
    end

    test "is a no-op when nothing is running" do
      put_busy(:idle)

      Sync.cancel_sync()

      refute_receive {:fide_sync, _}, 100
      assert raw_state().status == :idle
    end
  end

  describe "start_sync/0 guarding" do
    test "does nothing while a sync is already in progress" do
      put_busy(:downloading, %{progress: "Downloading rating list… 3.0 of 41.0 MB"})

      Sync.start_sync()

      refute_receive {:fide_sync, _}, 100
      assert raw_state().progress == "Downloading rating list… 3.0 of 41.0 MB"
    end
  end

  # Exercises `Sync.import_list/3` directly with synthetic already-unpacked
  # FIDE-list text (the real thing `unpack/3` would hand it after a real
  # HTTP download + zip extraction, which isn't practical to drive from a
  # test) — this is the actual transaction/count-guard code path a corrupt
  # or truncated download would hit, not just a re-assertion of the design.
  # `import_list/3` is `def` (not `defp`), `@doc false`, purely to make this
  # callable from here.
  describe "import_list/3 (corrupt/truncated-download guard)" do
    # These tests write real rows to fide_players and need a real DB
    # connection (unlike the rest of this file, which only exercises the
    # GenServer's in-memory state via :sys) — check out the sandbox exactly
    # like PairingsEngine.DataCase does, but only for this describe block.
    setup do
      pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: false)
      on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
      :ok
    end

    # Mirrors Sync's own private @header_labels — the header line just needs
    # each label to appear, in order, for column_offsets/1 to succeed; exact
    # column widths don't matter as long as the header and every data row
    # use the same ones (see fide_row/1).
    @header_labels [
      "ID Number", "Name", "Fed", "Sex", "Tit", "WTit", "OTit", "FOA",
      "SRtng", "SGm", "SK", "RRtng", "RGm", "Rk", "BRtng", "BGm", "BK",
      "B-day", "Flag"
    ]
    @col_width 12

    defp fide_header, do: Enum.map_join(@header_labels, "", &String.pad_trailing(&1, @col_width))

    # `values` is keyed by header label text (e.g. "ID Number", "Name") —
    # any column not given a value comes out blank, which is exactly what
    # produces an unusable (nil fide_id) row for the zero-valid-rows tests.
    defp fide_row(values \\ %{}) do
      Enum.map_join(@header_labels, "", fn label ->
        values |> Map.get(label, "") |> to_string() |> String.pad_trailing(@col_width)
      end)
    end

    defp fide_text(rows), do: Enum.join([fide_header() | rows], "\r\n")

    test "a well-formed header with zero valid data rows fails instead of wiping the cache" do
      Repo.insert_all(FidePlayer, [
        %{fide_id: 1, name: "Existing, One", federation: "BEL"},
        %{fide_id: 2, name: "Existing, Two", federation: "BEL"}
      ])

      # 5 blank data rows: well-formed header, but every row is missing an
      # ID Number/Name, so all 5 are filtered out as unusable.
      text = fide_text(List.duplicate(fide_row(), 5))

      assert {:error, reason} = Sync.import_list(self(), text, %Sync{})
      assert reason =~ "zero usable"

      # The existing cache is untouched — proof the rollback (not just the
      # return value) actually protected the data.
      assert Repo.aggregate(FidePlayer, :count) == 2
      assert Repo.get(FidePlayer, 1).name == "Existing, One"
    end

    test "a big drop from the existing cache (fewer than half survive) also rolls back" do
      Repo.insert_all(FidePlayer, for(n <- 1..10, do: %{fide_id: n, name: "Existing, #{n}", federation: "BEL"}))

      row = fide_row(%{"ID Number" => "999999", "Name" => "OnlyOne, Player", "Fed" => "BEL"})
      text = fide_text([row])

      assert {:error, reason} = Sync.import_list(self(), text, %Sync{})
      assert reason =~ "far fewer"

      assert Repo.aggregate(FidePlayer, :count) == 10
    end

    test "a normal, healthy import still succeeds and replaces the cache" do
      rows =
        for n <- 1..5 do
          fide_row(%{
            "ID Number" => to_string(1_000_000 + n),
            "Name" => "Player, #{n}",
            "Fed" => "BEL"
          })
        end

      text = fide_text(rows)

      assert {:ok, %Sync{imported_rows: 5}} = Sync.import_list(self(), text, %Sync{})
      assert Repo.aggregate(FidePlayer, :count) == 5
      assert Repo.get(FidePlayer, 1_000_001).name == "Player, 1"
    end
  end
end
