defmodule Mix.Tasks.Pairings.PublishingTest do
  @moduledoc """
  The ingest token can arrive without ever touching a command line.

  A secret passed as `--token` is in the argv of the process that runs, and
  `/proc/<pid>/cmdline` is world-readable - so on a box that hosts other
  applications it is legible to any local account for as long as the task
  takes. The deploy script removed the token from the command string it
  builds, prints and sends over the wire, and could not remove this last
  part, because `OptionParser` reads argv and nothing else.

  `DEPLOY_PUBLISH_TOKEN` is that last part. These tests exist because the
  fallback is invisible when it works: nothing about a successful deploy
  shows which of the two routes the token took, so a regression here would
  quietly put the secret back on the command line and be noticed by nobody.
  """
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.Publishing

  @env "DEPLOY_PUBLISH_TOKEN"

  setup do
    previous = System.get_env(@env)

    on_exit(fn ->
      if previous, do: System.put_env(@env, previous), else: System.delete_env(@env)
    end)

    System.delete_env(@env)
    :ok
  end

  defp run(args) do
    # The task prints; the tests are about what it stores.
    ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Pairings.Publishing.run(args) end)
  end

  describe "where the token comes from" do
    test "the environment is enough - no --token anywhere" do
      System.put_env(@env, "from-the-environment")

      run(["--force"])

      assert Publishing.token() == "from-the-environment"
    end

    test "--token still wins when both are given" do
      # A person typing it has decided; the environment is what a script
      # arranges. The explicit one is the more specific instruction.
      System.put_env(@env, "from-the-environment")

      run(["--force", "--token", "typed-by-hand"])

      assert Publishing.token() == "typed-by-hand"
    end

    test "a blank environment variable is not a token" do
      # `.env` files ship keys with empty values, and `System.get_env` hands
      # back "" rather than nil for those. Storing it would set the token to
      # nothing and make every publish 401 with no clue why.
      System.put_env(@env, "")

      run(["--force"])

      assert Publishing.token() in [nil, ""]
    end

    test "neither one set leaves the stored token alone" do
      run(["--force", "--token", "already-here"])
      assert Publishing.token() == "already-here"

      run(["--force"])

      assert Publishing.token() == "already-here"
    end
  end
end
