defmodule PairingsEngine.Desktop.RegistryTest do
  @moduledoc """
  The real `:win32reg` store, and a whole desktop start end to end, against a
  registry subtree this test creates and deletes:
  `HKEY_CURRENT_USER\\Software\\OpenPairingsTest\\<unique>`.

  The real `Uninstall` keys are not reachable from here: every call is given
  roots built below, and `real_roots/0` is only asserted on, never passed.
  Windows only - there is no registry anywhere else, and CI's Linux runner
  compiles this module to a single check that says so.
  """
  use ExUnit.Case, async: false

  alias PairingsEngine.Desktop.{DataHome, Housekeeping, Registry}

  @test_base "\\hkey_current_user\\Software\\OpenPairingsTest"

  test "the real roots are the Uninstall keys, and no test root is" do
    for {_, path} <- Registry.real_roots() do
      refute String.starts_with?(path, @test_base)
    end
  end

  if match?({:win32, _}, :os.type()) do
    import ExUnit.CaptureLog

    setup do
      base = @test_base <> "\\run#{System.unique_integer([:positive])}"

      roots = %{
        hkcu: base <> "\\HKCU\\Uninstall",
        hklm: base <> "\\HKLM\\Uninstall",
        backup: base <> "\\Backup"
      }

      # Guard for the guard: a test root that is not under the test base must
      # never be used, whatever edit is made to the lines above.
      for {_, path} <- roots, do: true = String.starts_with?(path, @test_base <> "\\run")

      on_exit(fn ->
        delete_tree(base)
        delete_base_if_empty()
      end)

      %{roots: roots}
    end

    test "put, read and delete round-trip every value type", %{roots: roots} do
      values = %{
        "DisplayName" => "OpenPairings",
        "NoModify" => 1,
        "EstimatedSize" => {:raw, <<192, 2, 1, 0, 0, 0, 0, 0>>}
      }

      assert :missing = Registry.read(roots, :hkcu, "OpenPairingsApp")
      assert :ok = Registry.put(roots, :hkcu, "OpenPairingsApp", values)
      assert {:ok, ^values} = Registry.read(roots, :hkcu, "OpenPairingsApp")
      assert :ok = Registry.delete(roots, :hkcu, "OpenPairingsApp")
      assert :missing = Registry.read(roots, :hkcu, "OpenPairingsApp")
      assert :ok = Registry.delete(roots, :hkcu, "OpenPairingsApp")
    end

    test "refuses a name that would reach outside its root", %{roots: roots} do
      assert_raise ArgumentError, fn -> Registry.read(roots, :hkcu, "..\\..\\Other") end
    end

    test "a machine in the 2026-09-13 state is put right on the next start", %{roots: roots} do
      lad = Path.join(System.tmp_dir!(), "op_reg_lad_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(lad) end)
      layout = DataHome.layout(lad)

      # The old-id install: its directory IS the data directory.
      File.mkdir_p!(Path.join([layout.legacy, "current"]))
      File.write!(Path.join(layout.legacy, "Update.exe"), "old updater")
      File.write!(Path.join(layout.legacy, "openpairings.db"), "every tournament")
      File.mkdir_p!(Path.join(layout.legacy, "backups"))
      File.write!(Path.join([layout.legacy, "backups", "b1.db"]), "a backup")

      # And the two other entries, for one real install directory.
      app = Path.join(lad, "OpenPairingsApp")
      File.mkdir_p!(app)

      :ok =
        Registry.put(roots, :hkcu, "OpenPairings", %{
          "DisplayName" => "OpenPairings",
          "DisplayVersion" => "0.54.0",
          "InstallLocation" => layout.legacy,
          "UninstallString" => ~s("#{layout.legacy}\\Update.exe" --uninstall)
        })

      :ok =
        Registry.put(roots, :hkcu, "OpenPairingsApp", %{
          "DisplayName" => "OpenPairings",
          "InstallLocation" => app
        })

      previous_repo = Application.get_env(:pairings_engine, PairingsEngine.Repo)

      Application.put_env(
        :pairings_engine,
        PairingsEngine.Repo,
        Keyword.put(previous_repo, :database, Path.join(layout.legacy, "openpairings.db"))
      )

      try do
        capture_log(fn -> assert :ok = Housekeeping.run(layout, registry: {Registry, roots}) end)

        # Data first: moved, and the database path follows it.
        assert File.read!(Path.join(layout.home, "openpairings.db")) == "every tournament"
        assert File.read!(Path.join(layout.backups, "b1.db")) == "a backup"
        refute File.exists?(layout.legacy)

        assert DataHome.same_path?(
                 Application.get_env(:pairings_engine, PairingsEngine.Repo)[:database],
                 Path.join(layout.home, "openpairings.db")
               )

        # The old install's program files, out of the way beside the data.
        assert File.exists?(Path.join([layout.home, "old-program-files", "Update.exe"]))

        # Then the entry: gone from the list, kept in the backup key. (Its
        # directory no longer exists, which is reason enough on its own.)
        assert :missing = Registry.read(roots, :hkcu, "OpenPairings")

        assert {:ok, %{"DisplayVersion" => "0.54.0"}} =
                 Registry.read(roots, :backup, "OpenPairings")

        # A portable run does not judge an installed copy it is not.
        assert {:ok, _} = Registry.read(roots, :hkcu, "OpenPairingsApp")

        assert %{outcome: :renamed} = Housekeeping.result()

        # And the second start changes nothing.
        capture_log(fn -> assert :ok = Housekeeping.run(layout, registry: {Registry, roots}) end)
        assert %{outcome: :already} = Housekeeping.result()
        assert File.read!(Path.join(layout.home, "openpairings.db")) == "every tournament"
      after
        Application.put_env(:pairings_engine, PairingsEngine.Repo, previous_repo)
      end
    end

    defp delete_base_if_empty do
      {:ok, h} = :win32reg.open([:read, :write])

      try do
        with :ok <- :win32reg.change_key(h, String.to_charlist(@test_base)),
             {:ok, []} <- :win32reg.sub_keys(h),
             {:ok, []} <- :win32reg.values(h) do
          :win32reg.delete_key(h)
        end
      after
        :win32reg.close(h)
      end
    end

    defp delete_tree(path) do
      {:ok, h} = :win32reg.open([:read, :write])

      try do
        do_delete_tree(h, path)
      after
        :win32reg.close(h)
      end
    end

    defp do_delete_tree(h, path) do
      # Never anything but the test subtree.
      true = String.starts_with?(path, @test_base <> "\\run")

      case :win32reg.change_key(h, String.to_charlist(path)) do
        :ok ->
          {:ok, subkeys} = :win32reg.sub_keys(h)
          for sub <- subkeys, do: do_delete_tree(h, path <> "\\" <> to_string(sub))
          :ok = :win32reg.change_key(h, String.to_charlist(path))
          :win32reg.delete_key(h)

        {:error, _} ->
          :ok
      end
    end
  end
end
