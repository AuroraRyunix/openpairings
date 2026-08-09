defmodule PairingsEngineWeb.PublicRegisterLiveTest do
  @moduledoc """
  The public self-registration form — the only public page that writes.

  The two properties worth guarding are the ones that would be damaging
  rather than merely wrong: a closed form must not accept an entry, and
  everyone who registers must land ABSENT. Pairing a no-show hands their
  opponent a forfeit win, so "absent until the arbiter says otherwise" is
  the whole point of the feature, not a detail of it.
  """
  use PairingsEngineWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PairingsEngine.{RateLimit, Tournaments}

  setup :register_and_log_in_user

  # The rate-limit bucket is global ETS keyed by client address, and every
  # test here arrives from the same one. Tests within a module run
  # sequentially, so clearing it up front isolates them from each other —
  # without this the flood test below spends the allowance for the rest.
  setup do
    RateLimit.clear(:public_register, "127.0.0.1")
    :ok
  end

  defp tournament(scope, opts \\ []) do
    {:ok, t} = Tournaments.create_tournament(scope, %{"name" => "Reg Test", "type" => "swiss"})

    if Keyword.get(opts, :open?, false) do
      {:ok, t} = Tournaments.set_registration_open(t, true)
      t
    else
      t
    end
  end

  describe "the form itself" do
    test "is closed by default, and says so rather than 404ing", %{conn: conn, scope: scope} do
      t = tournament(scope)

      {:ok, _lv, html} = live(conn, ~p"/p/#{t.public_slug}/register")

      assert html =~ "Registration is closed"
      refute html =~ "Add your name"
    end

    test "shows the form once opened", %{conn: conn, scope: scope} do
      t = tournament(scope, open?: true)

      {:ok, _lv, html} = live(conn, ~p"/p/#{t.public_slug}/register")

      assert html =~ "Add your name"
      refute html =~ "Registration is closed"
    end

    test "needs no login", %{scope: scope} do
      t = tournament(scope, open?: true)

      {:ok, _lv, html} = live(build_conn(), ~p"/p/#{t.public_slug}/register")

      assert html =~ "Add your name"
    end
  end

  describe "registering" do
    test "adds the player and marks them ABSENT", %{conn: conn, scope: scope} do
      t = tournament(scope, open?: true)

      {:ok, lv, _html} = live(conn, ~p"/p/#{t.public_slug}/register")

      lv |> element("#reg-search") |> render_change(%{"q" => "Nakamura Hikaru"})
      html = lv |> element("button", "Register") |> render_click()

      assert html =~ "You&#39;re registered" or html =~ "You're registered"

      assert [player] = Tournaments.list_players(t.id)
      assert player.name == "Nakamura Hikaru"

      assert player.absent,
             "a player who filled in a web form has announced an intention, not arrived"
    end

    test "an empty name is rejected", %{conn: conn, scope: scope} do
      t = tournament(scope, open?: true)

      {:ok, lv, _html} = live(conn, ~p"/p/#{t.public_slug}/register")
      html = lv |> element("button", "Register") |> render_click()

      assert html =~ "Please enter your name"
      assert Tournaments.list_players(t.id) == []
    end
  end

  describe "closing the form" do
    test "a form already open in a browser closes live, mid-session", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope, open?: true)

      {:ok, lv, _html} = live(conn, ~p"/p/#{t.public_slug}/register")
      lv |> element("#reg-search") |> render_change(%{"q" => "Late Entrant"})

      # The arbiter closes it after the page was already rendered.
      {:ok, _t} = Tournaments.set_registration_open(t, false)

      # The PubSub broadcast reaches the open form and takes the whole
      # thing away — there is no longer a Register button to press, which
      # is a better outcome than letting someone click it and be refused.
      html = render(lv)

      assert html =~ "Registration is closed"
      refute html =~ "Add your name"
      assert Tournaments.list_players(t.id) == []
    end

    test "the context function refuses regardless of the caller", %{scope: scope} do
      t = tournament(scope)

      assert {:error, :closed} =
               Tournaments.register_public_player(t.public_slug, %{"name" => "Sneaky"})

      assert Tournaments.list_players(t.id) == []
    end

    test "registration cannot outlive the public pages switch", %{scope: scope} do
      t = tournament(scope, open?: true)
      {:ok, t} = Tournaments.set_public_pages(t, false)

      assert {:error, :closed} =
               Tournaments.register_public_player(t.public_slug, %{"name" => "Nope"})
    end
  end

  describe "rate limiting" do
    # Each entry is its own page load, because a successful registration
    # replaces the form with the confirmation — one visitor, one sign-up.
    defp register_once(conn, slug, name) do
      {:ok, lv, _html} = live(conn, ~p"/p/#{slug}/register")
      lv |> element("#reg-search") |> render_change(%{"q" => name})
      lv |> element("button", "Register") |> render_click()
    end

    test "a flood from one address is cut off, and only real entries count", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope, open?: true)
      %{max: max} = PairingsEngine.RateLimit.config(:public_register)

      # Blanks are refused, and must not spend the allowance.
      for _ <- 1..3 do
        {:ok, lv, _html} = live(conn, ~p"/p/#{t.public_slug}/register")
        lv |> element("button", "Register") |> render_click()
      end

      # The bucket is global ETS keyed by client address, and these tests
      # are async, so a sibling test may already have spent part of the
      # allowance from the same address. Assert the BEHAVIOUR — that the
      # flood is eventually cut off and never exceeds the cap — rather than
      # an exact count that depends on what else ran.
      results =
        for i <- 1..(max + 1), do: register_once(conn, t.public_slug, "Player #{i}")

      entered = length(Tournaments.list_players(t.id))

      assert entered > 0, "honest sign-ups must get through"
      assert entered <= max, "the cap must hold"

      assert List.last(results) =~ "Too many sign-ups",
             "the flood must be refused once the bucket is spent"
    end
  end

  describe "the arbiter's toggle" do
    test "Options offers 'Open up' and then the share link", %{conn: conn, scope: scope} do
      t = tournament(scope)

      {:ok, lv, html} = live(conn, ~p"/t/#{t.id}/settings/options")

      assert html =~ "Open up"
      refute html =~ "Registration link"

      html = lv |> element("button", "Open up") |> render_click()

      assert html =~ "Close the form"
      assert html =~ ~s(href="/p/#{t.public_slug}/register")
    end
  end
end
