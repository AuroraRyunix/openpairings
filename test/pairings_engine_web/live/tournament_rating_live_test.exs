defmodule PairingsEngineWeb.TournamentRatingLiveTest do
  @moduledoc """
  The Tournament Rating method and the initial order's last criterion on
  Settings -> Options, and the hand-typed tournament rating on the Players
  page (VCL4THP Q145/Q146).
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Tournaments.Player

  setup :register_and_log_in_user

  defp create_tournament(scope, attrs \\ %{}) do
    {:ok, tournament} =
      Tournaments.create_tournament(
        scope,
        Map.merge(
          %{"name" => "Rating Method LV", "type" => "swiss", "rounds_count" => "5"},
          attrs
        )
      )

    tournament
  end

  test "Options offers the six methods, FIDON selected, and saves another", %{
    conn: conn,
    scope: scope
  } do
    t = create_tournament(scope)
    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/options")

    assert has_element?(lv, "#rating-method-select option[value='FIDON'][selected]")

    for method <- ~w(FIDE NRO NIDOF HBFN OTHER) do
      assert has_element?(lv, "#rating-method-select option[value='#{method}']")
    end

    assert has_element?(lv, "#initial-order-tiebreak-select option[value='name'][selected]")
    assert has_element?(lv, "#late-entry-numbering-select option[value='rating'][selected]")

    lv
    |> form("#pairing-settings-form", %{
      "tournament" => %{
        "rating_method" => "NIDOF",
        "initial_order_tiebreak" => "fide_id",
        "late_entry_numbering" => "rating"
      }
    })
    |> render_submit()

    t = Tournaments.get_tournament!(t.id)
    assert t.rating_method == "NIDOF"
    assert t.initial_order_tiebreak == "fide_id"
    assert t.late_entry_numbering == "rating"
  end

  test "the Players page offers a tournament rating only under HBFN and OTHER", %{
    conn: conn,
    scope: scope
  } do
    t = create_tournament(scope)
    {:ok, player} = Tournaments.create_player(t.id, %{"name" => "Alice"})

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/players")
    render_click(lv, "edit_player", %{"id" => to_string(player.id)})
    refute has_element?(lv, "#edit-player-tournament-rating")

    {:ok, _} = Tournaments.update_tournament(t, %{"rating_method" => "OTHER"})

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/players")
    render_click(lv, "edit_player", %{"id" => to_string(player.id)})
    assert has_element?(lv, "#edit-player-tournament-rating")

    lv
    |> form("form", player: %{"name" => "Alice", "tournament_rating" => "1750"})
    |> render_submit()

    assert Repo.get!(Player, player.id).tournament_rating == 1750
  end
end
