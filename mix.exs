defmodule PairingsEngine.MixProject do
  use Mix.Project

  def project do
    [
      app: :pairings_engine,
      version: "0.56.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      releases: releases(),
      # There are two releases now, so a bare `mix release` is ambiguous and
      # fails - which broke CI and would have broken the build instructions
      # in docs/binaries.md the same way. The single-file binary is the one
      # you get when you do not say, because it is the one the docs have
      # always described.
      default_release: :pairings_engine,
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Standalone single-file binaries via Burrito - one self-contained
  # executable per OS/arch (x86_64 + aarch64 for macOS, Linux, Windows).
  # Build with `MIX_ENV=prod mix release`; output lands in `burrito_out/`.
  # See docs/binaries.md. Needs Zig + xz on the build machine; cross-target
  # builds are done per-arch in CI (.github/workflows/binaries.yml).
  defp releases do
    [
      pairings_engine: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            macos_x86_64: [os: :darwin, cpu: :x86_64],
            macos_aarch64: [os: :darwin, cpu: :aarch64],
            linux_x86_64: [os: :linux, cpu: :x86_64],
            linux_aarch64: [os: :linux, cpu: :aarch64],
            # No windows_aarch64: Erlang/OTP ships no Windows/ARM runtime to
            # bundle. Windows on ARM emulates the x86_64 binary.
            windows_x86_64: [os: :windows, cpu: :x86_64]
          ]
        ]
      ],
      # The same application, shipped as an ordinary Erlang release: a folder
      # you unzip, with a launcher next to it. No self-extracting stub.
      #
      # This exists because the Burrito binary gets deleted by antivirus.
      # Not "warned about" - Symantec removed it from disk before it ran
      # once. Nothing is wrong with it: an unsigned executable carrying a
      # compressed payload, which unpacks a runtime into AppData and spawns
      # processes, is byte-for-byte what a dropper looks like, and heuristics
      # cannot tell the difference. Code signing is the real answer on
      # Windows and costs money and a hardware token; this costs nothing and
      # works today, because a directory of DLLs and a .bat is not a shape
      # anything hunts for.
      #
      # `include_erts: true` is the default and the point - the runtime ships
      # inside, so there is still nothing to install.
      pairings_engine_portable: [
        applications: [pairings_engine: :permanent],
        steps: [:assemble, &__MODULE__.windows_launcher/1],
        include_executables_for: [:unix, :windows],
        # `bin/pairings_engine_portable start` works, but says nothing about
        # local mode - which a plain release cannot detect, since `__BURRITO`
        # is exactly what it is not. The launchers make it explicit.
        overlays: ["rel/portable"]
      ]
    ]
  end

  @doc false
  # Compiles rel/windows/launcher.c into OpenPairings.exe at the root of the
  # portable release. See that file's header for what it does and why it has to
  # exist at all; this is only about how it gets into the package.
  #
  # A release STEP rather than an overlay, which was the obvious candidate and
  # is the wrong one. `overlays: ["rel/portable"]` copies whatever is in that
  # directory into the release root - so putting the executable there means
  # either committing a binary to the repository, which goes stale silently and
  # cannot be reviewed, or writing a build artifact into a source directory and
  # hoping nobody builds a release without running the script first. A step
  # cannot be forgotten: `mix release pairings_engine_portable` runs it, and
  # that is the only way this release is ever produced.
  #
  # Windows only. macOS and Linux have openpairings.sh and no use for a .exe,
  # and the portable release is built on a native runner per platform anyway.
  #
  # Nothing in here fails the release. Not an absent Zig, and - since 0.56.x -
  # not a Zig that is present and cannot build the launcher either. Both warn,
  # and both name the file that will not exist and what will refuse it.
  #
  # Missing Zig warns because a plain `mix release` on a machine without the
  # documented toolchain should still give you a working portable release -
  # the .bat launcher is untouched and still starts it.
  #
  # A Zig that FAILS used to raise, on the reasoning that a present tool
  # breaking is a broken build rather than an absent one. That reasoning does
  # not survive the version fork: CI pins Zig 0.15.2 because Burrito 1.5
  # requires exactly that, while a developer machine carries whatever is
  # current (0.16.0 as this was written). `zig rc` stops parsing options at
  # the first non-option argument - build_launcher.ps1 already documents
  # having to order its arguments around that - and that is precisely the kind
  # of surface that moves between Zig releases. So a launcher build can fail
  # on one machine and succeed on the other for a reason that has nothing to
  # do with this application, and raising made that fatal to the whole
  # release: no OpenPairings.exe, and no portable release either, when the
  # portable release was complete apart from a 100 KB C stub.
  #
  # What is NOT soft, and must stay that way - read these as the other half of
  # this branch, because it is only safe to warn here because they refuse
  # there:
  #
  #   * rel/windows/build_installer.ps1 hard-stops when OpenPairings.exe is
  #     not in the payload. Velopack will happily pack a --mainExe that does
  #     not exist and hand you a Setup.exe that installs an application
  #     nothing can start, which is worse than no installer at all.
  #   * .github/workflows/binaries.yml's "Check the Windows launcher was
  #     built" step throws when the file is missing. Zig is always on PATH
  #     there, so missing means this step ran and did not produce it.
  #
  # The consequence of softening is therefore local, and deliberate: a
  # developer gets a usable portable release plus a warning instead of a dead
  # build. CI still goes red on the Windows target - it should.
  def windows_launcher(release) do
    script = Path.join([__DIR__, "rel", "windows", "build_launcher.ps1"])
    output = Path.join(release.path, "OpenPairings.exe")

    cond do
      elem(:os.type(), 0) != :win32 ->
        release

      is_nil(System.find_executable("zig")) ->
        Mix.shell().info([
          :yellow,
          "Skipping OpenPairings.exe: zig is not on PATH.\n",
          "The portable release still works through OpenPairings.bat, but\n",
          "rel/windows/build_installer.ps1 will refuse this payload.",
          :reset
        ])

        release

      true ->
        args = [
          "-NoProfile",
          "-ExecutionPolicy",
          "Bypass",
          "-File",
          script,
          "-OutputPath",
          output,
          "-Version",
          release.version
        ]

        case System.cmd("powershell", args, stderr_to_stdout: true) do
          {out, 0} ->
            Mix.shell().info(out)
            release

          {out, status} ->
            Mix.shell().error("""
            OpenPairings.exe was NOT built: rel/windows/build_launcher.ps1 exited #{status}.

            The portable release is otherwise complete and still starts through
            OpenPairings.bat. What will not work:

              * rel/windows/build_installer.ps1 refuses this payload outright -
                Velopack's --mainExe has to exist.
              * CI's "Check the Windows launcher was built" step fails the
                Windows target.

            A Zig version difference is the usual cause; see the header of
            rel/windows/build_launcher.ps1. The script's own output follows.

            #{out}
            """)

            release
        end
    end
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {PairingsEngine.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:pbkdf2_elixir, "~> 2.0"},
      {:phoenix, "~> 1.8.9"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.5.20",
       sparse: "packages/bundle",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:eqrcode, "~> 0.2"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:req, "~> 0.5"},
      {:swoosh, "~> 1.16"},
      {:gen_smtp, "~> 1.2"},
      {:burrito, "~> 1.3"},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      # Pure Elixir, no native deps - renders CHANGELOG.md on the
      # Settings > Changelog page (SettingsChangelogLive).
      {:earmark_parser, "~> 1.4"},
      # Ainalrami - the optional second Swiss engine (see
      # docs/pairing-systems.md). A from-scratch Dutch-system implementation
      # in pure Elixir with zero runtime dependencies: no JVM, no external
      # binary, nothing to install alongside a release or a Burrito build.
      # Not published to Hex, so it comes from GitHub the same way heroicons
      # and daisyui already do.
      #
      # Pinned to an exact RELEASE on purpose, and only ever bumped
      # deliberately, with the bump reviewed like any other pairing change.
      # Floating this to a branch would let an upstream push silently change
      # what this app pairs - the one thing a tournament manager can never
      # allow. `override: true`-style looseness is equally out.
      #
      # A tag rather than a bare SHA, since 2026-08-22. The pin sat 79
      # commits and four days stale without anyone noticing, because
      # "6d739bd" looks exactly as current as any other SHA - there is
      # nothing in it to be stale-looking. A version number is legible: a
      # `v0.4.0` here against a v0.10.0 upstream is visible at a glance, in
      # a diff and in review. mix.lock still records the resolved commit, so
      # this is no less exact than a SHA was; it is only easier to read.
      {:ainalrami, github: "AuroraRyunix/Ainalrami", tag: "v0.25.0"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind pairings_engine", "esbuild pairings_engine"],
      "assets.deploy": [
        "tailwind pairings_engine --minify",
        "esbuild pairings_engine --minify",
        "phx.digest"
      ],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        # Before the tests, because it is instant and the failure is a typo
        # somebody wants to hear about now rather than after a full suite.
        "pairings.version_check",
        "test"
      ]
    ]
  end
end
