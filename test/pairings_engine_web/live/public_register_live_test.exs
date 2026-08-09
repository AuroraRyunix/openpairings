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

  alias PairingsEngine.Tournaments

  setup :register_and_log_in_user

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

      lv |> element("#reg-name") |> render_change(%{"q" => "Nakamura Hikaru"})
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
      lv |> element("#reg-name") |> render_change(%{"q" => "Late Entrant"})

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
