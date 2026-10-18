defmodule PairingsEngine.PluginManifestTest do
  use ExUnit.Case, async: true

  alias PairingsEngine.PluginManifest

  test "a manifest without applications starts nothing extra" do
    plugin = PluginManifest.parse([name: :demo, module: Demo.Plugin], "somewhere/demo")

    assert plugin.name == :demo
    assert plugin.module == Demo.Plugin
    assert plugin.applications == []
  end

  test "applications are carried through" do
    plugin =
      PluginManifest.parse(
        [name: :demo, module: Demo.Plugin, applications: [:demo_client, :demo_core]],
        "somewhere/demo"
      )

    assert plugin.applications == [:demo_client, :demo_core]
  end

  test "applications that are not a list of atoms stop the build, naming the manifest" do
    for bad <- ["demo_client", [:ok, "no"], :demo_client, [1]] do
      error =
        assert_raise ArgumentError, fn ->
          PluginManifest.parse([name: :demo, module: Demo.Plugin, applications: bad], "x/demo")
        end

      assert error.message =~ "openpairings_plugin.exs"
      assert error.message =~ ":applications"
    end
  end

  test "a missing name or module is named" do
    error =
      assert_raise ArgumentError, fn -> PluginManifest.parse([module: Demo.Plugin], "x/demo") end

    assert error.message =~ ":name key is missing"

    assert_raise ArgumentError, ~r/:module key is missing/, fn ->
      PluginManifest.parse([name: :demo], "x/demo")
    end
  end

  test "a manifest that is not a keyword list is refused" do
    assert_raise ArgumentError, ~r/keyword list/, fn -> PluginManifest.parse(%{}, "x/demo") end
  end
end
