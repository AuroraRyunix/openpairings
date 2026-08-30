defmodule Mix.Tasks.Pairings.VersionCheckTest do
  @moduledoc """
  The check exists because the drift it catches has happened three times,
  the last time inside the three days the report that filed it covered. So
  the test that matters is not "it passes on a clean tree" - it is "it fails
  on the exact shape that got through before".
  """
  use ExUnit.Case, async: false

  @documents ["TODO.md", "docs/features.md", "CHANGELOG.md"]

  setup do
    originals = Map.new(@documents, &{&1, File.read!(&1)})
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

  defp bump(path, from, to) do
    body = File.read!(path)
    assert String.contains?(body, from), "#{path} does not contain #{inspect(from)}"
    File.write!(path, String.replace(body, from, to, global: false))
  end
end
