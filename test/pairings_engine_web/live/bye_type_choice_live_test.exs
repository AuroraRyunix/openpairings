defmodule PairingsEngineWeb.ByeTypeChoiceLiveTest do
  @moduledoc """
  "Ask the bye type for each absence" on its two pages: the switch on
  Settings - Scoring, and the player dialog's question it switches on.
  """
  use PairingsEngineWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias PairingsEngine.{Repo, Tournaments}

  setup :register_and_log_in_user

  defp tournament(scope, attrs \\ %{}) do
    {:ok, t} =
      Tournaments.create_tournament(
        scope,
        Map.merge(%{"name" => "Bye types", "type" => "swiss", "rounds_count" => 5}, attrs)
      )

    t
  end

  defp player(t, name) do
    {:ok, p} = Tournaments.create_player(t.id, %{"name" => name})
    p
  end

  defp byes(t) do
    Repo.all(
      from b in "byes",
        where: b.tournament_id == ^t.id,
        select: {b.player_id, b.round, b.type}
    )
  end

  describe "the setting" do
    test "is off by default, next to the absence scoring, and saves", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope)
      refute t.ask_bye_type

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/scoring")
      assert has_element?(lv, "#ask-bye-type-toggle")
      refute has_element?(lv, "#ask-bye-type-toggle[checked]")

      lv
      |> form("#scoring-settings-form", %{"tournament" => %{"ask_bye_type" => "true"}})
      |> render_submit()

      assert Tournaments.get_authorized_tournament!(scope, t.id).ask_bye_type
      assert has_element?(lv, "#ask-bye-type-toggle[checked]")
    end

    test "is not offered in a round robin", %{conn: conn, scope: scope} do
      t = tournament(scope, %{"pairing_system" => "round_robin"})
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/scoring")
      refute has_element?(lv, "#ask-bye-type-toggle")
    end
  end

  describe "the player dialog" do
    setup %{scope: scope} do
      t = tournament(scope, %{"abs_value" => "0.5", "ask_bye_type" => "true"})
      %{t: t, ann: player(t, "Ann")}
    end

    test "asks per round, with the absence value's answer picked; Save stores it", %{
      conn: conn,
      t: t,
      ann: ann
    } do
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/players")
      render_click(lv, "edit_player", %{"id" => to_string(ann.id)})
      refute has_element?(lv, "#player-bye-types")

      lv
      |> element("#player-edit-form")
      |> render_change(%{"player" => %{"absent_rounds" => "2"}})

      assert has_element?(lv, "#player-bye-type-2")
      assert has_element?(lv, "#player-bye-type-2-requested-half[checked]")
      refute has_element?(lv, "#player-fpb-notice")

      # The one click: Save, with what was picked for it.
      lv
      |> element("#player-edit-form")
      |> render_submit(%{"player" => %{"absent_rounds" => "2"}})

      assert byes(t) == [{ann.id, 2, "requested-half"}]
      assert Repo.reload!(ann).absent_rounds == "2"
    end

    test "another pick is stored as picked, a full-point one with its notice", %{
      conn: conn,
      t: t,
      ann: ann
    } do
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/players")
      render_click(lv, "edit_player", %{"id" => to_string(ann.id)})

      lv
      |> element("#player-edit-form")
      |> render_change(%{
        "player" => %{"absent_rounds" => "2", "bye_types" => %{"2" => "full-point"}}
      })

      assert has_element?(lv, "#player-bye-type-2-full-point[checked]")
      assert has_element?(lv, "#player-fpb-notice")

      lv
      |> element("#player-edit-form")
      |> render_submit(%{
        "player" => %{"absent_rounds" => "2", "bye_types" => %{"2" => "requested-zero"}}
      })

      assert byes(t) == [{ann.id, 2, "requested-zero"}]

      # Opened again, the stored answer is the one picked.
      render_click(lv, "edit_player", %{"id" => to_string(ann.id)})
      assert has_element?(lv, "#player-bye-type-2-requested-zero[checked]")
    end

    test "asks nothing with the setting off", %{conn: conn, t: t, ann: ann} do
      t |> Ecto.Changeset.change(ask_bye_type: false) |> Repo.update!()

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/players")
      render_click(lv, "edit_player", %{"id" => to_string(ann.id)})

      lv
      |> element("#player-edit-form")
      |> render_change(%{"player" => %{"absent_rounds" => "2"}})

      refute has_element?(lv, "#player-bye-types")
    end
  end
end
