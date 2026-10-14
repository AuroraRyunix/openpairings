defmodule PairingsEngine.Desktop.MacosTest do
  @moduledoc """
  OpenPairings.app keeps its data where no update and no uninstall reaches:
  `~/Library/Application Support/OpenPairings`, never inside an app bundle.

  The same rule Windows learned by losing a database (see
  `PairingsEngine.Desktop.DataHome`), held here in three places that do not
  trust each other: `config/runtime.exs` refuses a data folder inside any
  `.app`, the launcher names the same default the runtime computes, and no
  script that builds or starts the app removes anything from the data
  folder. Nothing here needs a Mac; every check reads files or evaluates
  the runtime configuration against a scratch directory.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO, only: [with_io: 1]

  @root Path.expand("../../..", __DIR__)
  @runtime Path.join(@root, "config/runtime.exs")

  defp read(path), do: File.read!(Path.join(@root, path))

  defp read_runtime(data_dir) do
    vars = %{
      "OPENPAIRINGS_LOCAL" => "1",
      "OPENPAIRINGS_DATA_DIR" => data_dir,
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

  describe "config/runtime.exs" do
    @tag :tmp_dir
    test "refuses a data folder inside an app bundle, before creating it", %{tmp_dir: dir} do
      for bad <- [
            Path.join([dir, "OpenPairings.app", "Contents", "data"]),
            Path.join([dir, "Applications", "OpenPairings.app"]),
            Path.join([dir, "Other.APP", "x"])
          ] do
        assert_raise RuntimeError, ~r/will not keep its data/, fn -> read_runtime(bad) end
        refute File.exists?(bad)
      end
    end

    @tag :tmp_dir
    test "takes a folder that only looks alike", %{tmp_dir: dir} do
      for good <- [Path.join(dir, "OpenPairings"), Path.join(dir, "apps.application")] do
        config = read_runtime(good)

        assert Path.dirname(config[:pairings_engine][PairingsEngine.Repo][:database]) ==
                 good
      end
    end
  end

  describe "where the data goes on a Mac" do
    test "the default is Application Support/OpenPairings, outside any bundle" do
      default =
        :filename.basedir(:user_data, ~c"OpenPairings", %{os: :darwin}) |> to_string()

      assert String.ends_with?(default, "Library/Application Support/OpenPairings")
      refute default =~ ~r/\.app(\/|$)/i
    end

    test "the launcher names the same folder, and moves it nowhere" do
      launcher = read("rel/macos/launcher.sh")

      assert launcher =~
               ~s(data=${OPENPAIRINGS_DATA_DIR:-"$HOME/Library/Application Support/OpenPairings"})

      # What the release writes at start goes to the temporary folder and the
      # data folder, never into the (possibly read-only) bundle.
      assert launcher =~ ~s(export RELEASE_TMP="${TMPDIR:-/tmp}/OpenPairings")
      assert launcher =~ ~s(cd "$data")
      assert launcher =~ "export OPENPAIRINGS_LOCAL=1"
      assert launcher =~ ~s(export RELEASE_DISTRIBUTION="${RELEASE_DISTRIBUTION:-none}")
    end

    test "no macOS script removes anything but its own scratch files" do
      for name <- ~w(launcher.sh build_app.sh sign_and_notarize.sh),
          line <- String.split(read("rel/macos/#{name}"), "\n"),
          line = String.trim(line),
          line =~ ~r/\brm\b/ and not String.starts_with?(line, "#") do
        refute line =~ "$data", "rel/macos/#{name} removes the data: #{line}"
        refute line =~ "Application Support", "rel/macos/#{name} removes the data: #{line}"
      end
    end
  end

  describe "the bundle" do
    test "the plist names the executable the build script writes" do
      plist = read("rel/macos/Info.plist")
      build = read("rel/macos/build_app.sh")

      assert [_, exe] =
               Regex.run(~r{<key>CFBundleExecutable</key>\s*<string>([^<]+)</string>}, plist)

      # The executable is the compiled Swift launcher; the script that
      # starts the server sits beside the release as a resource.
      assert build =~ ~s(-o "$app/Contents/MacOS/#{exe}" "$swift_source")
      assert build =~ "-target arm64-apple-macos11"
      assert build =~ ~s(cp "$here/launcher.sh" "$app/Contents/Resources/launcher.sh")
      # The data folder is not named after anything an installer would own.
      refute plist =~ "OpenPairingsData"
    end

    test "the app has a Dock icon" do
      # LSUIElement hides the app from the Dock and Cmd-Tab, which is what
      # the shell-script version did and what this one exists to undo.
      refute read("rel/macos/Info.plist") =~ "LSUIElement"
    end

    test "the Swift launcher runs launcher.sh and agrees with it on the data folder" do
      swift = read("rel/macos/Launcher.swift")

      assert swift =~ ~s(let defaultDataFolder = "Library/Application Support/OpenPairings")
      assert swift =~ ~s(let dataEnv = "OPENPAIRINGS_DATA_DIR")
      assert swift =~ ~s(let releaseInResources = "app/bin/pairings_engine_portable")
      assert swift =~ ~s(appendingPathComponent("launcher.sh"))
      # CI starts the bundle's own executable this way.
      assert swift =~ ~s(let headlessEnv = "OPENPAIRINGS_LAUNCHER_NO_UI")
      assert swift =~ ~s(contains("--headless"))
      assert read(".github/workflows/binaries.yml") =~ ~s("$launcher" --headless)
      # Nothing but AppKit and Foundation: the build has swiftc and the SDK.
      imports = Regex.scan(~r/^import (\w+)$/m, swift, capture: :all_but_first)
      assert Enum.sort(List.flatten(imports)) == ["AppKit", "Foundation"]
    end

    test "the shell scripts have Unix line endings" do
      for file <- Path.wildcard(Path.join(@root, "rel/macos/*.sh")) do
        refute File.read!(file) =~ "\r", "#{file} has CRLF line endings"
        assert String.starts_with?(File.read!(file), "#!/bin/sh\n")
      end
    end
  end
end
