defmodule PairingsEngineWeb.ClickPayloadTest do
  @moduledoc """
  `phx-click`/`phx-value-*` handlers the JS hooks audit found outside the
  hooks themselves - "Outside this area, noticed on the way" in
  docs/js-hooks-audit-2026-09-13.md, the same class of problem as finding
  F4: a `phx-value-*` payload is written by whoever holds the socket, just
  like a `pushEvent` payload, so a value no template of ours sends can
  still arrive.

  `players_live.ex` `toggle_column`/`pick`, `pairings_live.ex`
  `arm_swap`/`pick_swap_target`/`stage_vacate`/`stage_bye`/`stage_fill`,
  and `standings_live.ex` `publish_standings`/`unpublish_standings` each
  took their own LiveView down - mostly `String.to_integer/1` on a
  non-numeric id, `toggle_column` also on a missing key entirely. Every
  one must now be a no-op that leaves the page standing, and none of them
  may act on another tournament's data when the id parses fine but names
  a row that belongs elsewhere.
  """

  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Pairing, Tournaments}

  @moduletag :capture_log

  setup :register_and_log_in_user

  setup %{scope: scope} do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{
        "name" => "Click Payload Open",
        "type" => "swiss",
        "rounds_count" => "5",
        "pairing_engine" => "ainalrami"
      })

    players =
      for {name, rating} <- [{"Anna", 2200}, {"Bram", 2100}, {"Chris", 2000}, {"Dina", 1900}] do
        {:ok, p} =
          Tournaments.create_player(tournament.id, %{
            "name" => name,
            "fide_rating" => "#{rating}"
          })

        p
      end

    # A second, unrelated tournament - so an id that belongs to IT is a
    # foreign id when sent to a LiveView mounted on the first.
    {:ok, other_tournament} =
      Tournaments.create_tournament(scope, %{
        "name" => "Click Payload Other",
        "type" => "swiss",
        "rounds_count" => "5",
        "pairing_engine" => "ainalrami"
      })

    {:ok, other_player} =
      Tournaments.create_player(other_tournament.id, %{
        "name" => "Ida",
        "fide_rating" => "1700"
      })

    {:ok, _other_player_2} =
      Tournaments.create_player(other_tournament.id, %{
        "name" => "Jef",
        "fide_rating" => "1600"
      })

    %{
      tournament: tournament,
      players: players,
      other_tournament: other_tournament,
      other_player: other_player
    }
  end

  # The page survived the event: the LiveView process is still there and
  # still renders.
  defp survives(view, event, payload) do
    html = render_hook(view, event, payload)
    assert Process.alive?(view.pid), "#{event} #{inspect(payload)} crashed the LiveView"
    assert is_binary(html)
    html
  end

  describe "PlayersLive toggle_column" do
    test "a key no column has, and a missing key", %{conn: conn, tournament: t} do
      {:ok, view, _} = live(conn, ~p"/t/#{t.id}/players")

      for key <- ["bogus", "", 5, nil, %{"a" => 1}, ["name"], "name"] do
        survives(view, "toggle_column", %{"key" => key})
      end

      survives(view, "toggle_column", %{})

      before = render(view)
      # A real column still toggles ("club" starts visible - see
      # @default_visible - so this hides it).
      html = survives(view, "toggle_column", %{"key" => "club"})
      refute html == before
    end
  end

  describe "PlayersLive pick" do
    test "a fide-id that is not a number, and a missing key", %{conn: conn, tournament: t} do
      {:ok, view, _} = live(conn, ~p"/t/#{t.id}/players")

      for id <- ["abc", "1x", 1.5, nil, %{}, ["1"]] do
        survives(view, "pick", %{"fide-id" => id})
      end

      survives(view, "pick", %{})
    end
  end

  describe "PairingsLive arm_swap, pick_swap_target, stage_vacate, stage_bye, stage_fill" do
    setup %{tournament: t, other_tournament: ot} do
      {:ok, _round} = Pairing.pair_next_round(Tournaments.get_tournament!(t.id))
      {:ok, _other_round} = Pairing.pair_next_round(Tournaments.get_tournament!(ot.id))
      %{round: Tournaments.get_round(t.id, 1), other_round: Tournaments.get_round(ot.id, 1)}
    end

    test "arm_swap with an id that is not a number never arms the swap", %{
      conn: conn,
      tournament: t
    } do
      {:ok, view, _} = live(conn, ~p"/t/#{t.id}/pairings")

      for id <- ["abc", "1x", 1.5, nil, %{}, ["1"]] do
        survives(view, "arm_swap", %{"player-id" => id})
      end

      survives(view, "arm_swap", %{})
    end

    test "a bad arm_swap payload leaves nothing for pick_swap_target to complete", %{
      conn: conn,
      tournament: t,
      round: round
    } do
      {:ok, view, _} = live(conn, ~p"/t/#{t.id}/pairings")

      survives(view, "arm_swap", %{"player-id" => "not-a-number"})

      [pairing | _] = round.pairings
      second_id = pairing.black_player_id || pairing.white_player_id

      html = survives(view, "pick_swap_target", %{"player-id" => to_string(second_id)})
      refute html =~ ~s(id="hand-edit-title")
    end

    test "pick_swap_target with an id that is not a number", %{conn: conn, tournament: t} do
      {:ok, view, _} = live(conn, ~p"/t/#{t.id}/pairings")

      for id <- ["abc", "1x", 1.5, nil, %{}, ["1"]] do
        survives(view, "pick_swap_target", %{"player-id" => id})
      end

      survives(view, "pick_swap_target", %{})
    end

    # Security check: a player id that parses fine but belongs to another
    # tournament must never complete a swap or open the confirm modal for
    # one - `confirm_for/2` only looks inside this tournament's own round
    # and pool.
    test "pick_swap_target with a player id from another tournament stages nothing", %{
      conn: conn,
      tournament: t,
      round: round,
      other_player: other_player
    } do
      {:ok, view, _} = live(conn, ~p"/t/#{t.id}/pairings")

      [pairing | _] = round.pairings
      first_id = pairing.white_player_id

      survives(view, "arm_swap", %{"player-id" => to_string(first_id)})

      html =
        survives(view, "pick_swap_target", %{"player-id" => to_string(other_player.id)})

      refute html =~ ~s(id="hand-edit-title")
    end

    test "stage_vacate with an id that is not a number", %{conn: conn, tournament: t} do
      {:ok, view, _} = live(conn, ~p"/t/#{t.id}/pairings")

      for id <- ["abc", "1x", 1.5, nil, %{}, ["1"]] do
        html = survives(view, "stage_vacate", %{"player-id" => id})
        refute html =~ ~s(id="hand-edit-title")
      end

      survives(view, "stage_vacate", %{})
    end

    test "stage_vacate with a player id from another tournament stages nothing", %{
      conn: conn,
      tournament: t,
      other_player: other_player
    } do
      {:ok, view, _} = live(conn, ~p"/t/#{t.id}/pairings")

      html = survives(view, "stage_vacate", %{"player-id" => to_string(other_player.id)})
      refute html =~ ~s(id="hand-edit-title")
    end

    test "stage_bye with an id that is not a number", %{conn: conn, tournament: t} do
      {:ok, view, _} = live(conn, ~p"/t/#{t.id}/pairings")

      for id <- ["abc", "1x", 1.5, nil, %{}, ["1"]] do
        html = survives(view, "stage_bye", %{"pairing-id" => id})
        refute html =~ ~s(id="hand-edit-title")
      end

      survives(view, "stage_bye", %{})
    end

    test "stage_bye with a pairing id from another tournament stages nothing", %{
      conn: conn,
      tournament: t,
      other_round: other_round
    } do
      {:ok, view, _} = live(conn, ~p"/t/#{t.id}/pairings")

      [other_pairing | _] = other_round.pairings

      html =
        survives(view, "stage_bye", %{"pairing-id" => to_string(other_pairing.id)})

      refute html =~ ~s(id="hand-edit-title")
    end

    test "stage_fill with ids that are not numbers", %{conn: conn, tournament: t} do
      {:ok, view, _} = live(conn, ~p"/t/#{t.id}/pairings")

      for id <- ["abc", "1x", 1.5, nil, %{}, ["1"]] do
        html = survives(view, "stage_fill", %{"pairing-id" => id, "player-id" => "1"})
        refute html =~ ~s(id="hand-edit-title")

        html = survives(view, "stage_fill", %{"pairing-id" => "1", "player-id" => id})
        refute html =~ ~s(id="hand-edit-title")
      end

      survives(view, "stage_fill", %{})
      survives(view, "stage_fill", %{"pairing-id" => "1"})
    end

    # Security check: `Tournaments.fill_seat/3` refuses a player id from
    # another tournament (`player_belongs_to_tournament?/2`), so even a
    # pairing id from THIS tournament with a foreign player id must not
    # seat that player.
    test "stage_fill with a player id from another tournament does not seat them", %{
      conn: conn,
      tournament: t,
      round: round,
      other_player: other_player
    } do
      {:ok, view, _} = live(conn, ~p"/t/#{t.id}/pairings")

      vacant =
        Enum.find(round.pairings, &(is_nil(&1.white_player_id) or is_nil(&1.black_player_id)))

      pairing_id = if vacant, do: vacant.id, else: hd(round.pairings).id

      html =
        survives(view, "stage_fill", %{
          "pairing-id" => to_string(pairing_id),
          "player-id" => to_string(other_player.id)
        })

      # Confirming would call `Tournaments.fill_seat/3`, which refuses a
      # foreign player id - but staging alone must not show the confirm
      # modal with that id primed to apply either way isn't the concern
      # here; the concern is nothing about this tournament changed.
      refute html =~ other_player.name
    end
  end

  describe "StandingsLive publish_standings and unpublish_standings" do
    test "a round that is not a whole number", %{conn: conn, tournament: t} do
      {:ok, view, _} = live(conn, ~p"/t/#{t.id}/standings")

      for round <- ["abc", "1.5", -1, "-1", nil, %{}, ["1"]] do
        survives(view, "publish_standings", %{"round" => round})
        survives(view, "unpublish_standings", %{"round" => round})
      end

      survives(view, "publish_standings", %{})
      survives(view, "unpublish_standings", %{})

      # Nothing was ever published, in spite of all that.
      assert Tournaments.get_tournament!(t.id).standings_through == 0
    end
  end
end
