defmodule PairingsEngineWeb.ExternalTiebreakLiveTest do
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Pairing, Player, Round}

  setup :register_and_log_in_user

  defp fixture(scope) do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "External page",
        "type" => "swiss",
        "rounds_count" => "1"
      })

    {:ok, t} = Tournaments.update_tournament(t, %{tiebreaks: ["EXT"]})

    [a, b] =
      for {name, rating} <- [{"A", 2000}, {"B", 1900}],
          do: Repo.insert!(%Player{tournament_id: t.id, name: name, fide_rating: rating})

    r1 = Repo.insert!(%Round{tournament_id: t.id, number: 1, status: "finished"})

    Repo.insert!(%Pairing{
      round_id: r1.id,
      board: 1,
      white_player_id: a.id,
      black_player_id: b.id,
      result: "1/2-1/2"
    })

    :ok = Tournaments.freeze_round_display_boards!(r1.id)
    {t, a, b}
  end

  test "the arbiter types a value per player and the ranking follows it", %{
    conn: conn,
    scope: scope
  } do
    {t, a, b} = fixture(scope)
    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/standings")

    assert has_element?(lv, "#external-tiebreak-#{a.id}")

    lv
    |> form("#external-tiebreak-form-#{b.id}", %{"value" => "7,5"})
    |> render_change()

    assert Repo.get!(Player, b.id).external_tiebreak == 7.5

    # B now outranks A: its row comes first in the table.
    html = render(lv)

    assert :binary.match(html, "external-tiebreak-#{b.id}") <
             :binary.match(html, "external-tiebreak-#{a.id}")

    lv |> form("#external-tiebreak-form-#{b.id}", %{"value" => ""}) |> render_change()
    assert Repo.get!(Player, b.id).external_tiebreak == nil
  end

  test "text that is not a number is refused", %{conn: conn, scope: scope} do
    {t, _a, b} = fixture(scope)
    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/standings")

    lv |> form("#external-tiebreak-form-#{b.id}", %{"value" => "abc"}) |> render_change()
    assert Repo.get!(Player, b.id).external_tiebreak == nil
  end
end
