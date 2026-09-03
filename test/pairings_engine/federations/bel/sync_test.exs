defmodule PairingsEngine.Federations.BEL.SyncTest do
  # Sync is a singleton GenServer (named process) started by the application
  # supervisor, so tests here mutate shared global state via :sys and fake
  # OTP messages rather than spinning up isolated instances - same approach
  # as PairingsEngine.Fide.SyncTest, which this mirrors. Kept `async: false`
  # since nothing else in the suite touches this process, but there's no
  # reason to risk interleaving with itself.
  use ExUnit.Case, async: false

  alias PairingsEngine.Federations.BEL.Sync
  alias PairingsEngine.Federations.BEL.Member
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
      put_busy(:importing, %{task_pid: pid, task_ref: ref})

      send(Sync, {:DOWN, ref, :process, pid, :killed})

      assert_receive {:kbsb_sync, %Sync{status: :error} = state}
      assert state.error =~ "crashed unexpectedly"
      assert state.task_pid == nil
      assert state.task_ref == nil
      assert state.watchdog_timer == nil

      assert raw_state().status == :error
    end

    test "a stale :DOWN (task_ref no longer matches) is ignored and does not clobber state" do
      stale_ref = make_ref()
      pid = alive_dummy()

      # Simulate: the import already finished/was cancelled, so task_ref is nil.
      put_busy(:idle, %{task_ref: nil, task_pid: nil})

      send(Sync, {:DOWN, stale_ref, :process, pid, :killed})

      refute_receive {:kbsb_sync, _}, 100
      assert raw_state().status == :idle
    end

    test "a :normal :DOWN is not treated as a crash" do
      pid = alive_dummy()
      ref = make_ref()
      put_busy(:importing, %{task_pid: pid, task_ref: ref})

      send(Sync, {:DOWN, ref, :process, pid, :normal})

      refute_receive {:kbsb_sync, _}, 100
      assert raw_state().status == :importing
    end
  end

  describe "watchdog" do
    test "firing while busy kills the task, fails the import, and returns to a recoverable state" do
      pid = alive_dummy()
      put_busy(:importing, %{task_pid: pid, task_ref: make_ref()})

      send(Sync, :watchdog_timeout)

      assert_receive {:kbsb_sync, %Sync{status: :error} = state}
      assert state.error =~ "stalled with no progress"
      assert state.task_pid == nil

      refute Process.alive?(pid)
    end

    test "firing while idle is a no-op" do
      put_busy(:idle)

      send(Sync, :watchdog_timeout)

      refute_receive {:kbsb_sync, _}, 100
      assert raw_state().status == :idle
    end
  end

  describe "cancel_import/0" do
    test "kills the running task and resets to :idle" do
      pid = alive_dummy()
      put_busy(:importing, %{task_pid: pid, task_ref: make_ref()})

      Sync.cancel_import()

      assert_receive {:kbsb_sync, %Sync{status: :idle} = state}
      assert state.task_pid == nil
      refute Process.alive?(pid)
    end

    test "is a no-op when nothing is running" do
      put_busy(:idle)

      Sync.cancel_import()

      refute_receive {:kbsb_sync, _}, 100
      assert raw_state().status == :idle
    end
  end

  describe "start_import/1 guarding" do
    test "does nothing while an import is already in progress" do
      put_busy(:importing, %{progress: "Importing players… 500 of 2000"})

      Sync.start_import("Matricule;Nom\n1;Foo\n")

      refute_receive {:kbsb_sync, _}, 100
      assert raw_state().progress == "Importing players… 500 of 2000"
    end
  end

  # Exercises `Sync.import_rows/3` directly with synthetic already-parsed
  # rows (the shape `Members.Parser.parse/1` hands it) - the actual
  # count-guard code path a corrupt/truncated upload would hit, not just a
  # re-assertion of the design. `import_rows/3` is `def` (not `defp`),
  # `@doc false`, purely to make this callable from here.
  describe "import_rows/3 (corrupt/truncated-upload guard)" do
    # These tests write real rows to kbsb_players and need a real DB
    # connection (unlike the rest of this file, which only exercises the
    # GenServer's in-memory state via :sys) - check out the sandbox exactly
    # like PairingsEngine.DataCase does, but only for this describe block.
    setup do
      pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: false)
      on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
      :ok
    end

    defp kbsb_row(national_id, last_name) do
      %{
        national_id: national_id,
        last_name: last_name,
        first_name: "",
        national_rating: nil,
        fide_id: nil,
        club_number: nil,
        club_name: "",
        federation: "",
        birth_year: nil
      }
    end

    test "zero rows fails outright, before ever touching the database" do
      Repo.insert_all(Member, [
        kbsb_row("1", "Existing One"),
        kbsb_row("2", "Existing Two")
      ])

      assert {:error, reason} = Sync.import_rows(self(), [], %Sync{})
      assert reason =~ "zero usable"

      # Untouched - the guard fires before the delete+insert transaction
      # even starts, so there's nothing to roll back.
      assert Repo.aggregate(Member, :count) == 2
      assert Repo.get(Member, "1").last_name == "Existing One"
    end

    test "a big drop from the existing cache (fewer than half survive) also fails without touching the database" do
      Repo.insert_all(Member, for(n <- 1..10, do: kbsb_row(to_string(n), "Existing #{n}")))

      assert {:error, reason} = Sync.import_rows(self(), [kbsb_row("999", "OnlyOne")], %Sync{})
      assert reason =~ "far fewer"

      assert Repo.aggregate(Member, :count) == 10
    end

    test "a normal, healthy import still succeeds and replaces the cache" do
      rows = for n <- 1..5, do: kbsb_row(to_string(n), "Player #{n}")

      assert {:ok, %Sync{imported_rows: 5}} = Sync.import_rows(self(), rows, %Sync{})
      assert Repo.aggregate(Member, :count) == 5
      assert Repo.get(Member, "1").last_name == "Player 1"
    end
  end
end
