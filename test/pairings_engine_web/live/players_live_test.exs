defmodule PairingsEngineWeb.PlayersLiveTest do
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Fide.FidePlayer
  alias PairingsEngine.Kbsb.KbsbPlayer

  setup :register_and_log_in_user

  test "the top-left nav link reads 'Home' once inside a tournament", %{
    conn: conn,
    scope: scope
  } do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{"name" => "Nav Test", "type" => "swiss"})

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/players")

    assert html =~ ~r/<a[^>]*href="\/"[^>]*>\s*Home\s*<\/a>/
    refute html =~ ~r/<a[^>]*href="\/"[^>]*>\s*Tournaments\s*<\/a>/
  end

  test "print player list link opens the roster-wide document in a new tab", %{
    conn: conn,
    scope: scope
  } do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{"name" => "Players Print Test", "type" => "swiss"})

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/players")

    # The player-list link carries `?cols=` (see `printable_player_list_columns/1`)
    # so the print shows whatever's currently checked in the Display panel —
    # not a fixed set — hence a prefix match rather than an exact href.
    assert html =~ ~s(href="/t/#{tournament.id}/print/players?)
    assert html =~ "Print player list"
    assert html =~ ~s(target="_blank")
    # "Print player cards" was removed from the UI (the route/controller
    # action still exist, see docs/printing.md) — assert its absence so a
    # regression re-adding the button gets caught.
    refute html =~ "Print player cards"
  end

  test "the FIDE database tab is hidden once inside a tournament", %{conn: conn, scope: scope} do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{"name" => "No FIDE Tab Here", "type" => "swiss"})

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/players")

    refute html =~ ~s(href="/fide")
  end

  test "Ctrl+I hint and hook are wired on the page header, so the shortcut works even with zero players",
       %{
         conn: conn,
         scope: scope
       } do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{"name" => "Empty Roster", "type" => "swiss"})

    {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/players")

    assert html =~ ~s(phx-hook="AddPlayerShortcut")
    assert html =~ "Ctrl+I"
  end

  describe "player registration modal (double-click to edit)" do
    setup %{scope: scope} do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{"name" => "Modal Test", "type" => "swiss"})

      {:ok, player} = Tournaments.create_player(tournament.id, %{"name" => "Alice"})
      %{tournament: tournament, player: player}
    end

    test "does not rely on onclick stopPropagation, which blocks phx-click delegation", %{
      conn: conn,
      tournament: tournament,
      player: player
    } do
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      html = lv |> element("tr[data-player-id='#{player.id}']") |> render()
      # sanity: the row exists before we push the dblclick-equivalent event
      assert html =~ "Alice"

      html = render_click(lv, "edit_player", %{"id" => to_string(player.id)})
      assert html =~ "Player registration"
      refute html =~ "stopPropagation"
      assert html =~ ~s(phx-click-away="close_edit")
    end

    test "Cancel closes the modal via close_edit", %{
      conn: conn,
      tournament: tournament,
      player: player
    } do
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      render_click(lv, "edit_player", %{"id" => to_string(player.id)})
      html = lv |> element("button", "Cancel") |> render_click()

      refute html =~ "Player registration"
    end

    test "shows a Fixed table number input instead of the old Special Table checkbox", %{
      conn: conn,
      tournament: tournament,
      player: player
    } do
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      html = render_click(lv, "edit_player", %{"id" => to_string(player.id)})

      assert html =~ "Fixed table"
      assert html =~ ~s(name="player[fixed_board]")
      refute html =~ "Special Table"
    end

    test "saving a fixed_board value round-trips it and derives special_table", %{
      conn: conn,
      tournament: tournament,
      player: player
    } do
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      render_click(lv, "edit_player", %{"id" => to_string(player.id)})

      lv
      |> form("form", player: %{"name" => "Alice", "fixed_board" => "7"})
      |> render_submit()

      # update_player/2 broadcasts on the tournament topic and this `lv` is
      # subscribed to its own tournament (see PlayersLive's mount) —
      # render_submit/1 only waits for the direct reply to the "save" event,
      # not for that self-broadcast's handle_info reload, which lands in the
      # mailbox microseconds later and runs its own Repo query. Draining it
      # with a synchronous render/1 before the test (and this `lv`'s
      # teardown) proceeds avoids racing that query against the test process
      # supervisor killing `lv` mid-query — which, on SQLite's single-writer
      # file, can wedge the shared sandbox connection for later tests with a
      # spurious `Database busy` (see the same fix in sharing_test.exs).
      render(lv)

      updated = Tournaments.get_player!(player.tournament_id, player.id)
      assert updated.fixed_board == 7
      assert updated.special_table == true
    end

    test "the absent_rounds field accepts the forgiving grammar and normalizes it on save", %{
      conn: conn,
      tournament: tournament,
      player: player
    } do
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      render_click(lv, "edit_player", %{"id" => to_string(player.id)})

      lv
      |> form("form", player: %{"name" => "Alice", "absent_rounds" => "2-4;1"})
      |> render_submit()

      # Same self-broadcast race as the "saving a fixed_board value" test
      # above — drain it before the test (and `lv`'s teardown) proceeds.
      render(lv)

      updated = Tournaments.get_player!(player.tournament_id, player.id)
      assert updated.absent_rounds == "1,2,3,4"
    end

    test "a category not in the tournament's category list is preserved as a selectable option",
         %{
           conn: conn,
           scope: scope
         } do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{
          "name" => "Cat Test",
          "type" => "swiss",
          "categories" => ["U18", "U20"]
        })

      {:ok, player} =
        Tournaments.create_player(tournament.id, %{"name" => "Bob", "category" => "Legacy"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      html = render_click(lv, "edit_player", %{"id" => to_string(player.id)})

      assert html =~ ~s(value="Legacy")
      assert html =~ "Legacy"
    end
  end

  describe "players card modal (right-click)" do
    setup %{scope: scope} do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{"name" => "Card Modal Test", "type" => "swiss"})

      {:ok, player} = Tournaments.create_player(tournament.id, %{"name" => "Carol"})
      %{tournament: tournament, player: player}
    end

    test "does not rely on onclick stopPropagation either", %{
      conn: conn,
      tournament: tournament,
      player: player
    } do
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      html = render_click(lv, "show_card", %{"id" => to_string(player.id)})
      assert html =~ "<h2>Players Card</h2>"
      refute html =~ "stopPropagation"
      assert html =~ ~s(phx-click-away="close_card")
    end

    test "has a Print link to that one player's print/card document", %{
      conn: conn,
      tournament: tournament,
      player: player
    } do
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      html = render_click(lv, "show_card", %{"id" => to_string(player.id)})

      assert html =~ ~s(href="/t/#{tournament.id}/print/card/#{player.id}")
      assert html =~ ~s(target="_blank")
    end

    test "shows the player's own tiebreak values, hidden when the tournament has none configured",
         %{conn: conn, scope: scope} do
      # create_tournament/2 applies FIDE default tiebreaks unless told
      # otherwise (see Tournaments.new_tournament/1) — force the truly-empty
      # case explicitly rather than relying on this describe block's own
      # default-tiebreaks tournament for the "nothing configured" half.
      {:ok, no_tb_tournament} =
        Tournaments.create_tournament(scope, %{
          "name" => "Card Modal No-TB Test",
          "type" => "swiss",
          "tiebreaks" => []
        })

      {:ok, no_tb_player} = Tournaments.create_player(no_tb_tournament.id, %{"name" => "Eve"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{no_tb_tournament.id}/players")

      # Scoped to inside the modal card specifically (via has_element?/2) —
      # a bare substring match against the whole page would false-positive
      # on the Players grid's own "Buch" column tooltip, unrelated to
      # this card.
      render_click(lv, "show_card", %{"id" => to_string(no_tb_player.id)})
      refute has_element?(lv, ".modal-card .pe-summary")

      {:ok, tb_tournament} =
        Tournaments.create_tournament(scope, %{
          "name" => "Card Modal TB Test",
          "type" => "swiss",
          "tiebreaks" => ["BH", "SB"]
        })

      {:ok, tb_player} = Tournaments.create_player(tb_tournament.id, %{"name" => "Dave"})

      {:ok, lv2, _html} = live(conn, ~p"/t/#{tb_tournament.id}/players")
      html = render_click(lv2, "show_card", %{"id" => to_string(tb_player.id)})

      assert html =~ ~s(title="Buchholz")
      assert html =~ ~s(title="Sonneborn-Berger")
      assert html =~ "BH"
      assert html =~ "SB"
    end

    test "Exit closes the card via close_card", %{
      conn: conn,
      tournament: tournament,
      player: player
    } do
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      render_click(lv, "show_card", %{"id" => to_string(player.id)})
      html = lv |> element("button", "Exit") |> render_click()

      refute html =~ "<h2>Players Card</h2>"
      refute html =~ ~s(phx-click-away="close_card")
    end
  end

  describe "KBSB autofill (add-player form)" do
    setup %{scope: scope} do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{
          "name" => "KBSB Add Test",
          "type" => "swiss",
          "start_date" => "2026-07-15",
          "rounds_count" => "9",
          "round_dates" => List.duplicate("2026-07-15", 9),
          "tiebreaks" => ["BH", "SB"],
          "chief_arbiter" => "Jane Arbiter",
          "federation" => "BEL",
          "rate_of_play" => "90 min + 30 sec/move"
        })

      Repo.insert!(%KbsbPlayer{
        national_id: "12345",
        last_name: "Peeters",
        first_name: "Jan",
        national_rating: 1850,
        fide_id: nil,
        club_number: 42,
        club_name: "KSK Antwerpen",
        federation: "VSF",
        birth_year: 1990
      })

      %{tournament: tournament}
    end

    test "entering a known national id fills national rating and other blank fields", %{
      conn: conn,
      tournament: tournament
    } do
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      render_click(lv, "add", %{})
      html = render_change(lv, "lookup_kbsb_add", %{"player" => %{"national_id" => "12345"}})

      assert html =~ ~s(value="1850")
      assert html =~ ~s(value="VSF")
      assert html =~ ~s(value="1990")
      assert html =~ ~s(value="KSK Antwerpen")
      assert html =~ "Peeters, Jan"
    end

    test "an unknown national id leaves the form untouched", %{conn: conn, tournament: tournament} do
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      render_click(lv, "add", %{})
      html = render_change(lv, "lookup_kbsb_add", %{"player" => %{"national_id" => "no-such-id"}})

      refute html =~ "Peeters"
    end

    test "picking a FIDE search result also fills in the matching KBSB row by FIDE id", %{
      conn: conn,
      tournament: tournament
    } do
      Repo.insert!(%FidePlayer{
        fide_id: 555_555,
        name: "Peeters, Jan",
        federation: "BEL",
        birth_year: 1990,
        title: "",
        standard_rating: 1900
      })

      Repo.update_all(
        from(k in KbsbPlayer, where: k.national_id == "12345"),
        set: [fide_id: 555_555]
      )

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      render_click(lv, "add", %{})
      render_change(lv, "search", %{"q" => "555555"})
      html = render_click(lv, "pick", %{"fide-id" => "555555"})

      # FIDE fields...
      assert html =~ ~s(value="555555")
      assert html =~ ~s(value="1900")
      # ...and the cross-referenced KBSB fields.
      assert html =~ ~s(value="12345")
      assert html =~ ~s(value="1850")
      assert html =~ ~s(value="KSK Antwerpen")
    end
  end

  describe "KBSB autofill (edit modal)" do
    setup %{scope: scope} do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{"name" => "KBSB Edit Test", "type" => "swiss"})

      {:ok, player} =
        Tournaments.create_player(tournament.id, %{"name" => "Alice", "national_id" => "12345"})

      Repo.insert!(%KbsbPlayer{
        national_id: "12345",
        last_name: "Peeters",
        first_name: "Jan",
        national_rating: 1850,
        fide_id: 555_555,
        club_number: 42,
        club_name: "KSK Antwerpen",
        federation: "VSF",
        birth_year: 1990
      })

      %{tournament: tournament, player: player}
    end

    test "the KBSB refresh button fills national rating, club, federation, birth year and fide id",
         %{
           conn: conn,
           tournament: tournament,
           player: player
         } do
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      render_click(lv, "edit_player", %{"id" => to_string(player.id)})
      html = lv |> element("button", "KBSB") |> render_click()

      assert html =~ ~s(value="1850")
      assert html =~ ~s(value="VSF")
      assert html =~ ~s(value="KSK Antwerpen")
      assert html =~ ~s(value="1990")
      assert html =~ ~s(value="555555")
    end

    test "when KBSB fills a previously-blank FIDE id, it also immediately pulls that player's FIDE data",
         %{conn: conn, tournament: tournament, player: player} do
      Repo.insert!(%FidePlayer{
        fide_id: 555_555,
        name: "Peeters, Jan",
        title: "FM",
        federation: "BEL",
        standard_rating: 2100,
        birth_year: 1990
      })

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      render_click(lv, "edit_player", %{"id" => to_string(player.id)})
      html = lv |> element("button", "KBSB") |> render_click()

      # KBSB's own fields, plus the FIDE data reachable through the id it
      # just found — no need to click "FIDE lookup" a second time by hand.
      assert html =~ ~s(value="555555")
      assert html =~ ~s(value="2100")
      assert html =~ "Peeters, Jan"
    end

    test "when the KBSB-linked FIDE id isn't in our local FIDE copy, KBSB's own data is still applied",
         %{conn: conn, tournament: tournament, player: player} do
      # No FidePlayer 555_555 inserted — simulates a stale/not-yet-synced
      # local FIDE list. The KBSB half of the lookup must not be thrown
      # away just because the FIDE follow-up came back empty.
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      render_click(lv, "edit_player", %{"id" => to_string(player.id)})
      html = lv |> element("button", "KBSB") |> render_click()

      assert html =~ ~s(value="1850")
      assert html =~ ~s(value="555555")
      refute html =~ "No matching FIDE player found"
    end

    test "does not clobber an existing FIDE id already on the form", %{
      conn: conn,
      tournament: tournament
    } do
      {:ok, other} =
        Tournaments.create_player(tournament.id, %{
          "name" => "Bob",
          "national_id" => "12345",
          "fide_id" => "9",
          "fide_rating" => "1000"
        })

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      render_click(lv, "edit_player", %{"id" => to_string(other.id)})
      html = lv |> element("button", "KBSB") |> render_click()

      # The pre-existing FIDE id (9) wins — KBSB only fills FIDE id when blank.
      assert html =~ ~s(value="9")
      refute html =~ ~s(value="555555")
    end

    test "shows an error when the National ID field is blank", %{
      conn: conn,
      tournament: tournament
    } do
      {:ok, blank} = Tournaments.create_player(tournament.id, %{"name" => "NoId"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      render_click(lv, "edit_player", %{"id" => to_string(blank.id)})
      html = lv |> element("button", "KBSB") |> render_click()

      assert html =~ "Enter a National ID first"
    end

    test "shows an error when no KBSB row matches", %{conn: conn, tournament: tournament} do
      {:ok, unknown} =
        Tournaments.create_player(tournament.id, %{"name" => "Ghost", "national_id" => "no-match"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      render_click(lv, "edit_player", %{"id" => to_string(unknown.id)})
      html = lv |> element("button", "KBSB") |> render_click()

      assert html =~ "No matching KBSB player found"
    end
  end

  describe "Fixed table conflict hint (edit modal)" do
    setup %{scope: scope} do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{"name" => "Fixed Board Test", "type" => "swiss"})

      {:ok, alice} =
        Tournaments.create_player(tournament.id, %{"name" => "Alice", "fixed_board" => "1001"})

      {:ok, bob} = Tournaments.create_player(tournament.id, %{"name" => "Bob"})

      %{tournament: tournament, alice: alice, bob: bob}
    end

    test "typing a fixed_board value already used by another player shows who", %{
      conn: conn,
      tournament: tournament,
      bob: bob
    } do
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      render_click(lv, "edit_player", %{"id" => to_string(bob.id)})

      html =
        lv
        |> form("#player-edit-form", player: %{"name" => "Bob", "fixed_board" => "1001"})
        |> render_change()

      assert html =~ "Also used by: Alice"
    end

    test "no hint when the value is unique", %{conn: conn, tournament: tournament, bob: bob} do
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      render_click(lv, "edit_player", %{"id" => to_string(bob.id)})

      html =
        lv
        |> form("#player-edit-form", player: %{"name" => "Bob", "fixed_board" => "1002"})
        |> render_change()

      refute html =~ "Also used by"
    end

    test "editing the player who already owns the value doesn't warn against themselves", %{
      conn: conn,
      tournament: tournament,
      alice: alice
    } do
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      html = render_click(lv, "edit_player", %{"id" => to_string(alice.id)})

      refute html =~ "Also used by"
    end

    test "no hint when the field is blank", %{conn: conn, tournament: tournament, bob: bob} do
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      html = render_click(lv, "edit_player", %{"id" => to_string(bob.id)})

      refute html =~ "Also used by"
    end
  end

  describe "FIDE lookup (edit modal)" do
    setup %{scope: scope} do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{"name" => "FIDE Edit Test", "type" => "swiss"})

      %{tournament: tournament}
    end

    test "by FIDE id: a name reformat is still staged behind a confirm, not applied silently", %{
      conn: conn,
      tournament: tournament
    } do
      {:ok, player} =
        Tournaments.create_player(tournament.id, %{
          "name" => "tijl de moyer",
          "fide_id" => "214566"
        })

      Repo.insert!(%FidePlayer{
        fide_id: 214_566,
        name: "De Moyer, Tijl",
        federation: "BEL",
        standard_rating: 1865,
        birth_year: 1982
      })

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      render_click(lv, "edit_player", %{"id" => to_string(player.id)})
      html = lv |> element("button", "FIDE lookup") |> render_click()

      # Operational fields (birth year here) apply directly regardless...
      assert html =~ ~s(value="1982")
      # ...but the name isn't silently rewritten, even though it's an
      # exact FIDE-ID match — an already-filled identity field always gets
      # a human's sign-off on a real change.
      assert html =~ ~s(value="tijl de moyer")
      refute html =~ ~s(value="De Moyer, Tijl")
      assert html =~ "FIDE disagrees"

      html = lv |> element("button[phx-click='apply_fide_conflicts']") |> render_click()
      assert html =~ ~s(value="De Moyer, Tijl")
      refute html =~ "FIDE disagrees"
    end

    test "also fills in Sex, normalized from FIDE's raw M/F to the app's m/w convention", %{
      conn: conn,
      tournament: tournament
    } do
      {:ok, player} =
        Tournaments.create_player(tournament.id, %{
          "name" => "tijl de moyer",
          "fide_id" => "214566"
        })

      Repo.insert!(%FidePlayer{
        fide_id: 214_566,
        name: "De Moyer, Tijl",
        federation: "BEL",
        standard_rating: 1865,
        sex: "M"
      })

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      render_click(lv, "edit_player", %{"id" => to_string(player.id)})
      html = lv |> element("button", "FIDE lookup") |> render_click()

      # The checked radio is the app's internal "m", not FIDE's raw "M".
      assert html =~ ~r/name="player\[sex\]" value="m" checked/
      refute html =~ ~r/name="player\[sex\]" value="w" checked/
    end

    test "changing an already-set Sex is staged behind a confirm, not applied silently", %{
      conn: conn,
      tournament: tournament
    } do
      {:ok, player} =
        Tournaments.create_player(tournament.id, %{
          "name" => "De Moyer, Tijl",
          "fide_id" => "214566",
          "sex" => "w"
        })

      Repo.insert!(%FidePlayer{
        fide_id: 214_566,
        name: "De Moyer, Tijl",
        federation: "BEL",
        standard_rating: 1865,
        sex: "M"
      })

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      render_click(lv, "edit_player", %{"id" => to_string(player.id)})
      html = lv |> element("button", "FIDE lookup") |> render_click()

      # Not silently flipped — the radio still shows what was on file...
      assert html =~ ~r/name="player\[sex\]" value="w" checked/
      refute html =~ ~r/name="player\[sex\]" value="m" checked/
      # ...and the conflict is visible, naming the field and FIDE's value.
      assert html =~ "FIDE disagrees"
      assert html =~ "Sex → M"

      html = lv |> element("button[phx-click='apply_fide_conflicts']") |> render_click()
      assert html =~ ~r/name="player\[sex\]" value="m" checked/
      refute html =~ "FIDE disagrees"
    end

    test "changing an already-set birth year is staged behind a confirm", %{
      conn: conn,
      tournament: tournament
    } do
      {:ok, player} =
        Tournaments.create_player(tournament.id, %{
          "name" => "De Moyer, Tijl",
          "fide_id" => "214566",
          "birth_year" => "1980"
        })

      Repo.insert!(%FidePlayer{
        fide_id: 214_566,
        name: "De Moyer, Tijl",
        federation: "BEL",
        standard_rating: 1865,
        birth_year: 1982
      })

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      render_click(lv, "edit_player", %{"id" => to_string(player.id)})
      html = lv |> element("button", "FIDE lookup") |> render_click()

      assert html =~ ~s(value="1980")
      refute html =~ ~s(value="1982")
      assert html =~ "FIDE disagrees"
      assert html =~ "Birth year → 1982"

      html = lv |> element("button[phx-click='reject_fide_conflicts']") |> render_click()
      assert html =~ ~s(value="1980")
      refute html =~ "FIDE disagrees"
    end

    test "a matching birth year (string vs integer form) doesn't falsely flag as a conflict", %{
      conn: conn,
      tournament: tournament
    } do
      {:ok, player} =
        Tournaments.create_player(tournament.id, %{
          "name" => "De Moyer, Tijl",
          "fide_id" => "214566",
          "birth_year" => "1982"
        })

      Repo.insert!(%FidePlayer{
        fide_id: 214_566,
        name: "De Moyer, Tijl",
        federation: "BEL",
        standard_rating: 1865,
        birth_year: 1982
      })

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      render_click(lv, "edit_player", %{"id" => to_string(player.id)})
      html = lv |> element("button", "FIDE lookup") |> render_click()

      refute html =~ "FIDE disagrees"
    end

    test "multiple conflicting fields at once are all listed together", %{
      conn: conn,
      tournament: tournament
    } do
      {:ok, player} =
        Tournaments.create_player(tournament.id, %{
          "name" => "De Moyer, Tijl",
          "fide_id" => "214566",
          "sex" => "w",
          "birth_year" => "1980"
        })

      Repo.insert!(%FidePlayer{
        fide_id: 214_566,
        name: "De Moyer, Tijl",
        federation: "BEL",
        standard_rating: 1865,
        sex: "M",
        birth_year: 1982
      })

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      render_click(lv, "edit_player", %{"id" => to_string(player.id)})
      html = lv |> element("button", "FIDE lookup") |> render_click()

      assert html =~ "Sex → M"
      assert html =~ "Birth year → 1982"

      html = lv |> element("button[phx-click='apply_fide_conflicts']") |> render_click()
      assert html =~ ~r/name="player\[sex\]" value="m" checked/
      assert html =~ ~s(value="1982")
      refute html =~ "FIDE disagrees"
    end

    test "operational fields (title/rating/federation) still apply directly, even when changing",
         %{conn: conn, tournament: tournament} do
      {:ok, player} =
        Tournaments.create_player(tournament.id, %{
          "name" => "De Moyer, Tijl",
          "fide_id" => "214566",
          "fide_rating" => "1500",
          "federation" => "FRA",
          "title" => "CM"
        })

      Repo.insert!(%FidePlayer{
        fide_id: 214_566,
        name: "De Moyer, Tijl",
        federation: "BEL",
        title: "FM",
        standard_rating: 1865
      })

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      render_click(lv, "edit_player", %{"id" => to_string(player.id)})
      html = lv |> element("button", "FIDE lookup") |> render_click()

      assert html =~ ~s(value="1865")
      assert html =~ ~s(value="BEL")
      refute html =~ "FIDE disagrees"
    end

    test "by name: fills the other fields but stages a genuinely different name behind a yes/no prompt",
         %{conn: conn, tournament: tournament} do
      # "tijl" alone vs FIDE's full "De Moyer, Tijl" — a real token-set
      # difference (not just reordering/reformatting), so this is a
      # genuine identity question worth a human's sign-off, not just a
      # spelling normalization.
      {:ok, player} = Tournaments.create_player(tournament.id, %{"name" => "tijl"})

      Repo.insert!(%FidePlayer{
        fide_id: 214_566,
        name: "De Moyer, Tijl",
        federation: "BEL",
        standard_rating: 1865,
        birth_year: 1982
      })

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      render_click(lv, "edit_player", %{"id" => to_string(player.id)})
      html = lv |> element("button", "FIDE lookup") |> render_click()

      # Other fields applied immediately.
      assert html =~ ~s(value="214566")
      assert html =~ ~s(value="BEL")
      assert html =~ ~s(value="1982")
      # Name not overwritten yet — staged behind the prompt instead.
      assert html =~ ~s(value="tijl")
      assert html =~ "De Moyer, Tijl"
      assert html =~ "FIDE disagrees"

      html = lv |> element("button[phx-click='apply_fide_conflicts']") |> render_click()
      assert html =~ ~s(value="De Moyer, Tijl")
      refute html =~ "FIDE disagrees"
    end

    test "by name: No keeps the original name but leaves the other fields applied", %{
      conn: conn,
      tournament: tournament
    } do
      {:ok, player} = Tournaments.create_player(tournament.id, %{"name" => "tijl"})

      Repo.insert!(%FidePlayer{
        fide_id: 214_566,
        name: "De Moyer, Tijl",
        federation: "BEL",
        standard_rating: 1865,
        birth_year: 1982
      })

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      render_click(lv, "edit_player", %{"id" => to_string(player.id)})
      lv |> element("button", "FIDE lookup") |> render_click()

      html = lv |> element("button[phx-click='reject_fide_conflicts']") |> render_click()
      assert html =~ ~s(value="tijl")
      assert html =~ ~s(value="BEL")
      refute html =~ "FIDE disagrees"
    end

    test "by name: a same-identity reformat (case/comma/word order) still gets a prompt, not a silent rewrite",
         %{conn: conn, tournament: tournament} do
      {:ok, player} =
        Tournaments.create_player(tournament.id, %{"name" => "de moyer tijl"})

      Repo.insert!(%FidePlayer{
        fide_id: 214_566,
        name: "De Moyer, Tijl",
        federation: "BEL",
        standard_rating: 1865
      })

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      render_click(lv, "edit_player", %{"id" => to_string(player.id)})
      html = lv |> element("button", "FIDE lookup") |> render_click()

      # Not silently rewritten — the original text is still what's shown...
      assert html =~ ~s(value="de moyer tijl")
      refute html =~ ~s(value="De Moyer, Tijl")
      # ...and the prompt names the real correction.
      assert html =~ "FIDE disagrees"
      assert html =~ "De Moyer, Tijl"

      html = lv |> element("button[phx-click='apply_fide_conflicts']") |> render_click()
      assert html =~ ~s(value="De Moyer, Tijl")
      refute html =~ "FIDE disagrees"
    end

    test "by name: re-running the lookup when the name is already an exact match is a genuine no-op",
         %{conn: conn, tournament: tournament} do
      {:ok, player} =
        Tournaments.create_player(tournament.id, %{"name" => "De Moyer, Tijl"})

      Repo.insert!(%FidePlayer{
        fide_id: 214_566,
        name: "De Moyer, Tijl",
        federation: "BEL",
        standard_rating: 1865
      })

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      render_click(lv, "edit_player", %{"id" => to_string(player.id)})
      html = lv |> element("button", "FIDE lookup") |> render_click()

      assert html =~ ~s(value="De Moyer, Tijl")
      refute html =~ "FIDE disagrees"
    end

    test "typing a name live (no save first) is what the lookup actually searches, not a stale snapshot",
         %{conn: conn, tournament: tournament} do
      {:ok, player} = Tournaments.create_player(tournament.id, %{"name" => "placeholder"})

      Repo.insert!(%FidePlayer{
        fide_id: 214_566,
        name: "Burssens, Jorian",
        federation: "BEL",
        standard_rating: 1865
      })

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      render_click(lv, "edit_player", %{"id" => to_string(player.id)})

      # Hand-typed, never saved — mirrors editing the field then immediately
      # clicking the lookup button, with no fide_id present to short-circuit
      # to the exact-ID (no-confirmation) path.
      lv
      |> form("#player-edit-form", player: %{"name" => "jorian burssens"})
      |> render_change()

      html = lv |> element("button", "FIDE lookup") |> render_click()

      # The live-typed value ("jorian burssens") is what got searched, not
      # some stale snapshot — proven by the match actually being found:
      # operational fields (federation) apply directly, and the name
      # correction ("jorian burssens" -> FIDE's own "Burssens, Jorian") is
      # a real reformat, so it's staged behind the confirm prompt rather
      # than silently rewritten.
      assert html =~ ~s(value="BEL")
      assert html =~ ~s(value="jorian burssens")
      assert html =~ "FIDE disagrees"

      html = lv |> element("button[phx-click='apply_fide_conflicts']") |> render_click()
      assert html =~ ~s(value="Burssens, Jorian")
      refute html =~ "FIDE disagrees"
    end

    test "shows an error when both FIDE id and name are blank", %{
      conn: conn,
      tournament: tournament
    } do
      {:ok, player} = Tournaments.create_player(tournament.id, %{"name" => "placeholder"})
      # Name is required on creation; blanked directly to reach the both-blank
      # form state (e.g. legacy/imported data) without a live-typing round-trip.
      from(p in PairingsEngine.Tournaments.Player, where: p.id == ^player.id)
      |> Repo.update_all(set: [name: ""])

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      render_click(lv, "edit_player", %{"id" => to_string(player.id)})
      html = lv |> element("button", "FIDE lookup") |> render_click()

      assert html =~ "Enter a FIDE ID or name first"
    end
  end

  describe "bulk rating refresh (Refresh ratings button)" do
    setup %{scope: scope} do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{"name" => "Refresh Test", "type" => "swiss"})

      %{tournament: tournament}
    end

    test "no players registered shows the empty-diff message", %{
      conn: conn,
      tournament: tournament
    } do
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      html = lv |> element("button", "Refresh ratings") |> render_click()

      assert html =~ "Everything up to date"
      assert html =~ "0 players checked"
    end

    test "shows the diff table and applies changes on Apply", %{
      conn: conn,
      tournament: tournament
    } do
      {:ok, player} =
        Tournaments.create_player(tournament.id, %{
          "name" => "Alice",
          "fide_id" => "555555",
          "fide_rating" => "1900"
        })

      Repo.insert!(%FidePlayer{
        fide_id: 555_555,
        name: "Alice",
        federation: "BEL",
        title: "IM",
        standard_rating: 2100
      })

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      html = lv |> element("button", "Refresh ratings") |> render_click()

      assert html =~ "FIDE rating"
      assert html =~ "1900"
      assert html =~ "2100"
      assert html =~ "Title"
      assert html =~ "1 player checked"
      assert html =~ "1 change"

      lv |> element("button", "Apply") |> render_click()
      # This click both writes (via RatingRefresh.apply/2) and broadcasts —
      # synchronize before asserting so the reload always lands before we look.
      html = render(lv)

      refute html =~ "phx-click-away=\"close_rating_refresh\""

      updated = Tournaments.get_player!(player.tournament_id, player.id)
      assert updated.fide_rating == 2100
      assert updated.title == "IM"
    end

    test "Cancel closes the modal without writing anything", %{conn: conn, tournament: tournament} do
      {:ok, player} =
        Tournaments.create_player(tournament.id, %{
          "name" => "Bob",
          "fide_id" => "42",
          "fide_rating" => "1500"
        })

      Repo.insert!(%FidePlayer{fide_id: 42, name: "Bob", standard_rating: 1800})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      lv |> element("button", "Refresh ratings") |> render_click()
      html = lv |> element("button", "Cancel") |> render_click()

      refute html =~ "phx-click-away=\"close_rating_refresh\""
      assert Tournaments.get_player!(player.tournament_id, player.id).fide_rating == 1500
    end
  end

  describe "sortable columns" do
    setup %{scope: scope} do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{"name" => "Sort Test", "type" => "swiss"})

      {:ok, alice} =
        Tournaments.create_player(tournament.id, %{
          "name" => "Alice",
          "club" => "Zeta Club",
          "birth_year" => "1990",
          "extra_points" => "2.0"
        })

      {:ok, bob} =
        Tournaments.create_player(tournament.id, %{
          "name" => "Bob",
          "club" => "Alpha Club",
          "extra_points" => "0.5"
        })

      {:ok, carol} =
        Tournaments.create_player(tournament.id, %{
          "name" => "Carol",
          "club" => "Middle Club",
          "birth_year" => "2000",
          "extra_points" => "1.0"
        })

      %{tournament: tournament, alice: alice, bob: bob, carol: carol}
    end

    defp position(html, needle) do
      case :binary.match(html, needle) do
        {pos, _len} -> pos
        :nomatch -> flunk("expected #{inspect(needle)} to be present in the rendered HTML")
      end
    end

    # Extracts the trimmed text content of every `<td class="num">...</td>`
    # cell in `row_html`, in document order — used to check individual
    # numeric-column values without depending on exact whitespace.
    defp num_cells(row_html) do
      ~r/<td class="num"[^>]*>(.*?)<\/td>/s
      |> Regex.scan(row_html)
      |> Enum.map(fn [_, inner] -> String.trim(inner) end)
    end

    test "clicking a bio column header sorts ascending by that column's underlying value (case-insensitive)",
         %{conn: conn, tournament: tournament} do
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      html = render_click(lv, "sort", %{"key" => "club"})

      # Alpha Club (Bob) < Middle Club (Carol) < Zeta Club (Alice)
      assert position(html, "Bob") < position(html, "Carol")
      assert position(html, "Carol") < position(html, "Alice")
      assert html =~ "▲"
    end

    test "clicking the same header again flips to descending", %{
      conn: conn,
      tournament: tournament
    } do
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      render_click(lv, "sort", %{"key" => "club"})
      html = render_click(lv, "sort", %{"key" => "club"})

      # Descending: Zeta Club (Alice) > Middle Club (Carol) > Alpha Club (Bob)
      assert position(html, "Alice") < position(html, "Carol")
      assert position(html, "Carol") < position(html, "Bob")
      assert html =~ "▼"
    end

    test "sorting by a computed grid column (XtPts) sorts numerically, not as a string", %{
      conn: conn,
      tournament: tournament
    } do
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      html = render_click(lv, "sort", %{"key" => "xtpts"})

      # Ascending by extra points: Bob (0.5) < Carol (1.0) < Alice (2.0). A
      # naive string sort would put "0.5" < "1.0" < "2.0" too, so this alone
      # wouldn't catch a stringified sort — the real regression guard is that
      # a numeric column never crashes when compared, exercised across all
      # these tests via mixed nil/blank values.
      assert position(html, "Bob") < position(html, "Carol")
      assert position(html, "Carol") < position(html, "Alice")
    end

    test "clicking a different header switches to that column, ascending", %{
      conn: conn,
      tournament: tournament
    } do
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      render_click(lv, "sort", %{"key" => "club"})
      render_click(lv, "sort", %{"key" => "club"})
      html = render_click(lv, "sort", %{"key" => "xtpts"})

      assert position(html, "Bob") < position(html, "Carol")
      assert position(html, "Carol") < position(html, "Alice")
      assert html =~ "▲"
    end

    test "nil/blank values sort last in both directions", %{conn: conn, tournament: tournament} do
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      # Bob has no birth_year — must sort after both Alice (1990) and Carol
      # (2000) whether ascending or descending.
      asc_html = render_click(lv, "sort", %{"key" => "birth_year"})
      assert position(asc_html, "Alice") < position(asc_html, "Bob")
      assert position(asc_html, "Carol") < position(asc_html, "Bob")

      desc_html = render_click(lv, "sort", %{"key" => "birth_year"})
      assert position(desc_html, "Alice") < position(desc_html, "Bob")
      assert position(desc_html, "Carol") < position(desc_html, "Bob")
    end

    test "the N1 header sorts by the same ranking as Cl (phx-value-key is \"cl\", not \"name\")",
         %{conn: conn, tournament: tournament} do
      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/players")

      assert html =~ "N1"
      assert html =~ ~s(phx-value-key="cl")

      # No ratings given, so all three tie on rank/rating — `entry.rank`'s
      # own order (Alice, Bob, Carol, per `list_players/1`'s
      # rating-desc/name-asc ordering) already matches ascending "cl", so
      # the first click is a no-op; the real proof N1 is wired to the same
      # "cl" sort (not "name", as it was before this change) is that a
      # second click flips it to descending rank order.
      render_click(lv, "sort", %{"key" => "cl"})
      html = render_click(lv, "sort", %{"key" => "cl"})

      assert position(html, "Carol") < position(html, "Bob")
      assert position(html, "Bob") < position(html, "Alice")
    end
  end

  describe "default sort order (real tournament ranking, not just rating)" do
    test "with no column clicked, players sort by points/total, not rating or name", %{
      conn: conn,
      scope: scope
    } do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{
          "name" => "Default Sort Test",
          "type" => "swiss",
          "count_extra_points" => true
        })

      # Equal ratings (0) for all three, so a rating/name-based default would
      # list them alphabetically: Alice, Bob, Carol. Extra points (counted
      # into `total` because count_extra_points is on) instead should rank
      # Bob (5) > Carol (2) > Alice (0).
      {:ok, _alice} =
        Tournaments.create_player(tournament.id, %{"name" => "Alice", "extra_points" => "0"})

      {:ok, _bob} =
        Tournaments.create_player(tournament.id, %{"name" => "Bob", "extra_points" => "5"})

      {:ok, _carol} =
        Tournaments.create_player(tournament.id, %{"name" => "Carol", "extra_points" => "2"})

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/players")

      assert position(html, "Bob") < position(html, "Carol")
      assert position(html, "Carol") < position(html, "Alice")
    end

    test "ties on points/tiebreaks fall back to rating descending, then name", %{
      conn: conn,
      scope: scope
    } do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{
          "name" => "Rating Fallback Test",
          "type" => "swiss"
        })

      # No games played -> everyone tied on points (0) and every tiebreak
      # (0) -> default order should fall back to rating descending.
      {:ok, _low} =
        Tournaments.create_player(tournament.id, %{"name" => "Low", "fide_rating" => "1200"})

      {:ok, _high} =
        Tournaments.create_player(tournament.id, %{"name" => "High", "fide_rating" => "2000"})

      {:ok, _mid} =
        Tournaments.create_player(tournament.id, %{"name" => "Mid", "fide_rating" => "1600"})

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/players")

      assert position(html, "High") < position(html, "Mid")
      assert position(html, "Mid") < position(html, "Low")
    end
  end

  describe "Rnk column (live rating-based seed, distinct from frozen Nr)" do
    test "Rnk recomputes fresh and can differ from the frozen Nr after a rating correction", %{
      conn: conn,
      scope: scope
    } do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{"name" => "Rnk Test", "type" => "swiss"})

      {:ok, alice} =
        Tournaments.create_player(tournament.id, %{"name" => "Alice", "fide_rating" => "1000"})

      {:ok, bob} =
        Tournaments.create_player(tournament.id, %{"name" => "Bob", "fide_rating" => "2000"})

      # Freeze pairing numbers the same way the real pairing run does: Bob
      # (higher rating) gets Nr 1, Alice gets Nr 2.
      players = Tournaments.list_players(tournament.id)
      PairingsEngine.Pairing.ensure_pairing_numbers(tournament, players)

      alice = Tournaments.get_player!(alice.tournament_id, alice.id)
      bob = Tournaments.get_player!(bob.tournament_id, bob.id)
      assert bob.pairing_number == 1
      assert alice.pairing_number == 2

      # Now correct Alice's rating upward, past Bob's, *after* numbers were
      # frozen — Nr must stay put (it's frozen), but the live Rnk column
      # must reflect the new rating order immediately.
      {:ok, _alice} = Tournaments.update_player(alice, %{"fide_rating" => "2500"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")
      render_click(lv, "toggle_column", %{"key" => "nr"})
      html = render_click(lv, "toggle_column", %{"key" => "rnk"})

      alice_row = html |> String.split(~s(data-player-id="#{alice.id}")) |> Enum.at(1)
      bob_row = html |> String.split(~s(data-player-id="#{bob.id}")) |> Enum.at(1)

      # Visible numeric columns, in order: N1, Cl, Nr, Rnk, ... — so index 2
      # is the frozen Nr and index 3 is the live Rnk.
      alice_cells = num_cells(alice_row)
      bob_cells = num_cells(bob_row)

      # Frozen Nr is unchanged...
      assert Enum.at(alice_cells, 2) == "2"
      assert Enum.at(bob_cells, 2) == "1"

      # ...but the live Rnk column now puts Alice (2500) ahead of Bob (2000).
      assert Enum.at(alice_cells, 3) == "1"
      assert Enum.at(bob_cells, 3) == "2"
    end
  end

  describe "Pr. column (SWAR presence notation)" do
    test "encodes forfeit, whole-event absence, and per-round absence with case", %{
      conn: conn,
      scope: scope
    } do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{"name" => "Presence Test", "type" => "swiss"})

      {:ok, range} =
        Tournaments.create_player(tournament.id, %{"name" => "Range", "absent_rounds" => "1-3"})

      {:ok, later} =
        Tournaments.create_player(tournament.id, %{"name" => "Later", "absent_rounds" => "4,5"})

      {:ok, all_event} =
        Tournaments.create_player(tournament.id, %{"name" => "AllEvent", "absent" => true})

      {:ok, here} = Tournaments.create_player(tournament.id, %{"name" => "Here"})

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/players")

      # Every cell in the player's row, so the assertions do not depend on
      # which column index Pr. happens to sit at.
      cells = fn player ->
        row =
          html
          |> String.split(~s(data-player-id="#{player.id}"))
          |> Enum.at(1)
          |> String.split("</tr>")
          |> Enum.at(0)

        ~r{<td[^>]*>(.*?)</td>}s
        |> Regex.scan(row)
        |> Enum.map(fn [_, inner] -> String.trim(inner) end)
      end

      # Nothing paired yet, so round 1 is the one about to be paired.
      # "1-3" is stored expanded AND covers round 1 -> capital A.
      assert range.absent_rounds == "1,2,3"
      assert "A(1,2,3)" in cells.(range)

      # Absences recorded, but none of them is round 1 -> lowercase a,
      # i.e. on the record but available right now.
      assert "a(4,5)" in cells.(later)

      # The whole-event boolean is a bare capital, no round list.
      assert "A" in cells.(all_event)

      # A present player carries no marker at all.
      here_cells = cells.(here)
      refute Enum.any?(here_cells, &String.starts_with?(&1, "A"))
      refute Enum.any?(here_cells, &String.starts_with?(&1, "a("))
    end
  end

  describe "Pr. cell click/right-click menu (Absent / Present)" do
    test "Absent sets the whole-event flag but leaves recorded rounds alone", %{
      conn: conn,
      scope: scope
    } do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{"name" => "Pr Menu Test", "type" => "swiss"})

      {:ok, player} =
        Tournaments.create_player(tournament.id, %{"name" => "Later", "absent_rounds" => "4,5"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      html =
        render_click(lv, "set_absent_flag", %{"id" => to_string(player.id), "value" => "true"})

      assert "A" in cells_for(html, player.id)
      reloaded = Tournaments.get_player!(tournament.id, player.id)
      assert reloaded.absent
      assert reloaded.absent_rounds == "4,5"
    end

    test "Present clears the flag but leaves recorded rounds alone", %{
      conn: conn,
      scope: scope
    } do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{"name" => "Pr Menu Test 2", "type" => "swiss"})

      {:ok, player} =
        Tournaments.create_player(tournament.id, %{
          "name" => "Both",
          "absent" => true,
          "absent_rounds" => "2"
        })

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      html =
        render_click(lv, "set_absent_flag", %{"id" => to_string(player.id), "value" => "false"})

      assert "a(2)" in cells_for(html, player.id)
      reloaded = Tournaments.get_player!(tournament.id, player.id)
      refute reloaded.absent
      assert reloaded.absent_rounds == "2"
    end

    test "an unknown id is ignored rather than crashing the view", %{
      conn: conn,
      scope: scope
    } do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{"name" => "Pr Menu Test 3", "type" => "swiss"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      assert render_click(lv, "set_absent_flag", %{"id" => "999999", "value" => "true"})
    end
  end

  describe "Paid cell click/right-click menu (fee status)" do
    test "each of the three states writes through and shows its letter", %{
      conn: conn,
      scope: scope
    } do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{"name" => "Paid Menu Test", "type" => "swiss"})

      {:ok, player} = Tournaments.create_player(tournament.id, %{"name" => "Fee Payer"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")
      # Paid is not on by default; a user right-clicking it has switched it
      # on from the column picker first.
      render_click(lv, "toggle_column", %{"key" => "paid"})

      for {value, letter} <- [{"nopaid", "N"}, {"gratis", "G"}, {"paid", "P"}] do
        html = render_click(lv, "set_paid", %{"id" => to_string(player.id), "value" => value})

        assert letter in cells_for(html, player.id),
               ~s(setting "#{value}" should render "#{letter}" in the Paid column)

        assert Tournaments.get_player!(tournament.id, player.id).paid == value
      end
    end

    test "a value outside the three states is refused, not stored", %{conn: conn, scope: scope} do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{"name" => "Paid Reject", "type" => "swiss"})

      {:ok, player} = Tournaments.create_player(tournament.id, %{"name" => "Fee Payer"})
      before = Tournaments.get_player!(tournament.id, player.id).paid

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")
      render_click(lv, "set_paid", %{"id" => to_string(player.id), "value" => "sponsored"})

      assert Tournaments.get_player!(tournament.id, player.id).paid == before
    end

    test "an unknown player id is a no-op rather than a crash", %{conn: conn, scope: scope} do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{"name" => "Paid Missing", "type" => "swiss"})

      {:ok, _player} = Tournaments.create_player(tournament.id, %{"name" => "Fee Payer"})
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      assert render_click(lv, "set_paid", %{"id" => "999999", "value" => "paid"})
    end

    test "the column header's bulk action sets every player at once", %{conn: conn, scope: scope} do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{"name" => "Paid Bulk", "type" => "swiss"})

      for name <- ~w(One Two Three) do
        {:ok, _} = Tournaments.create_player(tournament.id, %{"name" => name})
      end

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")
      render_click(lv, "set_all_paid", %{"value" => "nopaid"})

      assert Enum.all?(Tournaments.list_players(tournament.id), &(&1.paid == "nopaid"))

      render_click(lv, "set_all_paid", %{"value" => "gratis"})

      assert Enum.all?(Tournaments.list_players(tournament.id), &(&1.paid == "gratis"))
    end

    test "a bad bulk value touches nobody", %{conn: conn, scope: scope} do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{"name" => "Paid Bulk Reject", "type" => "swiss"})

      for name <- ~w(One Two) do
        {:ok, _} = Tournaments.create_player(tournament.id, %{"name" => name})
      end

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")
      render_click(lv, "set_all_paid", %{"value" => "sponsored"})

      assert Enum.all?(Tournaments.list_players(tournament.id), &(&1.paid == "paid"))
    end
  end

  # Every cell in a player's row, so assertions do not depend on which
  # column index a given field happens to sit at. Shared by the SWAR
  # presence-notation tests and the Pr. cell context-menu tests above.
  defp cells_for(html, player_id) do
    row =
      html
      |> String.split(~s(data-player-id="#{player_id}"))
      |> Enum.at(1)
      |> String.split("</tr>")
      |> Enum.at(0)

    ~r{<td[^>]*>(.*?)</td>}s
    |> Regex.scan(row)
    |> Enum.map(fn [_, inner] -> String.trim(inner) end)
  end

  describe "Elo used column" do
    test "shows FIDE rating when set, national rating otherwise", %{conn: conn, scope: scope} do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{"name" => "Elo Used Test", "type" => "swiss"})

      {:ok, fide_player} =
        Tournaments.create_player(tournament.id, %{
          "name" => "FidePlayer",
          "fide_rating" => "2200",
          "national_rating" => "1800"
        })

      {:ok, national_only} =
        Tournaments.create_player(tournament.id, %{
          "name" => "NationalOnly",
          "national_rating" => "1700"
        })

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")
      html = render_click(lv, "toggle_column", %{"key" => "elo_used"})

      fide_row = html |> String.split(~s(data-player-id="#{fide_player.id}")) |> Enum.at(1)
      national_row = html |> String.split(~s(data-player-id="#{national_only.id}")) |> Enum.at(1)

      # Visible numeric columns, in order: N1, Cl, Birth, Id FIDE, Elo Nat,
      # Elo FIDE, Elo used, Ga, Pts, XtPts, P.Tot. — index 4 is the raw
      # national rating, index 6 is the new Elo-used column.
      fide_cells = num_cells(fide_row)
      national_cells = num_cells(national_row)

      # FidePlayer has both ratings set — Elo Nat keeps showing the raw
      # national rating (1800), while Elo used picks the FIDE one (2200).
      assert Enum.at(fide_cells, 4) == "1800"
      assert Enum.at(fide_cells, 6) == "2200"

      # NationalOnly has no FIDE rating — Elo used falls back to the same
      # national rating shown in Elo Nat.
      assert Enum.at(national_cells, 4) == "1700"
      assert Enum.at(national_cells, 6) == "1700"
    end
  end

  describe "tiebreak column ordering follows the tournament's configured tiebreaks" do
    test "tiebreak headers render in the tournament's configured order", %{
      conn: conn,
      scope: scope
    } do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{
          "name" => "Tiebreak Order Test",
          "type" => "swiss",
          "tiebreaks" => ["SB", "BH"]
        })

      {:ok, _p} = Tournaments.create_player(tournament.id, %{"name" => "Solo"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      html =
        lv
        |> render_click("toggle_column", %{"key" => "buch"})
        |> then(fn _ -> render_click(lv, "toggle_column", %{"key" => "sb"}) end)

      # Configured order is SB, BH -> S.B. header must come before Buch.
      assert position(html, "S.B.") < position(html, "Buch")
    end

    test "tiebreaks left out of the tournament's configured list still render, after the configured ones",
         %{conn: conn, scope: scope} do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{
          "name" => "Partial Tiebreak Test",
          "type" => "swiss",
          "tiebreaks" => ["SB"]
        })

      {:ok, _p} = Tournaments.create_player(tournament.id, %{"name" => "Solo"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      html =
        lv
        |> render_click("toggle_column", %{"key" => "buch"})
        |> then(fn _ -> render_click(lv, "toggle_column", %{"key" => "sb"}) end)

      # SB is configured, so it comes first; BH is not configured, so it
      # falls back after — but it must still appear (columns aren't hidden,
      # only reordered, since the grid always computes all of these).
      assert html =~ "Buch"
      assert position(html, "S.B.") < position(html, "Buch")
    end
  end

  describe "setup-completion gate" do
    test "adding a player is blocked, with a banner, when the tournament is missing a start date",
         %{conn: conn, scope: scope} do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{"name" => "No Start Date", "type" => "swiss"})

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/players")

      assert html =~ "Finish the tournament setup"
      assert html =~ ~s(href="/t/#{tournament.id}/settings")

      button = lv |> element("button", "Add player")
      assert render(button) =~ "disabled"

      html = render_click(lv, "add", %{})
      assert html =~ "Finish the tournament setup"
      refute html =~ ~s(name="player[name]")

      html = render_click(lv, "save", %{"player" => %{"name" => "Sneaky"}})
      assert html =~ "Finish the tournament setup"
      assert Tournaments.list_players(tournament.id) == []
    end

    test "adding a player is allowed once the tournament setup is complete", %{
      conn: conn,
      scope: scope
    } do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{
          "name" => "Complete Setup",
          "type" => "swiss",
          "start_date" => "2026-07-15",
          "rounds_count" => "3",
          "round_dates" => ["2026-07-15", "2026-07-16", "2026-07-17"],
          "tiebreaks" => ["BH", "SB"],
          "chief_arbiter" => "Jane Arbiter",
          "federation" => "BEL",
          "rate_of_play" => "90 min + 30 sec/move"
        })

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/players")

      refute html =~ "Finish the tournament setup"

      button = lv |> element("button", "Add player")
      refute render(button) =~ "disabled"

      html = render_click(lv, "add", %{})
      assert html =~ ~s(name="player[name]")

      html = lv |> form("form", %{"player" => %{"name" => "New Player"}}) |> render_submit()

      assert html =~ "New Player"

      # create_player broadcasts :players on the tournament's topic, which
      # this `lv` is subscribed to — drain the self-broadcast before
      # teardown (same race as the other PlayersLive save tests above).
      render(lv)

      assert Enum.any?(Tournaments.list_players(tournament.id), &(&1.name == "New Player"))
    end
  end

  ## ---------- concurrent-arbiter live refresh ----------
  #
  # A visible "Player data was just updated by another arbiter" notice
  # used to fire on a remote broadcast — removed by explicit request, same
  # call as PairingsLive's identical notice: however it was positioned, a
  # toast popping up mid-click kept surprising people. The player data
  # itself still refreshes live underneath; that's the part that actually
  # matters, and it keeps working with no popup attached to it.

  test "a broadcast that changes a player's data refreshes it live, with no popup", %{
    conn: conn,
    scope: scope
  } do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{"name" => "Remote Notice Test", "type" => "swiss"})

    {:ok, player} = Tournaments.create_player(tournament.id, %{"name" => "Alice"})

    {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/players")
    refute html =~ "updated by another arbiter"

    # Simulate another arbiter/tab changing this player's rating directly in
    # the DB (bypassing this LiveView entirely) and broadcasting the change.
    Repo.update!(Ecto.Changeset.change(player, fide_rating: 2000))
    Tournaments.broadcast_tournament_change(tournament.id, :players)

    html = render(lv)
    refute html =~ "updated by another arbiter"
    assert html =~ "2000"
  end

  describe "bulk club refresh (Update clubs button)" do
    setup %{scope: scope} do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{"name" => "Club Test", "type" => "swiss"})

      %{tournament: tournament}
    end

    test "the button is on the Players page toolbar, beside Refresh ratings", %{
      conn: conn,
      tournament: tournament
    } do
      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/players")

      assert html =~ "Update clubs"
      assert html =~ "phx-click=\"open_club_refresh\""

      # Adjacent to Refresh ratings, in that order — the two are the same
      # gesture on different columns and are meant to be found together.
      [_, between] = String.split(html, "Refresh ratings", parts: 2)
      assert between =~ ~r/\A.{0,600}Update clubs/s
    end

    test "opens a preview and writes nothing until Apply", %{conn: conn, tournament: tournament} do
      {:ok, player} =
        Tournaments.create_player(tournament.id, %{
          "name" => "Clubless, Carl",
          "national_id" => "55555",
          "club" => "Old Club"
        })

      Repo.insert!(%KbsbPlayer{
        national_id: "55555",
        last_name: "Clubless",
        club_name: "New Club",
        club_number: 812
      })

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")
      html = lv |> element("button", "Update clubs") |> render_click()

      assert html =~ "Old Club"
      assert html =~ "New Club"

      # Still the old club: the preview is a preview.
      assert Tournaments.get_player!(tournament.id, player.id).club == "Old Club"

      lv |> element("button", "Apply") |> render_click()

      updated = Tournaments.get_player!(tournament.id, player.id)
      assert updated.club == "New Club"
      assert updated.club_number == 812
    end
  end
end
