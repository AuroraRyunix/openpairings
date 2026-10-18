defmodule PairingsEngine.PluginBootTest do
  use ExUnit.Case, async: false

  alias PairingsEngine.{FakePlugin, Plugins}

  test "boot/0 reaches a plugin that implements it" do
    FakePlugin.register(boot_notify: self())
    assert Plugins.boot() == :ok
    assert_received :fake_plugin_booted
  end

  test "a plugin that raises in boot/0 is logged and does not stop the boot" do
    FakePlugin.register(boot_notify: self(), boot_raise: true)

    log = ExUnit.CaptureLog.capture_log(fn -> assert Plugins.boot() == :ok end)

    assert log =~ "boot/0"
    assert_received :fake_plugin_booted
  end

  test "without plugins boot/0 does nothing" do
    assert Plugins.boot() == :ok
  end
end
