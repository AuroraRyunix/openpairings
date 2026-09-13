defmodule PairingsEngine.Desktop.HousekeepingTest do
  @moduledoc """
  The desktop start's steps in order, against a fake `%LOCALAPPDATA%`, with
  no registry (see `PairingsEngine.Desktop.RegistryTest` for the run with
  one), and the guard on the one delete it does to program files.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PairingsEngine.Desktop.{DataHome, Housekeeping}

  setup do
    lad = Path.join(System.tmp_dir!(), "op_hk_#{System.unique_integer([:positive])}")
    File.mkdir_p!(lad)
    previous_repo = Application.get_env(:pairings_engine, PairingsEngine.Repo)

    on_exit(fn ->
      Application.put_env(:pairings_engine, PairingsEngine.Repo, previous_repo)
      File.rm_rf(lad)
    end)

    %{lad: lad, layout: DataHome.layout(lad), previous_repo: previous_repo}
  end

  test "is a no-op unless runtime.exs recorded the Windows layout" do
    assert Application.get_env(:pairings_engine, :windows_data_layout) == nil
    assert :ok = Housekeeping.run()
  end

  test "moves the data, points the database at it, then moves the backups",
       %{layout: layout} = ctx do
    File.mkdir_p!(Path.join(layout.legacy, "backups"))
    File.write!(Path.join(layout.legacy, "openpairings.db"), "db")
    File.write!(Path.join([layout.legacy, "backups", "one.db"]), "b")

    Application.put_env(
      :pairings_engine,
      PairingsEngine.Repo,
      Keyword.put(ctx.previous_repo, :database, Path.join(layout.legacy, "openpairings.db"))
    )

    capture_log(fn -> assert :ok = Housekeeping.run(layout, registry: nil) end)

    assert %{outcome: :renamed, reports: []} = Housekeeping.result()
    database = Application.get_env(:pairings_engine, PairingsEngine.Repo)[:database]
    assert DataHome.same_path?(database, Path.join(layout.home, "openpairings.db"))
    assert File.read!(database) == "db"
    assert File.read!(Path.join(layout.backups, "one.db")) == "b"
  end

  test "a move that cannot happen leaves the database where runtime.exs pointed it",
       %{layout: layout} = ctx do
    File.mkdir_p!(layout.legacy)
    File.write!(Path.join(layout.legacy, "openpairings.db"), "db")
    File.write!(layout.home, "in the way")
    legacy_db = Path.join(layout.legacy, "openpairings.db")

    Application.put_env(
      :pairings_engine,
      PairingsEngine.Repo,
      Keyword.put(ctx.previous_repo, :database, legacy_db)
    )

    capture_log(fn -> assert :ok = Housekeeping.run(layout, registry: nil) end)

    assert %{outcome: {:fallback, _}} = Housekeeping.result()
    assert Application.get_env(:pairings_engine, PairingsEngine.Repo)[:database] == legacy_db
    assert File.read!(legacy_db) == "db"
  end

  describe "clear_set_aside_trees/3" do
    setup %{lad: lad} do
      root = Path.join(lad, "OpenPairingsApp")
      current = Path.join(root, "current")
      File.mkdir_p!(current)
      File.write!(Path.join(root, "Update.exe"), "")
      File.write!(Path.join(root, ".msi-installed"), "")
      %{root: root, current: current, install: %{root: root, kind: :msi, scope: :user}}
    end

    defp tree(path) do
      File.mkdir_p!(Path.join(path, "bin"))
      File.write!(Path.join([path, "bin", "erl.exe"]), "old")
      path
    end

    test "removes what the .msi set aside", %{
      layout: layout,
      install: install,
      root: root,
      current: current
    } do
      aside = tree(Path.join(root, "current.before-msi-12345"))
      assert :ok = Housekeeping.clear_set_aside_trees(layout, install, current)
      refute File.exists?(aside)
      assert File.dir?(current)
    end

    test "refuses everything else", %{
      layout: layout,
      install: install,
      root: root,
      current: current
    } do
      for dir <- [layout.home, layout.legacy, layout.backups] do
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, "openpairings.db"), "precious")
      end

      refused = [
        # the tree this process is running from
        current,
        # the right name, one level too deep
        tree(Path.join([root, "packages", "current.before-msi-1"])),
        # a different name
        tree(Path.join(root, "current-before-msi-1")),
        # the data, the old data, the backups, and what holds them
        layout.home,
        layout.legacy,
        layout.backups,
        layout.parent,
        root
      ]

      for path <- refused do
        refute Housekeeping.set_aside_removable?(layout, install, current, path),
               "would remove #{path}"
      end

      # And a running Setup.exe install never clears anything.
      aside = tree(Path.join(root, "current.before-msi-9"))

      refute Housekeeping.set_aside_removable?(
               layout,
               %{install | kind: :setup_exe},
               current,
               aside
             )

      assert :ok =
               Housekeeping.clear_set_aside_trees(layout, %{install | kind: :setup_exe}, current)

      assert File.exists?(aside)

      for dir <- [layout.home, layout.legacy, layout.backups] do
        assert File.read!(Path.join(dir, "openpairings.db")) == "precious"
      end
    end

    test "refuses a set-aside name when it is the running tree", %{
      layout: layout,
      install: install,
      root: root
    } do
      running = tree(Path.join(root, "current.before-msi-7"))

      refute Housekeeping.set_aside_removable?(
               layout,
               install,
               Path.join(running, "releases"),
               running
             )

      assert :ok = Housekeeping.clear_set_aside_trees(layout, install, running)
      assert File.exists?(running)
    end
  end
end
