defmodule PairingsEngine.Desktop.UninstallEntriesTest do
  @moduledoc """
  Which "Installed apps" entries are removed, refreshed or reported, and the
  order a removal happens in.

  The decisions run against an in-memory registry. The real `:win32reg`
  store is exercised in `PairingsEngine.Desktop.RegistryTest`, under a test
  key in HKCU - never against the real `Uninstall` keys.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PairingsEngine.Desktop.{DataHome, UninstallEntries}

  defmodule MemoryStore do
    @moduledoc false
    # Keyed by {root, name}. `fail` makes one operation fail, to check what a
    # removal does when a step does not go through.
    def start(entries \\ %{}, fail \\ nil) do
      {:ok, pid} = Agent.start_link(fn -> %{keys: entries, fail: fail, log: []} end)

      {__MODULE__,
       %{agent: pid, hkcu: "HKCU\\Uninstall", backup: "HKCU\\Backup", hklm: "HKLM\\Uninstall"}}
    end

    def dump({_, %{agent: pid}}), do: Agent.get(pid, & &1)

    def read(%{agent: pid}, root, name) do
      case Agent.get(pid, &Map.get(&1.keys, {root, name})) do
        nil -> :missing
        values -> {:ok, values}
      end
    end

    def put(%{agent: pid}, root, name, values) do
      Agent.get_and_update(pid, fn state ->
        if state.fail == {:put, root} do
          {{:error, :denied}, state}
        else
          keys = Map.update(state.keys, {root, name}, values, &Map.merge(&1, values))
          {:ok, %{state | keys: keys, log: state.log ++ [{:put, root, name}]}}
        end
      end)
    end

    def delete(%{agent: pid}, root, name) do
      Agent.get_and_update(pid, fn state ->
        if state.fail == {:delete, root} do
          {{:error, :denied}, state}
        else
          {:ok,
           %{
             state
             | keys: Map.delete(state.keys, {root, name}),
               log: state.log ++ [{:delete, root, name}]
           }}
        end
      end)
    end
  end

  setup do
    lad = Path.join(System.tmp_dir!(), "op_entries_#{System.unique_integer([:positive])}")
    File.mkdir_p!(lad)
    on_exit(fn -> File.rm_rf(lad) end)

    layout = DataHome.layout(lad)
    File.mkdir_p!(layout.home)
    File.mkdir_p!(layout.backups)
    app = Path.join(lad, "OpenPairingsApp")
    File.mkdir_p!(Path.join(app, "current"))

    %{lad: lad, layout: layout, app: app}
  end

  defp setup_exe_entry(location, version \\ "0.61.0") do
    %{
      "DisplayName" => "OpenPairings",
      "DisplayVersion" => version,
      "InstallLocation" => location,
      "UninstallString" => ~s("#{location}\\Update.exe" --uninstall)
    }
  end

  defp msi_entry(location, version \\ "0.61.0") do
    %{
      "DisplayName" => "OpenPairings",
      "DisplayVersion" => version,
      "InstallLocation" => location <> "\\",
      "UninstallString" => "msiexec.exe /x {49B2E118-1282-4066-81F5-AD1B653BAF67}"
    }
  end

  defp entry(root, key, values), do: %{root: root, key: key, values: values}

  defp context(layout, install), do: %{layout: layout, install: install, version: "0.62.0"}

  describe "plan/2" do
    test "an old-id entry whose install directory is the old data directory, still holding data, is removed",
         %{layout: layout, app: app} do
      File.mkdir_p!(layout.legacy)
      File.write!(Path.join(layout.legacy, "openpairings.db"), "data")
      old = entry(:hkcu, "OpenPairings", setup_exe_entry(layout.legacy, "0.54.0"))

      assert [{:remove, ^old, :endangers_data}] =
               UninstallEntries.plan(
                 [old],
                 context(layout, %{root: app, kind: :setup_exe, scope: :user})
               )
    end

    test "an entry whose uninstall would take the data directory or the backups is removed, whatever its name",
         %{layout: layout} do
      for dir <- [layout.home, layout.backups, layout.parent] do
        e = entry(:hkcu, "OpenPairingsApp", setup_exe_entry(dir))
        assert [{:remove, ^e, :endangers_data}] = UninstallEntries.plan([e], context(layout, nil))
      end
    end

    test "found only from UninstallString, when InstallLocation is missing", %{layout: layout} do
      values = layout.home |> setup_exe_entry() |> Map.delete("InstallLocation")
      e = entry(:hkcu, "OpenPairings", values)
      assert [{:remove, ^e, :endangers_data}] = UninstallEntries.plan([e], context(layout, nil))
    end

    test "the running Setup.exe install's own entry is kept and its version refreshed", %{
      layout: layout,
      app: app
    } do
      own = entry(:hkcu, "OpenPairingsApp", setup_exe_entry(app, "0.58.1"))

      assert [{:set_version, ^own, "0.62.0"}] =
               UninstallEntries.plan(
                 [own],
                 context(layout, %{root: app, kind: :setup_exe, scope: :user})
               )
    end

    test "an up-to-date own entry is left alone", %{layout: layout, app: app} do
      own = entry(:hkcu, "MSI:OpenPairingsApp", msi_entry(app, "0.62.0"))

      assert [] =
               UninstallEntries.plan(
                 [own],
                 context(layout, %{root: app, kind: :msi, scope: :user})
               )
    end

    test "Setup.exe over an .msi: the .msi's entry for the same directory is removed, Setup.exe's kept",
         %{layout: layout, app: app} do
      own = entry(:hkcu, "OpenPairingsApp", setup_exe_entry(app, "0.62.0"))
      msi = entry(:hkcu, "MSI:OpenPairingsApp", msi_entry(app, "0.60.1"))

      assert [{:remove, ^msi, :duplicate_of_running_install}] =
               UninstallEntries.plan(
                 [own, msi],
                 context(layout, %{root: app, kind: :setup_exe, scope: :user})
               )
    end

    test ".msi over Setup.exe: Setup.exe's entry for the same directory is removed, the .msi's kept",
         %{layout: layout, app: app} do
      own = entry(:hkcu, "MSI:OpenPairingsApp", msi_entry(app, "0.62.0"))
      exe = entry(:hkcu, "OpenPairingsApp", setup_exe_entry(app, "0.58.1"))

      assert [{:remove, ^exe, :duplicate_of_running_install}] =
               UninstallEntries.plan(
                 [own, exe],
                 context(layout, %{root: app, kind: :msi, scope: :user})
               )
    end

    test "an entry for a directory that no longer exists is removed", %{layout: layout, lad: lad} do
      gone = entry(:hkcu, "OpenPairingsApp", setup_exe_entry(Path.join(lad, "Nowhere")))

      assert [{:remove, ^gone, :install_location_missing}] =
               UninstallEntries.plan([gone], context(layout, nil))
    end

    test "the other scope is reported, not touched", %{layout: layout, app: app, lad: lad} do
      program_files = Path.join(lad, "ProgramFiles\\OpenPairingsApp")
      File.mkdir_p!(program_files)
      machine = entry(:hklm, "MSI:OpenPairingsApp", msi_entry(program_files))

      assert [{:report, :installed_twice, ^machine}] =
               UninstallEntries.plan(
                 [machine],
                 context(layout, %{root: app, kind: :setup_exe, scope: :user})
               )
    end

    test "HKLM is never changed, only reported - even an entry that endangers data", %{
      layout: layout
    } do
      e = entry(:hklm, "MSI:OpenPairingsApp", msi_entry(layout.home))

      assert [{:report, {:needs_administrator, :endangers_data}, ^e}] =
               UninstallEntries.plan([e], context(layout, nil))
    end

    test "a portable run next to an installed copy reports nothing", %{layout: layout, app: app} do
      installed = entry(:hkcu, "OpenPairingsApp", setup_exe_entry(app))
      assert [] = UninstallEntries.plan([installed], context(layout, nil))
    end

    test "the old directory with no data left in it is only an old program folder", %{
      layout: layout
    } do
      File.mkdir_p!(Path.join(layout.legacy, "current"))
      old = entry(:hkcu, "OpenPairings", setup_exe_entry(layout.legacy, "0.54.0"))

      # Not :endangers_data: nothing of the arbiter's is there. Still a dead
      # entry for a copy that is not running, but its directory exists, so
      # with no running install it is simply left.
      assert [] = UninstallEntries.plan([old], context(layout, nil))
    end

    test "running from inside the old directory: its own entry is reported, never removed",
         %{layout: layout} do
      File.mkdir_p!(Path.join(layout.legacy, "current"))
      File.write!(Path.join(layout.legacy, "openpairings.db"), "stale copy")
      own = entry(:hkcu, "OpenPairings", setup_exe_entry(layout.legacy))

      assert [{:report, :own_entry_endangers_data, ^own}] =
               UninstallEntries.plan(
                 [own],
                 context(layout, %{root: layout.legacy, kind: :setup_exe, scope: :user})
               )
    end

    test "compares paths the way Windows does", %{layout: layout, app: app} do
      shouty = app |> String.upcase() |> String.replace("/", "\\")
      own = entry(:hkcu, "OpenPairingsApp", setup_exe_entry(shouty <> "\\", "0.62.0"))

      assert [] =
               UninstallEntries.plan(
                 [own],
                 context(layout, %{root: app, kind: :setup_exe, scope: :user})
               )
    end
  end

  describe "read_all/1" do
    test "reads only the four known keys, and only OpenPairings' own" do
      store =
        MemoryStore.start(%{
          {:hkcu, "OpenPairingsApp"} => %{"DisplayName" => "OpenPairings"},
          {:hkcu, "OpenPairings"} => %{"DisplayName" => "Somebody Else's OpenPairings"},
          {:hkcu, "SomethingElse"} => %{"DisplayName" => "OpenPairings"},
          {:hklm, "MSI:OpenPairingsApp"} => %{"DisplayName" => "OpenPairings"}
        })

      found = store |> UninstallEntries.read_all() |> Enum.map(&{&1.root, &1.key}) |> Enum.sort()
      assert found == [{:hkcu, "OpenPairingsApp"}, {:hklm, "MSI:OpenPairingsApp"}]
    end
  end

  describe "apply_actions/2" do
    test "a removal backs every value up, reads it back, and only then deletes", %{layout: layout} do
      values = setup_exe_entry(layout.home)
      store = MemoryStore.start(%{{:hkcu, "OpenPairings"} => values})
      e = entry(:hkcu, "OpenPairings", values)

      capture_log(fn ->
        assert [] = UninstallEntries.apply_actions([{:remove, e, :endangers_data}], store)
      end)

      state = MemoryStore.dump(store)
      assert state.log == [{:put, :backup, "OpenPairings"}, {:delete, :hkcu, "OpenPairings"}]
      refute Map.has_key?(state.keys, {:hkcu, "OpenPairings"})

      backup = state.keys[{:backup, "OpenPairings"}]
      assert Map.take(backup, Map.keys(values)) == values
      assert backup["OpenPairingsRemovedBecause"] == "endangers_data"
    end

    test "if the backup cannot be written, nothing is deleted", %{layout: layout} do
      values = setup_exe_entry(layout.home)
      store = MemoryStore.start(%{{:hkcu, "OpenPairings"} => values}, {:put, :backup})
      e = entry(:hkcu, "OpenPairings", values)

      capture_log(fn ->
        assert [{{:could_not_remove, _}, ^e}] =
                 UninstallEntries.apply_actions([{:remove, e, :endangers_data}], store)
      end)

      assert MemoryStore.dump(store).keys[{:hkcu, "OpenPairings"}] == values
    end

    test "a failed delete leaves the backup, and running again finishes the job", %{
      layout: layout
    } do
      values = setup_exe_entry(layout.home)
      e = entry(:hkcu, "OpenPairings", values)
      store = MemoryStore.start(%{{:hkcu, "OpenPairings"} => values}, {:delete, :hkcu})

      capture_log(fn ->
        UninstallEntries.apply_actions([{:remove, e, :endangers_data}], store)
      end)

      state = MemoryStore.dump(store)
      assert state.keys[{:hkcu, "OpenPairings"}] == values
      assert state.keys[{:backup, "OpenPairings"}]["DisplayName"] == "OpenPairings"

      {MemoryStore, %{agent: pid}} = store
      Agent.update(pid, &%{&1 | fail: nil})

      capture_log(fn ->
        assert [] = UninstallEntries.apply_actions([{:remove, e, :endangers_data}], store)
      end)

      refute Map.has_key?(MemoryStore.dump(store).keys, {:hkcu, "OpenPairings"})
    end

    test "sets a stale version and returns reports untouched", %{app: app} do
      own = entry(:hkcu, "OpenPairingsApp", setup_exe_entry(app, "0.58.1"))
      other = entry(:hklm, "MSI:OpenPairingsApp", msi_entry(app))
      store = MemoryStore.start(%{{:hkcu, "OpenPairingsApp"} => own.values})

      assert [{:installed_twice, ^other}] =
               UninstallEntries.apply_actions(
                 [{:set_version, own, "0.62.0"}, {:report, :installed_twice, other}],
                 store
               )

      assert MemoryStore.dump(store).keys[{:hkcu, "OpenPairingsApp"}]["DisplayVersion"] ==
               "0.62.0"
    end

    test "never deletes outside HKCU, even when asked", %{layout: layout} do
      values = msi_entry(layout.home)
      store = MemoryStore.start(%{{:hklm, "MSI:OpenPairingsApp"} => values})
      e = entry(:hklm, "MSI:OpenPairingsApp", values)

      # plan/2 never produces this; the store call must still be impossible.
      assert_raise FunctionClauseError, fn ->
        UninstallEntries.apply_actions([{:remove, e, :endangers_data}], store)
      end

      assert MemoryStore.dump(store).keys[{:hklm, "MSI:OpenPairingsApp"}] == values
    end
  end

  describe "install_from_release_root/1" do
    test "reads the install kind from Velopack's own marker", %{app: app} do
      File.write!(Path.join(app, "Update.exe"), "")

      assert %{kind: :setup_exe, scope: :user} =
               UninstallEntries.install_from_release_root(Path.join(app, "current"))

      File.write!(Path.join(app, ".msi-installed"), "")

      assert %{kind: :msi, root: root} =
               UninstallEntries.install_from_release_root(Path.join(app, "current"))

      assert DataHome.same_path?(root, app)
    end

    test "is nil for anything that is not a Velopack install", %{app: app} do
      assert UninstallEntries.install_from_release_root(nil) == nil
      assert UninstallEntries.install_from_release_root(Path.join(app, "current")) == nil
      assert UninstallEntries.install_from_release_root(app) == nil
    end
  end
end
