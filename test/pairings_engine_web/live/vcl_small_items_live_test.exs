defmodule PairingsEngineWeb.VclSmallItemsLiveTest do
  @moduledoc """
  The pages behind VCL4THP Q62 (setup warning), Q170 (withdrawal in the
  standings and their print), Q174/Q175 (half-point byes on the player
  dialog) and Q197 (expelled flag).
  """
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Repo, Tournaments}

  setup :register_and_log_in_user

  defp tournament(scope, attrs \\ %{}) do
    {:ok, t} =
      Tournaments.create_tournament(
        scope,
        Map.merge(%{"name" => "Small items", "type" => "swiss", "rounds_count" => 5}, attrs)
      )

    t
  end

  defp players(t, names) do
    for name <- names do
      {:ok, p} = Tournaments.create_player(t.id, %{"name" => name})
      p
    end
  end

  test "the pairings page warns before round 1 when the rounds cannot be paired", %{
    conn: conn,
    scope: scope
  } do
    t = tournament(scope)
    players(t, ~w(Ann Bob Cy))

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
    assert has_element?(lv, "#setup-warning-swiss_rounds")
    assert has_element?(lv, "#setup-warning-link")

    players(t, ~w(Di Ed Flo))
    players(t, ~w(Gus Hal))

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
    refute has_element?(lv, "#setup-warning-swiss_rounds")
  end

  describe "a withdrawn player in the standings (Q170)" do
    test "is marked on the page and in the print", %{conn: conn, scope: scope} do
      t = tournament(scope)
      [ann, bob] = players(t, ~w(Ann Bob))
      {:ok, _} = Tournaments.update_player(bob, %{"forfeit" => "true"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/standings")
      assert has_element?(lv, "#player-withdrawn-#{bob.id}")
      refute has_element?(lv, "#player-withdrawn-#{ann.id}")

      html = conn |> get(~p"/t/#{t.id}/print/standings") |> html_response(200)
      assert html =~ "(withdrawn)"
    end
  end

  describe "the player dialog" do
    setup %{scope: scope} do
      t = tournament(scope)
      Repo.update!(Ecto.Changeset.change(t, abs_value: 0.5))
      [ann] = players(t, ["Ann"])
      %{t: t, ann: ann}
    end

    test "a second half-point bye asks for a confirmation that Save carries", %{
      conn: conn,
      t: t,
      ann: ann
    } do
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/players")
      render_click(lv, "edit_player", %{"id" => to_string(ann.id)})
      refute has_element?(lv, "#player-half-bye-warning")

      lv
      |> element("#player-edit-form")
      |> render_change(%{"player" => %{"absent_rounds" => "2"}})

      refute has_element?(lv, "#player-half-bye-warning")

      lv
      |> element("#player-edit-form")
      |> render_change(%{"player" => %{"absent_rounds" => "2,4"}})

      assert has_element?(lv, "#player-half-bye-warning")
      assert has_element?(lv, "#player-edit-save[data-confirm]")

      # The warning carries the confirmation flag in the form, which the
      # Save button's themed dialog stands behind; without it the server
      # refuses.
      lv
      |> element("#player-edit-form")
      |> render_submit(%{"player" => %{"absent_rounds" => "2,4", "half_ack" => "false"}})

      assert Repo.reload!(ann).absent_rounds == ""
      assert has_element?(lv, "#player-half-bye-warning")

      lv
      |> element("#player-edit-form")
      |> render_submit(%{"player" => %{"absent_rounds" => "2,4", "half_ack" => "true"}})

      assert Repo.reload!(ann).absent_rounds == "2,4"
    end

    test "a player marked not eligible gets no half-point bye", %{conn: conn, t: t, ann: ann} do
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/players")
      render_click(lv, "edit_player", %{"id" => to_string(ann.id)})
      assert has_element?(lv, "#player-no-half-bye")

      lv
      |> element("#player-edit-form")
      |> render_submit(%{"player" => %{"no_half_bye" => "true", "absent_rounds" => "3"}})

      assert Repo.reload!(ann).absent_rounds == ""
      refute Repo.reload!(ann).no_half_bye

      lv
      |> element("#player-edit-form")
      |> render_submit(%{"player" => %{"no_half_bye" => "true", "absent_rounds" => ""}})

      assert Repo.reload!(ann).no_half_bye
    end

    test "an expelled player is flagged and keeps the flag through other edits", %{
      conn: conn,
      t: t,
      ann: ann
    } do
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/players")
      render_click(lv, "edit_player", %{"id" => to_string(ann.id)})
      assert has_element?(lv, "#player-expelled")

      lv
      |> element("#player-edit-form")
      |> render_submit(%{"player" => %{"status" => "expelled"}})

      assert Repo.reload!(ann).status == "expelled"

      render_click(lv, "edit_player", %{"id" => to_string(ann.id)})
      assert has_element?(lv, "#player-expelled[checked]")
    end
  end
end
