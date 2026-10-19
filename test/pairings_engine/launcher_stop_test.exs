defmodule PairingsEngine.LauncherStopTest do
  @moduledoc """
  The Mac window's stop by signal (Ascella, an update, a logout): its quit
  must not wait inside the main dispatch queue for news that queues behind
  it, which is how "Stopping" lasted until a force-quit.
  """

  use ExUnit.Case, async: true

  @swift Path.expand("../../rel/macos/Launcher.swift", __DIR__)

  test "a stop by signal quits through the run loop, and hears its server end there" do
    swift = File.read!(@swift)

    assert swift =~
             "RunLoop.main.perform(inModes: [.default, .modalPanel]) { NSApp.terminate(nil) }"

    assert swift =~
             "RunLoop.main.perform(inModes: [.common]) { self?.serverEnded(status: status) }"

    refute swift =~ "DispatchQueue.main.async { self?.serverEnded"
    refute swift =~ "DispatchQueue.main.asyncAfter(deadline: .now() + 30)"
  end

  test "a stop that hangs anyway ends after forty seconds, from another thread" do
    assert File.read!(@swift) =~
             "DispatchQueue.global().asyncAfter(deadline: .now() + 40) { exit(0) }"
  end
end
