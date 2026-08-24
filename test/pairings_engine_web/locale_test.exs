defmodule PairingsEngineWeb.LocaleTest do
  @moduledoc """
  Language selection: how a locale is resolved, that it survives into the
  LiveView process, and that the switch cannot be turned into an open
  redirect.

  English and Dutch ship. Most of these are written against the MECHANISM
  rather than against a particular catalogue, so they keep their value when
  a third language lands - but note what happened when Dutch arrived: the
  malformed-header test asserted `== "en"` and only passed because there
  was nothing else to resolve TO. "Written against the mechanism" is easy to
  believe about a test and worth re-checking each time the set of shipped
  languages changes.
  """
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

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
      # The invariant is that garbage always lands on a locale we actually
      # ship - never a crash, never a code we cannot render.
      #
      # This asserted `== "en"` until Dutch shipped, which was the exact
      # trap this module's own moduledoc warns about: it read as a
      # statement about malformed input and was really a statement about
      # there being one catalogue.
      for header <- [";;;", "q=", String.duplicate("x,", 500), "-", "nl;q=banana", "nl-"] do
        assert Locale.known?(Locale.resolve(%{}, header))
      end

      # Nothing in these names a language, so they fall through to the
      # default.
      for header <- [";;;", "q=", String.duplicate("x,", 500), "-"] do
        assert Locale.resolve(%{}, header) == "en"
      end
    end

    test "a valid language with a broken quality value still gets its language" do
      # `q=banana` sorts last rather than raising, so a client that asked
      # for Dutch and mangled only the weighting still gets Dutch. Same for
      # a dangling region separator.
      assert Locale.resolve(%{}, "nl;q=banana") == "nl"
      assert Locale.resolve(%{}, "nl-") == "nl"
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

    test "refuses to send you to another site" do
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

    test "picking Dutch actually renders Dutch, end to end", %{conn: conn} do
      # The whole pipeline in one assertion: the switch writes the session,
      # the plug resolves it, LocaleHook re-applies it inside the LiveView
      # process, and the catalogue answers. Every earlier test in this file
      # could pass with an empty `nl` catalogue; this one cannot.
      conn = get(conn, ~p"/locale/nl?redirect_to=/")
      assert redirected_to(conn) == "/"

      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "Nieuw toernooi"
      assert html =~ "Alles wat je organiseert"
      refute html =~ "New tournament"
    end

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
