defmodule PairingsEngine.BuildTest do
  @moduledoc """
  A version number identifies a release; this identifies a BUILD.

  The distinction earned itself on 2026-08-30: a deploy went out, the public
  site still looked wrong, and both sides of the question reported `0.18.0`.
  The cause was that only one of the two applications had been deployed -
  which a build identifier shows at a glance and a version number cannot.
  """
  # DataCase for the one test that publishes a snapshot; the rest are pure.
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.Build

  describe "the pieces" do
    test "the version is the one mix.exs declares" do
      assert Build.version() == Mix.Project.config()[:version]
    end

    test "the build time is a real instant, not a placeholder" do
      assert {:ok, _at, _offset} = DateTime.from_iso8601(Build.built_at())
    end

    test "the ref is a short commit, or says it does not know" do
      ref = Build.ref()

      assert is_binary(ref)
      assert ref != ""

      # "unknown" is a legitimate answer and the honest one when the build
      # had no git and nothing set BUILD_REF - which is exactly the deployed
      # case if the deploy script forgets to pass it.
      assert ref == "unknown" or ref =~ ~r/^[0-9a-f]{7,40}$/
    end
  end

  describe "the identifier" do
    test "carries more than the version" do
      # The whole point. If this ever equals the bare version again, the
      # thing it was built to prevent is back.
      refute Build.id() == Build.version()
      assert String.starts_with?(Build.id(), Build.version())
    end

    test "a test run is not a release build, and says so" do
      refute Build.release?()
      assert Build.id() =~ "-dev"
      assert Build.long() =~ "not a release build"
    end

    test "the long form is the short one plus how it was built" do
      assert String.starts_with?(Build.long(), Build.id())
    end
  end

  describe "what reads it" do
    test "the three former copies of app_version all resolve here" do
      # `Layouts.app_version/0`, `Snapshot`'s and `TrfExport`'s were four
      # identical lines in three modules, one carrying a comment explaining
      # that the duplication was deliberate.
      assert PairingsEngineWeb.Layouts.app_version() == Build.version()
    end

    test "a published snapshot records the build that produced it" do
      # Not the release: a document that arrived from a dev build, or from a
      # build nobody can identify, should say so on the receiving side.
      tournament =
        Repo.insert!(%PairingsEngine.Tournaments.Tournament{
          name: "Build",
          type: "swiss",
          rounds_count: 1
        })

      assert %{"source" => %{"app" => "openpairings", "version" => version}} =
               PairingsEngine.Snapshot.build(tournament)

      assert version == Build.id()
    end
  end
end
