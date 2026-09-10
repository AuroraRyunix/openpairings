defmodule Mix.Tasks.Pairings.VersionCheckTest do
  @moduledoc """
  The check exists because the drift it catches has happened three times,
  the last time inside the three days the report that filed it covered. So
  the test that matters is not "it passes on a clean tree" - it is "it fails
  on the exact shape that got through before".
  """
  use ExUnit.Case, async: false

  @documents ["TODO.md", "docs/features.md", "CHANGELOG.md"]
  @workflow ".github/workflows/binaries.yml"

  setup do
    originals = Map.new([@workflow | @documents], &{&1, File.read!(&1)})
    on_exit(fn -> Enum.each(originals, fn {path, body} -> File.write!(path, body) end) end)
    {:ok, version: Mix.Project.config()[:version]}
  end

  test "passes on the tree as committed" do
    assert Mix.Tasks.Pairings.VersionCheck.run([]) == :ok
  end

  test "catches the drift that actually happened", %{version: version} do
    # 2026-08-29: TODO.md was bumped to 0.18.0 and docs/features.md was not.
    bump("docs/features.md", version, "0.17.1")

    error = assert_raise Mix.Error, fn -> Mix.Tasks.Pairings.VersionCheck.run([]) end

    assert error.message =~ "docs/features.md"
    assert error.message =~ "0.17.1"
    assert error.message =~ version
  end

  test "catches every document, not just the first", %{version: version} do
    # 2026-08-26: mix.exs had moved and both prose files were behind.
    bump("TODO.md", version, "0.16.1")
    bump("docs/features.md", version, "0.16.1")

    error = assert_raise Mix.Error, fn -> Mix.Tasks.Pairings.VersionCheck.run([]) end

    assert error.message =~ "TODO.md"
    assert error.message =~ "docs/features.md"
  end

  test "reads the changelog's TOP section, not any older one", %{version: version} do
    # The file is a list of past versions; every one but the first is meant
    # to disagree with mix.exs, so a naive search would fire on all of them.
    body = File.read!("CHANGELOG.md")
    assert body =~ "## [0.17.1]"

    assert Mix.Tasks.Pairings.VersionCheck.run([]) == :ok

    bump("CHANGELOG.md", "## [#{version}]", "## [0.99.0]")
    error = assert_raise Mix.Error, fn -> Mix.Tasks.Pairings.VersionCheck.run([]) end
    assert error.message =~ "0.99.0"
  end

  test "says so when a document states no version at all" do
    File.write!("docs/features.md", "# OpenPairings\n\nNo header any more.\n")

    error = assert_raise Mix.Error, fn -> Mix.Tasks.Pairings.VersionCheck.run([]) end

    assert error.message =~ "states no version this could find"
  end

  describe "files that derive the version" do
    test "the macOS bundle's plist names no version of its own" do
      # The committed workflow substitutes a placeholder. If this fails, the
      # 2026-09-10 bug is back: a literal in the Info.plist heredoc.
      body = File.read!(@workflow)

      assert body =~ "CFBundleShortVersionString"
      assert Mix.Tasks.Pairings.VersionCheck.run([]) == :ok
    end

    test "a hardcoded plist version fails, naming the file and the value" do
      hardcode("0.18.0")

      error = assert_raise Mix.Error, fn -> Mix.Tasks.Pairings.VersionCheck.run([]) end

      assert error.message =~ @workflow
      assert error.message =~ "0.18.0"
      assert error.message =~ "take it from mix.exs at build time"
    end

    test "a hardcoded version fails even when it is the right one", %{version: version} do
      # The whole point. 0.18.0 was correct on the day it was typed; what
      # made it a bug was the next bump, and a check that only compares
      # values would have waved that day's commit through.
      hardcode(version)

      error = assert_raise Mix.Error, fn -> Mix.Tasks.Pairings.VersionCheck.run([]) end

      assert error.message =~ "hardcodes #{version}"
    end

    test "the workflow's other version numbers are not mistaken for this one" do
      # It pins OTP, Elixir, Zig and an action per step, most of them
      # three-part - so a check anchored on "a number that looks like a
      # version" would fire on a clean tree. Which numbers those are is
      # dependabot's business and changes; that there are several is the
      # part worth asserting.
      body = File.read!(@workflow)

      assert length(Regex.scan(~r/\d+\.\d+\.\d+/, body)) > 3
      assert Mix.Tasks.Pairings.VersionCheck.run([]) == :ok
    end
  end

  defp bump(path, from, to) do
    body = File.read!(path)
    assert String.contains?(body, from), "#{path} does not contain #{inspect(from)}"
    File.write!(path, String.replace(body, from, to, global: false))
  end

  defp hardcode(version) do
    body = File.read!(@workflow)
    assert String.contains?(body, "<string>__VERSION__</string>")

    File.write!(
      @workflow,
      String.replace(body, "<string>__VERSION__</string>", "<string>#{version}</string>")
    )
  end
end
