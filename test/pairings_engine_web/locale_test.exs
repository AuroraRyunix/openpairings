defmodule PairingsEngineWeb.LocaleTest do
  @moduledoc """
  Language selection: how a locale is resolved, that it survives into the
  LiveView process, and that the switch cannot be turned into an open
  redirect.

  Only English ships today. These tests are deliberately written against the
  MECHANISM rather than against a second catalogue, so they keep their value
  on the day Dutch is added rather than needing rewriting then.
  """
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest
  import PairingsEngine.AccountsFixtures

  alias PairingsEngineWeb.Locale

  describe "resolving a locale" do
    test "an explicit session choice wins" do
      assert Locale.resolve(%{"locale" => "en"}, "nl-BE,nl;q=0.9") == "en"
    end

    test "a session value we do not ship is ignored rather than trusted" do
      # Session contents are signed, but a stale cookie from a build that
      # shipped another language must not select a catalogue that is gone.
      assert Locale.resolve(%{"locale" => "kl"}, nil) == "en"
    end

    test "falls back to the browser's header, then to the default" do
      assert Locale.resolve(%{}, "en-GB,en;q=0.9") == "en"
      assert Locale.resolve(%{}, nil) == "en"
      assert Locale.resolve(%{}, "") == "en"
    end

    test "a malformed accept-language cannot crash a public page" do
      # This header is attacker-controlled on pages with no login at all.
      for header <- [";;;", "q=", "nl;q=banana", String.duplicate("x,", 500), "nl-", "-"] do
        assert Locale.resolve(%{}, header) == "en"
      end
    end

    test "region subtags collapse to the language" do
      # Written for the day a second language lands: nl-BE and nl-NL must not
      # need two catalogues. Asserted through the public API rather than a
      # private helper so it survives the internals changing.
      assert Locale.resolve(%{"locale" => "en"}, "en-GB") == "en"
      refute Locale.known?("en-GB")
      assert Locale.known?("en")
    end

    test "every shipped locale has a label in its own language" do
      for {code, name} <- Locale.locales() do
        assert is_binary(name) and name != ""
        assert Locale.label(code) == name
      end
    end
  end

  describe "the switch" do
    test "sets the session and returns where you were", %{conn: conn} do
      conn = get(conn, ~p"/locale/en?redirect_to=/tools")

      assert redirected_to(conn) == "/tools"
      assert get_session(conn, "locale") == "en"
    end

    test "refuses to send you to another site", %{conn: conn} do
      # Presented to a visitor as "change language", so an open redirect here
      # would be a genuinely effective one.
      for target <- ["//evil.example.com", "https://evil.example.com", "", nil] do
        conn = get(build_conn(), ~p"/locale/en?redirect_to=#{target || ""}")
        assert redirected_to(conn) == "/"
      end
    end

    test "an unknown locale changes nothing", %{conn: conn} do
      conn = get(conn, ~p"/locale/kl?redirect_to=/tools")

      assert redirected_to(conn) == "/tools"
      refute get_session(conn, "locale") == "kl"
    end
  end

  describe "reaching the LiveView process" do
    setup :register_and_log_in_user

    test "a LiveView renders in the resolved locale, not the default", %{conn: conn} do
      # The reason LocaleHook exists at all: a LiveView does not run in the
      # process the plug ran in, so a locale set only by the plug would be
      # lost the moment the socket connects.
      {:ok, lv, _html} = live(conn, ~p"/")

      assert :sys.get_state(lv.pid).socket.assigns.locale == "en"
    end
  end

  describe "coverage" do
    test "every live_session decides a locale one way or the other" do
      # No central place catches them all. Either hook counts: EnglishHook is
      # a deliberate pin for the player-facing pages. What must never happen
      # is a session with no opinion, which renders in whatever locale the
      # process was last left with - invisible until somebody uses Dutch.
      source = File.read!("lib/pairings_engine_web/router.ex")

      missing =
        Regex.scan(~r/live_session\s+:(\w+)(.{0,400}?)\bdo\b/s, source)
        |> Enum.reject(fn [_all, _name, between] ->
          between =~ "LocaleHook" or between =~ "EnglishHook"
        end)
        |> Enum.map(fn [_all, name, _between] -> name end)

      assert missing == [],
             """
             These live_sessions set no locale at all: #{Enum.join(missing, ", ")}
             """
    end

    test "the player-facing sessions are pinned to English, deliberately" do
      # An open draws players from many federations, and the language its
      # arbiter picked for their own admin screens is not one to impose on a
      # visiting player reading the standings.
      source = File.read!("lib/pairings_engine_web/router.ex")

      for name <- ~w(public_tournament_pages public_registration mobile_results) do
        [[_all, between]] = Regex.scan(~r/live_session\s+:#{name}(.{0,400}?)\bdo\b/s, source)

        assert between =~ "EnglishHook", "#{name} is not pinned to English"
      end
    end
  end
end
