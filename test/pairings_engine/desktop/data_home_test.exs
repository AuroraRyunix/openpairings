defmodule PairingsEngine.Desktop.DataHomeTest do
  @moduledoc """
  The move of a Windows install's data out of every installer's reach.

  Everything runs against a fake `%LOCALAPPDATA%` in the system temp
  directory. Nothing here reads or writes the real one.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PairingsEngine.Desktop.DataHome

  setup do
    lad = Path.join(System.tmp_dir!(), "op_lad_#{System.unique_integer([:positive])}")
    File.mkdir_p!(lad)
    on_exit(fn -> File.rm_rf(lad) end)
    %{lad: lad, layout: DataHome.layout(lad)}
  end

  # A real SQLite database in WAL mode with rows still in the -wal file, so
  # a copy that read the main file alone would come up short.
  defp make_database(dir, rows \\ 25) do
    File.mkdir_p!(dir)
    path = Path.join(dir, "openpairings.db")
    {:ok, conn} = Exqlite.Sqlite3.open(path)
    :ok = Exqlite.Sqlite3.execute(conn, "PRAGMA journal_mode = WAL")
    :ok = Exqlite.Sqlite3.execute(conn, "PRAGMA wal_autocheckpoint = 0")

    :ok =
      Exqlite.Sqlite3.execute(
        conn,
        "CREATE TABLE tournaments (id INTEGER PRIMARY KEY, name TEXT)"
      )

    :ok =
      Exqlite.Sqlite3.execute(conn, "CREATE TABLE players (id INTEGER PRIMARY KEY, name TEXT)")

    for i <- 1..rows do
      :ok = Exqlite.Sqlite3.execute(conn, "INSERT INTO tournaments (name) VALUES ('t#{i}')")
      :ok = Exqlite.Sqlite3.execute(conn, "INSERT INTO players (name) VALUES ('p#{i}')")
    end

    {conn, path}
  end

  defp count(path, table) do
    {:ok, conn} = Exqlite.Sqlite3.open(path)
    {:ok, st} = Exqlite.Sqlite3.prepare(conn, "SELECT count(*) FROM #{table}")
    {:ok, [[n]]} = Exqlite.Sqlite3.fetch_all(conn, st)
    Exqlite.Sqlite3.release(conn, st)
    Exqlite.Sqlite3.close(conn)
    n
  end

  defp seed_legacy(%{legacy: legacy}) do
    File.mkdir_p!(Path.join(legacy, "backups"))
    File.write!(Path.join(legacy, "openpairings.db"), "not really a database, but bytes")
    File.write!(Path.join(legacy, "secret_key_base"), String.duplicate("s", 64))
    File.write!(Path.join(legacy, "openpairings-takedowns.jsonl"), ~s({"t":1}\n))
    File.write!(Path.join([legacy, "backups", "2026-09-01.db"]), "backup one")
  end

  describe "choose/1, the decision config/runtime.exs repeats" do
    test "a fresh machine gets the new directory", %{layout: layout} do
      assert DataHome.choose(layout) == layout.home
    end

    test "data still in the old directory is read there until it moves", %{layout: layout} do
      seed_legacy(layout)
      assert DataHome.choose(layout) == layout.legacy
    end

    test "once the new directory exists it wins, whatever is in the old one", %{layout: layout} do
      seed_legacy(layout)
      File.mkdir_p!(layout.home)
      assert DataHome.choose(layout) == layout.home
    end

    test "an old directory with no data in it is not a reason to stay", %{layout: layout} do
      File.mkdir_p!(layout.legacy)
      File.write!(Path.join(layout.legacy, "launcher.log"), "log")
      File.mkdir_p!(Path.join(layout.legacy, "current"))
      assert DataHome.choose(layout) == layout.home
    end
  end

  describe "secure/2" do
    test "renames the old directory, and every byte comes along", %{layout: layout} do
      seed_legacy(layout)
      before = snapshot(layout.legacy)

      {{:renamed, home}, _log} = with_log(fn -> DataHome.secure(layout) end)

      assert home == layout.home
      refute File.exists?(layout.legacy)
      assert snapshot(layout.home) == before
    end

    test "leaves a new directory that already exists alone, and the old one too", %{
      layout: layout
    } do
      seed_legacy(layout)
      File.mkdir_p!(layout.home)
      before = snapshot(layout.legacy)

      assert {:already, home} = DataHome.secure(layout)
      assert home == layout.home
      assert snapshot(layout.legacy) == before
    end

    test "a fresh machine gets an empty new directory", %{layout: layout} do
      assert {:fresh, home} = DataHome.secure(layout)
      assert File.dir?(home)
      refute File.exists?(layout.legacy)
    end

    test "is idempotent: a second start finds the move done", %{layout: layout} do
      seed_legacy(layout)
      capture_log(fn -> DataHome.secure(layout) end)
      before = snapshot(layout.home)

      assert {:already, _} = DataHome.secure(layout)
      assert snapshot(layout.home) == before
    end

    test "when the rename cannot happen, falls back to the old directory and changes nothing",
         %{layout: layout} do
      seed_legacy(layout)
      before = snapshot(layout.legacy)
      # Something already at the new name that is not a directory: the rename
      # must fail, which is the stand-in for "a file inside is held open".
      File.write!(layout.home, "in the way")

      {{{:fallback, _}, home}, log} = with_log(fn -> DataHome.secure(layout) end)

      assert home == layout.legacy
      assert snapshot(layout.legacy) == before
      assert File.read!(layout.home) == "in the way"
      assert log =~ "trying again next start"
    end

    if match?({:win32, _}, :os.type()) do
      # The claim the whole design rests on, checked rather than assumed: a
      # directory holding an open SQLite database cannot be renamed on
      # Windows, so a running OpenPairings (any version) is never moved out
      # from under itself. SQLite opens without FILE_SHARE_DELETE.
      test "an open database blocks the rename, and the running connection keeps working",
           %{layout: layout} do
        {conn, db} = make_database(layout.legacy, 10)

        {{{:fallback, _}, home}, _log} = with_log(fn -> DataHome.secure(layout) end)

        assert home == layout.legacy
        refute File.exists?(layout.home)
        :ok = Exqlite.Sqlite3.execute(conn, "INSERT INTO players (name) VALUES ('late')")
        Exqlite.Sqlite3.close(conn)
        assert count(db, "players") == 11

        # And with it closed, the next start moves it.
        {{:renamed, _}, _log} = with_log(fn -> DataHome.secure(layout) end)
        assert count(Path.join(layout.home, "openpairings.db"), "players") == 11
      end
    end

    test "running from inside the old directory copies instead, but never over something in the way",
         %{layout: layout} do
      {conn, _} = make_database(layout.legacy)
      Exqlite.Sqlite3.close(conn)
      File.write!(layout.home, "in the way")

      capture_log(fn ->
        assert {{:fallback, _}, home} =
                 DataHome.secure(layout, running_from: Path.join(layout.legacy, "current"))

        assert home == layout.legacy
      end)

      assert File.read!(layout.home) == "in the way"
      assert count(Path.join(layout.legacy, "openpairings.db"), "players") == 25
      assert staging_dirs(layout) == []
    end
  end

  describe "copy_verify_switch/1" do
    test "copies through SQLite, checks it, and commits by renaming; the original stays",
         %{layout: layout} do
      {conn, db} = make_database(layout.legacy, 40)
      File.write!(Path.join(layout.legacy, "secret_key_base"), String.duplicate("k", 64))
      File.write!(Path.join(layout.legacy, "openpairings-takedowns.jsonl"), "x\n")
      File.mkdir_p!(Path.join(layout.legacy, "current"))
      File.write!(Path.join(layout.legacy, "Update.exe"), "program")

      # Still open, with autocheckpoint off: the rows are in the -wal file,
      # so a copy of openpairings.db's bytes alone would be missing them.
      assert File.stat!(db <> "-wal").size > 0
      secret_before = File.read!(Path.join(layout.legacy, "secret_key_base"))

      capture_log(fn -> assert :ok = DataHome.copy_verify_switch(layout) end)
      Exqlite.Sqlite3.close(conn)

      copied = Path.join(layout.home, "openpairings.db")
      assert count(copied, "players") == 40
      assert count(copied, "tournaments") == 40
      assert File.read!(Path.join(layout.home, "secret_key_base")) == secret_before
      assert File.read!(Path.join(layout.home, "openpairings-takedowns.jsonl")) == "x\n"
      assert File.exists?(Path.join(layout.home, "MOVED-FROM.txt"))
      refute File.exists?(Path.join(layout.home, ".openpairings-staging"))
      # Program files are what is running; they are not data and stay put.
      refute File.exists?(Path.join(layout.home, "Update.exe"))
      refute File.exists?(Path.join(layout.home, "current"))

      # The original, untouched apart from a note saying where things went.
      assert count(db, "players") == 40
      assert File.read!(Path.join(layout.legacy, "secret_key_base")) == secret_before
      assert File.exists?(Path.join(layout.legacy, "DATA-MOVED.txt"))
      assert staging_dirs(layout) == []
    end
  end

  describe "remove_staging/2, the only recursive delete" do
    defp staging(layout, sentinel? \\ true) do
      dir =
        Path.join(layout.parent, "OpenPairingsData.staging-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      if sentinel?, do: File.write!(Path.join(dir, ".openpairings-staging"), "")
      File.write!(Path.join(dir, "openpairings.db"), "copy")
      dir
    end

    test "removes a real staging directory", %{layout: layout} do
      dir = staging(layout)
      assert :ok = DataHome.remove_staging(layout, dir)
      refute File.exists?(dir)
    end

    test "refuses the data directory, the old one, the backups, and their parent, whatever they hold",
         %{layout: layout} do
      for dir <- [layout.home, layout.legacy, layout.backups] do
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, ".openpairings-staging"), "")
        File.write!(Path.join(dir, "openpairings.db"), "precious")
      end

      for dir <- [layout.home, layout.legacy, layout.backups, layout.parent] do
        assert {:error, :refused} = DataHome.remove_staging(layout, dir), "removed #{dir}"
      end

      for dir <- [layout.home, layout.legacy, layout.backups] do
        assert File.read!(Path.join(dir, "openpairings.db")) == "precious"
      end
    end

    test "refuses a staging-named directory without the sentinel", %{layout: layout} do
      dir = staging(layout, false)
      assert {:error, :refused} = DataHome.remove_staging(layout, dir)
      assert File.exists?(Path.join(dir, "openpairings.db"))
    end

    test "refuses a staging-named directory anywhere but directly in %LOCALAPPDATA%", %{
      layout: layout
    } do
      nested = Path.join([layout.home, "OpenPairingsData.staging-1"])
      File.mkdir_p!(nested)
      File.write!(Path.join(nested, ".openpairings-staging"), "")

      assert {:error, :refused} = DataHome.remove_staging(layout, nested)
      assert File.exists?(nested)
    end

    test "secure/2 clears a crashed copy's staging directory and nothing else", %{layout: layout} do
      leftover = staging(layout)
      unfinished = staging(layout, false)
      File.mkdir_p!(layout.home)

      DataHome.secure(layout)

      refute File.exists?(leftover)
      assert File.exists?(unfinished)
      assert File.dir?(layout.home)
    end
  end

  describe "move_backups/1" do
    test "moves the whole folder when there is none yet", %{layout: layout} do
      seed_legacy(layout)
      capture_log(fn -> DataHome.secure(layout) end)

      capture_log(fn -> assert :ok = DataHome.move_backups(layout) end)

      assert File.read!(Path.join(layout.backups, "2026-09-01.db")) == "backup one"
      refute File.exists?(Path.join(layout.home, "backups"))
    end

    test "merges file by file, and never overwrites a name already there", %{layout: layout} do
      File.mkdir_p!(Path.join(layout.home, "backups"))
      File.mkdir_p!(layout.backups)
      File.write!(Path.join([layout.home, "backups", "a.db"]), "from home")
      File.write!(Path.join([layout.home, "backups", "same.db"]), "home's copy")
      File.write!(Path.join(layout.backups, "same.db"), "already there")

      assert :ok = DataHome.move_backups(layout)

      assert File.read!(Path.join(layout.backups, "a.db")) == "from home"
      assert File.read!(Path.join(layout.backups, "same.db")) == "already there"
      # The one it could not move is still where it was.
      assert File.read!(Path.join([layout.home, "backups", "same.db"])) == "home's copy"
    end

    test "takes backups out of an old directory that could not move", %{layout: layout} do
      seed_legacy(layout)
      capture_log(fn -> assert :ok = DataHome.move_backups(layout) end)

      assert File.read!(Path.join(layout.backups, "2026-09-01.db")) == "backup one"
      assert File.read!(Path.join(layout.legacy, "openpairings.db")) =~ "bytes"
    end
  end

  describe "tidy_program_files/1" do
    test "moves an old install's program files into one folder, beside the data", %{
      layout: layout
    } do
      File.mkdir_p!(Path.join([layout.home, "current", "bin"]))
      File.mkdir_p!(Path.join(layout.home, "packages"))
      File.write!(Path.join(layout.home, "Update.exe"), "u")
      File.write!(Path.join(layout.home, "OpenPairings.exe"), "stub")
      File.write!(Path.join(layout.home, "openpairings.db"), "data")

      assert :ok = DataHome.tidy_program_files(layout.home)

      old = Path.join(layout.home, "old-program-files")
      assert File.dir?(Path.join([old, "current", "bin"]))
      assert File.exists?(Path.join(old, "Update.exe"))
      assert File.exists?(Path.join(old, "OpenPairings.exe"))
      assert File.read!(Path.join(layout.home, "openpairings.db")) == "data"
    end

    test "does nothing to a folder that is not shaped like an install", %{layout: layout} do
      File.mkdir_p!(layout.home)
      File.write!(Path.join(layout.home, "OpenPairings.exe"), "not an install on its own")

      assert :ok = DataHome.tidy_program_files(layout.home)
      assert File.exists?(Path.join(layout.home, "OpenPairings.exe"))
      refute File.exists?(Path.join(layout.home, "old-program-files"))
    end
  end

  if match?({:win32, _}, :os.type()) do
    describe "config/runtime.exs on Windows" do
      import ExUnit.CaptureIO, only: [with_io: 1]

      @runtime Path.expand("../../../config/runtime.exs", __DIR__)

      defp read_runtime(lad) do
        vars = %{
          "OPENPAIRINGS_LOCAL" => "1",
          "LOCALAPPDATA" => lad,
          "OPENPAIRINGS_DATA_DIR" => nil,
          "BACKUP_DIR" => nil,
          "DATABASE_PATH" => nil
        }

        previous = Map.new(vars, fn {k, _} -> {k, System.get_env(k)} end)

        Enum.each(vars, fn
          {k, nil} -> System.delete_env(k)
          {k, v} -> System.put_env(k, v)
        end)

        try do
          {config, _} = with_io(fn -> Config.Reader.read!(@runtime, env: :prod) end)
          config
        after
          Enum.each(previous, fn
            {k, nil} -> System.delete_env(k)
            {k, v} -> System.put_env(k, v)
          end)
        end
      end

      defp database_dir(config),
        do:
          config[:pairings_engine][PairingsEngine.Repo][:database]
          |> Path.dirname()
          |> DataHome.normal()

      test "agrees with choose/1 on a fresh machine, and points backups at their own directory",
           %{lad: lad, layout: layout} do
        config = read_runtime(lad)

        assert database_dir(config) == DataHome.normal(DataHome.choose(layout))
        assert database_dir(config) == DataHome.normal(layout.home)

        assert DataHome.normal(config[:pairings_engine][:backup_dir]) ==
                 DataHome.normal(layout.backups)

        assert DataHome.same_path?(
                 config[:pairings_engine][:windows_data_layout].legacy,
                 layout.legacy
               )
      end

      test "agrees with choose/1 while the data is still in the old directory", %{
        lad: lad,
        layout: layout
      } do
        seed_legacy(layout)
        config = read_runtime(lad)

        assert database_dir(config) == DataHome.normal(layout.legacy)
        # Chose, did not move: the move is never done from runtime.exs.
        assert File.exists?(Path.join(layout.legacy, "openpairings.db"))
        refute File.exists?(layout.home)
      end

      test "agrees with choose/1 once the data has moved", %{lad: lad, layout: layout} do
        seed_legacy(layout)
        File.mkdir_p!(layout.home)

        assert database_dir(read_runtime(lad)) == DataHome.normal(layout.home)
      end
    end
  end

  defp snapshot(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Map.new(fn path -> {Path.relative_to(path, dir), File.read!(path)} end)
  end

  defp staging_dirs(%{parent: parent}) do
    parent |> File.ls!() |> Enum.filter(&String.starts_with?(&1, "OpenPairingsData.staging-"))
  end
end
