defmodule PairingsEngine.Desktop.LauncherGuardTest do
  @moduledoc """
  `OpenPairings.exe --protect-data`, the guard the `.msi` runs before it
  removes an older product - built from `rel/windows/launcher.c` by
  `build_launcher.ps1` into a temp directory, and run against a fake
  `%LOCALAPPDATA%`.

  Needs Windows and Zig; with either missing this module holds no tests (CI
  builds the launcher in `binaries.yml` and does not run the Elixir suite on
  Windows). Never started without `--protect-data`: that would open the
  launcher's window and start a server.
  """
  use ExUnit.Case, async: false

  @zig System.find_executable("zig")

  if match?({:win32, _}, :os.type()) and @zig do
    @moduletag timeout: 180_000

    setup_all do
      dir = Path.join(System.tmp_dir!(), "op_launcher_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      exe = Path.join(dir, "OpenPairings.exe")
      script = Path.expand("../../../rel/windows/build_launcher.ps1", __DIR__)

      {out, status} =
        System.cmd(
          "powershell",
          ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script, "-OutputPath", exe],
          stderr_to_stdout: true
        )

      if status != 0, do: raise("build_launcher.ps1 failed:\n" <> out)
      on_exit(fn -> File.rm_rf(dir) end)
      %{exe: exe}
    end

    setup do
      lad = Path.join(System.tmp_dir!(), "op_guard_lad_#{System.unique_integer([:positive])}")
      File.mkdir_p!(lad)
      on_exit(fn -> File.rm_rf(lad) end)

      %{
        lad: lad,
        legacy: Path.join(lad, "OpenPairings"),
        home: Path.join(lad, "OpenPairingsData")
      }
    end

    # The .msi passes "[LocalAppDataFolder]." - a trailing backslash then a
    # dot, so the backslash cannot escape the closing quote. Same here.
    defp guard(exe, lad, extra \\ []) do
      windows_lad = String.replace(lad, "/", "\\") <> "\\."
      {_, status} = System.cmd(exe, ["--protect-data", windows_lad, "--ui-level", "2"] ++ extra)
      status
    end

    test "moves the old directory to the new name, contents and all", %{exe: exe} = ctx do
      File.mkdir_p!(Path.join(ctx.legacy, "backups"))
      File.write!(Path.join(ctx.legacy, "openpairings.db"), "tournaments")
      File.write!(Path.join([ctx.legacy, "backups", "b.db"]), "backup")

      assert guard(exe, ctx.lad) == 0

      refute File.exists?(ctx.legacy)
      assert File.read!(Path.join(ctx.home, "openpairings.db")) == "tournaments"
      assert File.read!(Path.join([ctx.home, "backups", "b.db"])) == "backup"
    end

    test "never moves onto an existing data directory, and leaves both alone",
         %{exe: exe} = ctx do
      File.mkdir_p!(ctx.legacy)
      File.mkdir_p!(ctx.home)
      File.write!(Path.join(ctx.legacy, "openpairings.db"), "old")
      File.write!(Path.join(ctx.home, "openpairings.db"), "new")

      assert guard(exe, ctx.lad) == 0

      assert File.read!(Path.join(ctx.legacy, "openpairings.db")) == "old"
      assert File.read!(Path.join(ctx.home, "openpairings.db")) == "new"
    end

    test "with no data anywhere, creates nothing", %{exe: exe} = ctx do
      File.mkdir_p!(ctx.legacy)
      File.write!(Path.join(ctx.legacy, "launcher.log"), "just a log")

      assert guard(exe, ctx.lad) == 0

      refute File.exists?(ctx.home)
      assert File.exists?(Path.join(ctx.legacy, "launcher.log"))
    end

    test "an open database stops a silent installation, and nothing moves", %{exe: exe} = ctx do
      File.mkdir_p!(ctx.legacy)
      db = Path.join(ctx.legacy, "openpairings.db")
      {:ok, conn} = Exqlite.Sqlite3.open(db)
      :ok = Exqlite.Sqlite3.execute(conn, "CREATE TABLE t (x)")

      try do
        assert guard(exe, ctx.lad) == 3
        refute File.exists?(ctx.home)
        assert File.exists?(db)
      after
        Exqlite.Sqlite3.close(conn)
      end

      assert guard(exe, ctx.lad) == 0
      assert File.exists?(Path.join(ctx.home, "openpairings.db"))
    end

    test "sets a Setup.exe install's program tree aside for the .msi, and only that", %{
      exe: exe,
      lad: lad
    } do
      app = Path.join(lad, "OpenPairingsApp")
      File.mkdir_p!(Path.join([app, "current", "bin"]))
      File.write!(Path.join(app, "Update.exe"), "")

      assert guard(exe, lad, ["--install-folder", String.replace(app, "/", "\\") <> "\\."]) == 0

      refute File.exists?(Path.join(app, "current"))

      assert [aside] =
               app |> File.ls!() |> Enum.filter(&String.starts_with?(&1, "current.before-msi-"))

      assert File.dir?(Path.join([app, aside, "bin"]))

      # An .msi install's own tree is left for the .msi to upgrade.
      File.mkdir_p!(Path.join(app, "current"))
      File.write!(Path.join(app, ".msi-installed"), "")
      assert guard(exe, lad, ["--install-folder", app]) == 0
      assert File.dir?(Path.join(app, "current"))
    end
  end
end
