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
      assert build =~ ~s(-target "$swift_arch-apple-macos$supported")
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
      assert swift =~ ~s[appendingPathComponent("launcher.sh")]
      # CI starts the bundle's own executable this way.
      assert swift =~ ~s(let headlessEnv = "OPENPAIRINGS_LAUNCHER_NO_UI")
      assert swift =~ ~s[contains("--headless")]
      assert read(".github/workflows/binaries.yml") =~ ~s("$launcher" --headless)
      # Nothing but AppKit and Foundation: the build has swiftc and the SDK.
      imports = Regex.scan(~r/^import (\w+)$/m, swift, capture: :all_but_first)
      assert Enum.sort(List.flatten(imports)) == ["AppKit", "Foundation"]
    end

    test "there is no single-file macOS binary: Burrito has no Mac target and CI builds none" do
      mix = read("mix.exs")
      workflow = read(".github/workflows/binaries.yml")

      refute mix =~ ~r/^\s+macos_\w+: \[os: :darwin/m
      assert workflow =~ "if: runner.os != 'macOS'"
      assert workflow =~ "name: Build the single-file binary (Linux and Windows)"
      # The Mac downloads that stay.
      assert workflow =~ "openpairings_app_${{ matrix.target }}.zip"
      assert workflow =~ "openpairings_portable_${{ matrix.target }}.zip"
    end

    test "the Intel Mac build runs for a release and for a person, never for a plain push" do
      workflow = read(".github/workflows/binaries.yml")

      assert workflow =~ "include: ${{ fromJSON(needs.plan.outputs.matrix) }}"

      assert workflow =~
               ~s(if [ "$publish" = true ] || [ "$EVENT" = workflow_dispatch ]; then)

      [before, after_if] =
        String.split(workflow, ~s(if [ "$publish" = true ] || [ "$EVENT"), parts: 2)

      # Added by the plan job under that one condition, and nowhere before it,
      # where the permanent targets are listed.
      assert after_if =~ ~s("runner":"macos-15-intel","target":"macos_x86_64","macos_min":"10.13")
      refute before =~ "macos-15-intel"
      assert before =~ ~s("runner":"macos-15","target":"macos_aarch64","macos_min":"11.0")

      # The release waits for the plan and the build, and names both Mac
      # apps before it publishes.
      assert workflow =~ "needs: [plan, build]"
      assert workflow =~ "openpairings_app_macos_aarch64.zip openpairings_app_macos_x86_64.zip"
    end

    test "the Intel build's Swift runtime is bundled below macOS 10.15" do
      build = read("rel/macos/build_app.sh")
      swift = read("rel/macos/Launcher.swift")

      assert build =~ "swift-stdlib-tool --copy"
      assert build =~ "@executable_path/../Frameworks"

      for guard <- [
            "#available(macOS 10.15, *)",
            "#available(macOS 10.14, *)",
            "#available(macOS 10.15.4, *)"
          ] do
        assert swift =~ guard
      end
    end

    test "the runtime is built for the target's macOS, and a build that is not fails" do
      workflow = read(".github/workflows/binaries.yml")
      build_otp = read("rel/macos/build_otp.sh")
      build_app = read("rel/macos/build_app.sh")

      # The ready-made Erlang for macOS said "15.0"; it is not used there.
      assert workflow =~ "if: runner.os != 'macOS'"
      assert workflow =~ ~s(sh rel/macos/build_otp.sh "$HOME/otp-macos")

      assert workflow =~
               ~s(echo "MACOSX_DEPLOYMENT_TARGET=${{ matrix.macos_min }}" >> "$GITHUB_ENV")

      assert workflow =~ "steps.otp-cache.outputs.cache-hit != 'true'"

      assert [_, otp_key] = Regex.run(~r/path: ~\/otp-macos\n\s+key: (.+)$/m, workflow)

      for part <- ~w(env.OTP_VERSION env.OPENSSL_VERSION env.ELIXIR_VERSION
                     env.MACOSX_DEPLOYMENT_TARGET matrix.runner rel/macos/build_otp.sh) do
        assert otp_key =~ part, "the OTP cache key does not include #{part}"
      end

      # OpenSSL inside crypto, and nothing the arbiter's Mac lacks.
      assert build_otp =~ "--disable-dynamic-ssl-lib"
      assert build_otp =~ "no-shared"
      assert build_otp =~ "--without-wx --without-javac --without-odbc"

      # Every version the workflow names has a checksum in the script.
      for var <- ~w(OTP_VERSION OPENSSL_VERSION ELIXIR_VERSION) do
        assert [_, version] = Regex.run(~r/^\s+#{var}: "([^"]+)"$/m, workflow)

        assert build_otp =~
                 ~r/^\s+#{Regex.escape(version)}(-otp-\d+)?\) \w+_sha256=[0-9a-f]{64} ;;$/m,
               "build_otp.sh has no checksum for #{var} #{version}"
      end

      # The SQLite NIF from source on the Mac, and never from a cache built
      # for another macOS.
      assert workflow =~ ~s(echo "EXQLITE_FORCE_BUILD=true" >> "$GITHUB_ENV")
      assert read("config/config.exs") =~ "config :exqlite, force_build: true"
      assert Regex.match?(~r/_build\/prod\/lib\n\s+key:.*env\.MACOSX_DEPLOYMENT_TARGET/, workflow)

      # A binary that wants newer than the target fails the build, by name.
      assert build_app =~ "supported=${MACOSX_DEPLOYMENT_TARGET:-11.0}"
      assert build_otp =~ "darwin64-x86_64-cc"
      assert build_otp =~ "darwin64-arm64-cc"

      # The smoke test prints and checks what the bundle promises.
      assert workflow =~ "LSMinimumSystemVersion is not ${{ matrix.macos_min }}"
      assert workflow =~ "vtool -show-build"
      assert build_app =~ ~s(newer "$minos" "$supported")
      assert build_app =~ ~s(sed 's/^/  /' "$too_new")
    end

    test "the shell scripts have Unix line endings" do
      for file <- Path.wildcard(Path.join(@root, "rel/macos/*.sh")) do
        refute File.read!(file) =~ "\r", "#{file} has CRLF line endings"
        assert String.starts_with?(File.read!(file), "#!/bin/sh\n")
      end
    end
  end
end
