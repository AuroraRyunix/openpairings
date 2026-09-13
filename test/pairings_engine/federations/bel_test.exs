defmodule PairingsEngine.Federations.BELTest do
  @moduledoc """
  `source/0`'s precedence: the direct data-platform key first, then the
  results site, then the manual file upload - see docs/kbsb-sync.md.
  """
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.Federations.BEL
  alias PairingsEngine.Publishing

  setup do
    original_kbsb = Application.get_env(:pairings_engine, :kbsb)
    Application.delete_env(:pairings_engine, :kbsb)
    Publishing.put_endpoint(nil)
    Publishing.put_token(nil)

    on_exit(fn ->
      if original_kbsb,
        do: Application.put_env(:pairings_engine, :kbsb, original_kbsb),
        else: Application.delete_env(:pairings_engine, :kbsb)

      Publishing.put_endpoint(nil)
      Publishing.put_token(nil)
    end)

    :ok
  end

  test "neither source configured: file upload" do
    assert BEL.source() == :file_upload
  end

  test "only the results site available: results_site" do
    Publishing.put_endpoint("https://openresults.example")
    Publishing.put_token("op-token")

    assert BEL.source() == :results_site
  end

  test "the direct data-platform key wins over the results site" do
    Application.put_env(:pairings_engine, :kbsb, api_url: "https://kbsb.test", api_key: "k")
    Publishing.put_endpoint("https://openresults.example")
    Publishing.put_token("op-token")

    assert BEL.source() == :data_platform
  end
end
