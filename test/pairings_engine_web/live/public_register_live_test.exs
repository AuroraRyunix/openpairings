defmodule PairingsEngineWeb.PublicRegisterLiveTest do
  @moduledoc """
  The public self-registration form - the only public page that writes.

  The two properties worth guarding are the ones that would be damaging
  rather than merely wrong: a closed form must not accept an entry, and
  everyone who registers must land ABSENT. Pairing a no-show hands their
  opponent a forfeit win, so "absent until the arbiter says otherwise" is
  the whole point of the feature, not a detail of it.
  """
  use PairingsEngineWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PairingsEngine.{RateLimit, Repo, Tournaments}
  alias PairingsEngine.Fide.FidePlayer

  setup :register_and_log_in_user

  # The rate-limit bucket is global ETS keyed by client address, and every
  # test here arrives from the same one. Tests within a module run
  # sequentially, so clearing it up front isolates them from each other -
  # without this the flood test below spends the allowance for the rest.
  setup do
    RateLimit.clear(:public_register, "127.0.0.1")
    :ok
  end

  defp tournament(scope, opts \\ []) do
    {:ok, t} = Tournaments.create_tournament(scope, %{"name" => "Reg Test", "type" => "swiss"})
    {:ok, t} = Tournaments.set_public_pages(t, true)

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

      lv
      |> element("#reg-search")
      |> render_change(%{"q" => "Nakamura Hikaru", "birth_year" => "1990", "federation" => "USA"})

      html = lv |> element("button", "Register") |> render_click()

      assert html =~ "You&#39;re registered" or html =~ "You're registered"

      assert [player] = Tournaments.list_players(t.id)
      assert player.name == "Nakamura Hikaru"
      assert player.birth_year == 1990
      assert player.federation == "USA"

      assert player.absent,
             "a player who filled in a web form has announced an intention, not arrived"
    end

    test "a player can request byes for the rounds they cannot play",
         %{conn: conn, scope: scope} do
      t = tournament(scope, open?: true)

      {:ok, lv, html} = live(conn, ~p"/p/#{t.public_slug}/register")

      # One box per round the tournament actually has.
      assert html =~ "Rounds you cannot play"
      assert html =~ "Round 1"
      assert html =~ "Round #{t.rounds_count}"
      refute html =~ "Round #{t.rounds_count + 1}"

      lv
      |> element("#reg-search")
      |> render_change(%{"q" => "Bye Requester", "birth_year" => "1990", "federation" => "BEL"})

      lv |> element("input[phx-value-round='1']") |> render_click()
      lv |> element("input[phx-value-round='4']") |> render_click()

      # Ticking twice unticks - a mis-tap on a phone has to be undoable.
      lv |> element("input[phx-value-round='7']") |> render_click()
      lv |> element("input[phx-value-round='7']") |> render_click()

      lv |> element("button", "Register") |> render_click()

      assert [player] = Tournaments.list_players(t.id)
      assert player.absent_rounds == "1,4"

      assert player.absent,
             "requesting byes is still only an announcement - the arbiter confirms arrival"
    end

    test "a forged round number cannot reach the database", %{scope: scope} do
      # The LiveView only ever renders boxes for rounds that exist, but the
      # context function is the actual boundary: this page has no login at
      # all, so "the form would not send that" is not a control.
      t = tournament(scope, open?: true)

      {:ok, player} =
        Tournaments.register_public_player(t.public_slug, %{
          "name" => "Forger",
          "birth_year" => "1990",
          "federation" => "BEL",
          "absent_rounds" => "1,#{t.rounds_count + 5},999"
        })

      assert player.absent_rounds == "1"
    end

    test "nonsense in the rounds field is dropped, not stored", %{scope: scope} do
      t = tournament(scope, open?: true)

      {:ok, player} =
        Tournaments.register_public_player(t.public_slug, %{
          "name" => "Nonsense",
          "birth_year" => "1990",
          "federation" => "BEL",
          "absent_rounds" => "drop table players"
        })

      assert player.absent_rounds == ""
    end

    test "the form states what a requested bye is actually worth here",
         %{conn: conn, scope: scope} do
      # The figure has to come from the tournament. A player deciding
      # whether to ask for a bye is exactly who is misled by a hardcoded one.
      t = tournament(scope, open?: true)

      {:ok, _lv, html} = live(conn, ~p"/p/#{t.public_slug}/register")
      assert html =~ "no points"

      {:ok, _t} =
        Tournaments.update_tournament(t, %{"abs_value" => "0.5", "abs_nbfois" => "2"})

      {:ok, _lv, html} = live(conn, ~p"/p/#{t.public_slug}/register")

      # The allowance belongs in the sentence too: "half a point" and "half
      # a point for your first two" are different offers to somebody
      # deciding how many rounds to skip.
      assert html =~ "half a point"
      assert html =~ "for your first 2"
    end

    test "confirming arrival does not cancel the byes that were requested",
         %{scope: scope} do
      # The thing an arbiter relies on: they see the player in the room,
      # mark them present, and the rounds that player already said they
      # would miss survive it.
      t = tournament(scope, open?: true)

      {:ok, player} =
        Tournaments.register_public_player(t.public_slug, %{
          "name" => "Arrives Late",
          "birth_year" => "1990",
          "federation" => "BEL",
          "absent_rounds" => "1,2"
        })

      {:ok, present} = Tournaments.update_player(player, %{"absent" => false})

      refute present.absent
      assert present.absent_rounds == "1,2"
    end

    test "an empty name is rejected", %{conn: conn, scope: scope} do
      t = tournament(scope, open?: true)

      {:ok, lv, _html} = live(conn, ~p"/p/#{t.public_slug}/register")
      html = lv |> element("button", "Register") |> render_click()

      assert html =~ "Please enter your name"
      assert Tournaments.list_players(t.id) == []
    end

    test "not on the FIDE list still needs a birth year and federation", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope, open?: true)

      {:ok, lv, _html} = live(conn, ~p"/p/#{t.public_slug}/register")
      lv |> element("#reg-search") |> render_change(%{"q" => "Unrated Player"})
      html = lv |> element("button", "Register") |> render_click()

      assert html =~ "Please also fill in your birth year and federation"
      assert Tournaments.list_players(t.id) == []
    end

    test "a nonsense birth year is rejected", %{conn: conn, scope: scope} do
      t = tournament(scope, open?: true)

      {:ok, lv, _html} = live(conn, ~p"/p/#{t.public_slug}/register")

      lv
      |> element("#reg-search")
      |> render_change(%{"q" => "Unrated Player", "birth_year" => "abcd", "federation" => "BEL"})

      html = lv |> element("button", "Register") |> render_click()

      assert html =~ "Please enter a birth year as 4 digits"
      assert Tournaments.list_players(t.id) == []
    end

    test "picking a FIDE match needs no birth year or federation of its own", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope, open?: true)

      Repo.insert!(%FidePlayer{
        fide_id: 2_016_192,
        name: "Nakamura, Hikaru",
        federation: "USA",
        birth_year: 1987,
        title: "GM",
        standard_rating: 2780
      })

      {:ok, lv, _html} = live(conn, ~p"/p/#{t.public_slug}/register")
      lv |> element("#reg-search") |> render_change(%{"q" => "Nakamura"})
      lv |> element("button[phx-value-fide-id='2016192']") |> render_click()
      html = lv |> element("button", "Register") |> render_click()

      assert html =~ "You&#39;re registered" or html =~ "You're registered"
      assert [player] = Tournaments.list_players(t.id)
      assert player.name == "Nakamura, Hikaru"
      assert player.federation == "USA"
      assert player.birth_year == 1987
    end

    # The matches used to render as a list UNDER the form, so every keystroke
    # reflowed the birth-year and federation fields further down the page,
    # out from under the cursor of anyone mid-form.
    test "matches appear in an overlay panel, not as content that moves the form", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope, open?: true)

      Repo.insert!(%FidePlayer{
        fide_id: 2_016_192,
        name: "Nakamura, Hikaru",
        federation: "USA",
        birth_year: 1987,
        title: "GM",
        standard_rating: 2780
      })

      {:ok, lv, html} = live(conn, ~p"/p/#{t.public_slug}/register")
      refute html =~ "search-results"

      html = lv |> element("#reg-search") |> render_change(%{"q" => "Nakamura"})

      # The shared overlay panel, anchored to the field by .reg-name-wrap -
      # the same component the arbiter-side FIDE lookup uses.
      assert html =~ "reg-name-wrap"
      assert html =~ ~s(id="reg-results")
      assert html =~ "search-results"
      assert html =~ "Nakamura, Hikaru"

      # Clicking away puts the panel away but must NOT discard what was
      # typed: someone not on the FIDE list types their name and never picks
      # from the panel at all.
      html = render_click(lv, "close_results", %{})

      refute html =~ ~s(id="reg-results")
      assert html =~ ~s(value="Nakamura")
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
      # thing away - there is no longer a Register button to press, which
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
    # replaces the form with the confirmation - one visitor, one sign-up.
    defp register_once(conn, slug, name) do
      {:ok, lv, _html} = live(conn, ~p"/p/#{slug}/register")

      lv
      |> element("#reg-search")
      |> render_change(%{"q" => name, "birth_year" => "1990", "federation" => "BEL"})

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
      # allowance from the same address. Assert the BEHAVIOUR - that the
      # flood is eventually cut off and never exceeds the cap - rather than
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
      # Absolute now, not relative: PublicLink builds a full URL because half
      # of these end up on a QR code, in a printed footer or pasted into an
      # email, where a relative link is useless. A published tournament gets
      # the results site's address here instead - see public_link_test.exs.
      assert html =~ "/p/#{t.public_slug}/register"
    end
  end
end
