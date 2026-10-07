defmodule PairingsEngineWeb.FullPointByeLiveTest do
  @moduledoc """
  The Pairings page's full-point bye (VCL4THP Q177, Q178): offered on a
  player sitting the round out, with a Level-2 notice in the confirmation
  that the regulations do not describe it, and taken back the same way.
  The rules themselves are `PairingsEngine.FullPointByeTest`.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query, only: [from: 2]

  alias PairingsEngine.{Audit, Pairing, Repo, Tournaments}

  setup :register_and_log_in_user

  defp tournament(scope) do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "Full-point bye",
        "type" => "swiss",
        "start_date" => "2026-07-15",
        "rounds_count" => "3",
        "round_dates" => List.duplicate("2026-07-15", 3),
        "tiebreaks" => ["BH", "SB"],
        "chief_arbiter" => "Jane Arbiter",
        "federation" => "BEL",
        "rate_of_play" => "90 min + 30 sec/move"
      })

    players =
      for {name, i} <- Enum.with_index(~w(Ann Ben Cas Dan Eva)) do
        {:ok, p} =
          Tournaments.create_player(t.id, %{
            tournament_id: t.id,
            name: name,
            fide_rating: 2000 - 50 * i,
            # Eva is not playing round 1, so she sits in its pool.
            absent_rounds: if(name == "Eva", do: "1", else: "")
          })

        p
      end

    {:ok, _round} = Pairing.pair_next_round(Repo.reload!(t))
    {Repo.reload!(t), List.last(players)}
  end

  defp bye_type(t, player) do
    Repo.one(
      from b in "byes",
        where: b.tournament_id == ^t.id and b.player_id == ^player.id and b.round == 1,
        select: b.type
    )
  end

  defp open_pool_menu(lv, player) do
    render_click(lv, "open_menu", %{
      "scope" => "pool",
      "player-id" => to_string(player.id),
      "x" => "10",
      "y" => "10"
    })
  end

  test "given from the not-playing list, after a Level-2 notice; taken back the same way",
       %{conn: conn, scope: scope} do
    {t, eva} = tournament(scope)
    assert bye_type(t, eva) == "absent"

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

    open_pool_menu(lv, eva)
    refute has_element?(lv, "#menu-withdraw-fpb")
    lv |> element("#menu-give-fpb") |> render_click()

    assert has_element?(lv, "#hand-edit-dialog #confirm-level2")
    # Level 2 is said, not ticked: nothing to tick before applying.
    refute has_element?(lv, "#hand-edit-dialog #confirm-rule-ack")

    render_click(lv, "apply_confirm", %{})
    assert bye_type(t, eva) == "full-point"
    assert has_element?(lv, "#round-pool-1", "full-point bye")
    assert "pairing.full_point_bye_awarded" in actions(t)
    # Not a board change: no manual pairing alteration is opened for it.
    refute Tournaments.get_round(t.id, 1).mpa_session

    open_pool_menu(lv, eva)
    refute has_element?(lv, "#menu-give-fpb")
    lv |> element("#menu-withdraw-fpb") |> render_click()
    render_click(lv, "apply_confirm", %{})

    assert bye_type(t, eva) == "absent"
    assert "pairing.full_point_bye_withdrawn" in actions(t)
  end

  defp actions(t), do: t.id |> Audit.list_for_tournament() |> Enum.map(& &1.action)
end
