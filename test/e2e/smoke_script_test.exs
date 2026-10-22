defmodule PairingsEngineWeb.E2E.SmokeScriptTest do
  @moduledoc """
  e2e/smoke.mjs, the read-only check pointed at a deployed server after a
  deploy, pointed at this test server instead - so a page it expects that has
  moved fails here, in CI, and not on the evening of a deploy.
  """
  use PairingsEngineWeb.E2ECase

  test "passes against a freshly started server" do
    base_url = Application.fetch_env!(:phoenix_test, :base_url)
    node = System.find_executable("node") || flunk("node is not on PATH")

    {output, status} =
      System.cmd(node, ["smoke.mjs", base_url], cd: "e2e", stderr_to_stdout: true)

    assert status == 0, output
    assert output =~ ~r/All \d+ checks passed/
  end
end
