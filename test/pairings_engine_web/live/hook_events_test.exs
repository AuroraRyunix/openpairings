defmodule PairingsEngineWeb.HookEventsTest do
  @moduledoc """
  The events the page scripts push (`assets/js/app.js` and the colocated
  hooks), sent the way anybody holding the socket can send them: with a
  value no script of ours would produce, or with a key missing.

  A `pushEvent` payload is written by whoever holds the socket, exactly like
  a `phx-value-*`. Each of these used to take its LiveView down with it -
  a `FunctionClauseError`, a `MatchError`, an `ArgumentError` or a
  `CaseClauseError` in the render - and a crashed LiveView drops whatever the
  arbiter had open on that page. Every one must now be a no-op that leaves
  the page standing. See docs/js-hooks-audit-2026-09-13.md, finding F4.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Pairing, Repo, Tournaments}

  @moduletag :capture_log

  setup :register_and_log_in_user

  setup %{scope: scope} do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{
        "name" => "Hook Events Open",
        "type" => "swiss",
        "rounds_count" => "5",
        "pairing_engine" => "ainalrami",
        "categories_enabled" => true
      })

    {:ok, tournament} = Tournaments.update_tournament(tournament, %{"categories" => ["U16"]})

    players =
      for {name, rating} <- [{"Anna", 2200}, {"Bram", 2100}, {"Chris", 2000}, {"Dina", 1900}] do
        {:ok, p} =
          Tournaments.create_player(tournament.id, %{"name" => name, "fide_rating" => "#{rating}"})

        p
      end

    %{tournament: tournament, players: players}
  end

  # The page survived the event: the LiveView process is still there and still
  # renders.
  defp survives(view, event, payload) do
    html = render_hook(view, event, payload)
    assert Process.alive?(view.pid), "#{event} #{inspect(payload)} crashed the LiveView"
    assert is_binary(html)
    html
  end

  describe "the Players grid (PlayerGrid, ColumnPrefs)" do
    test "a sort key no column has", %{conn: conn, tournament: t} do
      {:ok, view, _} = live(conn, ~p"/t/#{t.id}/players")

      for key <- ["bogus", "", 5, nil, %{"a" => 1}, ["name"]] do
        survives(view, "sort", %{"key" => key})
      end

      survives(view, "sort", %{})

      # And a real one still sorts.
      html = survives(view, "sort", %{"key" => "name"})
      assert html =~ ~s(aria-sort="ascending")
    end

    test "a category name that is not a string", %{conn: conn, tournament: t, players: [p | _]} do
      {:ok, view, _} = live(conn, ~p"/t/#{t.id}/players")

      for name <- [5, nil, %{}, ["U16"]] do
        survives(view, "toggle_category", %{
          "id" => to_string(p.id),
          "name" => name,
          "value" => "true"
        })

        survives(view, "set_all_category", %{"name" => name, "value" => "true"})
        survives(view, "filter_category", %{"name" => name})
      end

      assert Repo.reload!(p).categories in [nil, []]

      # A real one still writes.
      survives(view, "toggle_category", %{
        "id" => to_string(p.id),
        "name" => "U16",
        "value" => "true"
      })

      assert Repo.reload!(p).categories == ["U16"]
    end

    test "the Players Card for an id that is not a number", %{
      conn: conn,
      tournament: t,
      players: [p | _]
    } do
      {:ok, view, _} = live(conn, ~p"/t/#{t.id}/players")

      for id <- ["abc", "12abc", 1.5, nil, %{}] do
        html = survives(view, "show_card", %{"id" => id})
        refute html =~ "player-card-dialog"
      end

      html = survives(view, "show_card", %{"id" => to_string(p.id)})
      assert html =~ "player-card-dialog"
    end

    test "every menu event with its keys missing", %{conn: conn, tournament: t} do
      {:ok, view, _} = live(conn, ~p"/t/#{t.id}/players")

      for event <-
            ~w(edit_player show_card set_absent_flag set_all_absent_flag set_paid set_all_paid
               toggle_category set_all_category filter_category sort) do
        survives(view, event, %{})
      end
    end
  end

  describe "the hand-edit menu (.PairingMenu)" do
    setup %{tournament: t} do
      {:ok, _round} = Pairing.pair_next_round(Tournaments.get_tournament!(t.id))
      :ok
    end

    test "without a position", %{conn: conn, tournament: t, players: [p | _]} do
      {:ok, view, _} = live(conn, ~p"/t/#{t.id}/pairings")

      survives(view, "open_menu", %{})
      survives(view, "open_menu", %{"scope" => "seated", "player-id" => to_string(p.id)})
    end

    # The keyboard places the menu at the seat's getBoundingClientRect(), which
    # is fractional under display scaling. A float used to put the menu at the
    # window's top-left corner. F5 in the report.
    test "at a fractional position, from the keyboard", %{
      conn: conn,
      tournament: t,
      players: [p | _]
    } do
      {:ok, view, _} = live(conn, ~p"/t/#{t.id}/pairings")

      html =
        survives(view, "open_menu", %{
          "x" => 120.5,
          "y" => 340.25,
          "scope" => "seated",
          "player-id" => to_string(p.id),
          "keyboard" => true
        })

      assert html =~ "left: 121px; top: 340px"
    end

    test "with ids that are not numbers", %{conn: conn, tournament: t} do
      {:ok, view, _} = live(conn, ~p"/t/#{t.id}/pairings")

      for id <- ["abc", "1x", 1.5, %{}, ["1"]] do
        html =
          survives(view, "open_menu", %{
            "x" => 1,
            "y" => 1,
            "scope" => "seated",
            "player-id" => id
          })

        refute html =~ "hand-edit-menu"

        html =
          survives(view, "open_menu", %{
            "x" => 1,
            "y" => 1,
            "scope" => "vacant",
            "pairing-id" => id
          })

        refute html =~ "hand-edit-menu"
      end
    end

    test "with a scope no seat has", %{conn: conn, tournament: t, players: [p | _]} do
      {:ok, view, _} = live(conn, ~p"/t/#{t.id}/pairings")

      for scope <- ["bogus", "", 5, %{}] do
        html =
          survives(view, "open_menu", %{
            "x" => 1,
            "y" => 1,
            "scope" => scope,
            "player-id" => to_string(p.id)
          })

        refute html =~ "hand-edit-menu"
      end

      # No scope at all is still a seat, as it always was.
      html = survives(view, "open_menu", %{"x" => 1, "y" => 1, "player-id" => to_string(p.id)})
      assert html =~ "hand-edit-menu"
    end
  end

  describe "the round menus (.RoundMenu)" do
    # The round's Print and More menus are native <details>: the <summary> is
    # the button (focusable, Enter/Space toggle it, the browser reports it
    # expanded or not), they start closed, and `open` survives a re-render.
    test "Print and More start closed, with their items inside", %{conn: conn, tournament: t} do
      {:ok, _round} = Pairing.pair_next_round(Tournaments.get_tournament!(t.id))
      {:ok, view, _} = live(conn, ~p"/t/#{t.id}/pairings")

      document = view |> render() |> LazyHTML.from_fragment()
      menus = LazyHTML.query(document, "details[phx-hook$='.RoundMenu']")

      assert Enum.count(menus) == 2
      assert menus |> LazyHTML.attribute("open") |> Enum.reject(&is_nil/1) == []

      assert Enum.count(LazyHTML.query(document, "details[phx-hook$='.RoundMenu'] > summary")) ==
               2

      assert Enum.count(
               LazyHTML.query(document, "details[phx-hook$='.RoundMenu'] [role='menuitem']")
             ) >
               5
    end
  end
end
