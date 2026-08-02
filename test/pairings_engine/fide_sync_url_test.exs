defmodule PairingsEngine.Fide.SyncUrlTest do
  # The rating-list URL has to be resolved at RUNTIME, not frozen into a
  # module attribute at compile time — a prod host that FIDE blocks needs to
  # be pointed at a mirror via FIDE_LIST_URL without recompiling.
  use ExUnit.Case, async: false

  alias PairingsEngine.Fide.Sync

  setup do
    original = Application.get_env(:pairings_engine, :fide)
    on_exit(fn -> Application.put_env(:pairings_engine, :fide, original) end)
    :ok
  end

  test "defaults to FIDE when nothing is configured" do
    Application.put_env(:pairings_engine, :fide, [])
    assert Sync.list_url() == "https://ratings.fide.com/download/players_list.zip"
  end

  test "a nil override (env var unset) still falls back to the default" do
    Application.put_env(:pairings_engine, :fide, list_url: nil)
    assert Sync.list_url() == "https://ratings.fide.com/download/players_list.zip"
  end

  test "a configured URL overrides the default" do
    Application.put_env(:pairings_engine, :fide, list_url: "https://example.test/list.zip")
    assert Sync.list_url() == "https://example.test/list.zip"
  end

  test "the key being absent entirely is not a crash" do
    Application.delete_env(:pairings_engine, :fide)
    assert Sync.list_url() == "https://ratings.fide.com/download/players_list.zip"
  end

  describe "source_label/0 — makes a misconfigured override visible" do
    test "says FIDE when using the default" do
      Application.put_env(:pairings_engine, :fide, [])
      assert Sync.source_label() == "FIDE"
    end

    test "names the host of an override" do
      Application.put_env(:pairings_engine, :fide,
        list_url: "https://fide-proxy.example.workers.dev/download/players_list.zip"
      )

      assert Sync.source_label() == "fide-proxy.example.workers.dev"
    end

    # A quoted value in .env survives verbatim (the loader splits on "=" and
    # doesn't strip quotes), so it must not crash the progress line — showing
    # the mangled value is exactly the diagnostic wanted.
    test "a mangled override degrades to showing the raw value, not a crash" do
      Application.put_env(:pairings_engine, :fide, list_url: "\"https://quoted.example\"")
      assert is_binary(Sync.source_label())
    end
  end
end
