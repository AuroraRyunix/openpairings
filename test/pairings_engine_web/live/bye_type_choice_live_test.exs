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

    test "says so when the pick pays more than the limits on paid absences", %{
      conn: conn,
      t: t,
      ann: ann
    } do
      # Paid only through round 1: an absence in round 2 scores nothing.
      t |> Ecto.Changeset.change(abs_jusque: 1) |> Repo.update!()

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/players")
      render_click(lv, "edit_player", %{"id" => to_string(ann.id)})

      lv
      |> element("#player-edit-form")
      |> render_change(%{"player" => %{"absent_rounds" => "2"}})

      assert has_element?(lv, "#player-bye-type-2-requested-zero[checked]")
      refute has_element?(lv, "#player-bye-above-limits")

      lv
      |> element("#player-edit-form")
      |> render_change(%{
        "player" => %{"absent_rounds" => "2", "bye_types" => %{"2" => "requested-half"}}
      })

      assert has_element?(lv, "#player-bye-above-limits")

      # Said, not refused.
      lv
      |> element("#player-edit-form")
      |> render_submit(%{
        "player" => %{"absent_rounds" => "2", "bye_types" => %{"2" => "requested-half"}}
      })

      assert byes(t) == [{ann.id, 2, "requested-half"}]
    end
  end

  describe "the count cap in the player dialog" do
    test "the third absence of two paid is pre-picked as zero; half anyway is said", %{
      conn: conn,
      scope: scope
    } do
      t =
        tournament(scope, %{"abs_value" => "0.5", "abs_nbfois" => "2", "ask_bye_type" => "true"})

      ann = player(t, "Ann")

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/players")
      render_click(lv, "edit_player", %{"id" => to_string(ann.id)})

      lv
      |> element("#player-edit-form")
      |> render_change(%{"player" => %{"absent_rounds" => "1,2,3"}})

      assert has_element?(lv, "#player-bye-type-1-requested-half[checked]")
      assert has_element?(lv, "#player-bye-type-2-requested-half[checked]")
      assert has_element?(lv, "#player-bye-type-3-requested-zero[checked]")
      refute has_element?(lv, "#player-bye-above-limits")

      lv
      |> element("#player-edit-form")
      |> render_change(%{
        "player" => %{
          "absent_rounds" => "1,2,3",
          "bye_types" => %{
            "1" => "requested-half",
            "2" => "requested-half",
            "3" => "requested-half"
          }
        }
      })

      assert has_element?(lv, "#player-bye-above-limits")
    end
  end

  describe "Mark absent on the Pairings page" do
    setup %{scope: scope} do
      t = tournament(scope, %{"abs_value" => "0.5", "ask_bye_type" => "true"})

      t =
        Ecto.Changeset.change(t, round_dates: for(n <- 1..5, do: "2026-03-0#{n}"))
        |> Repo.update!()

      players = for name <- ~w(Ann Bob Cy Di), do: player(t, name)
      assert {:ok, _} = PairingsEngine.Pairing.pair_next_round(Repo.reload!(t))
      %{t: Repo.reload!(t), players: players}
    end

    defp seated(t) do
      t.id
      |> Tournaments.get_round(1)
      |> Map.fetch!(:pairings)
      |> Enum.flat_map(&[&1.white_player_id, &1.black_player_id])
      |> Enum.reject(&is_nil/1)
    end

    test "asks the bye type, pre-picked, and stores the pick", %{conn: conn, t: t} do
      [id | _] = seated(t)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      render_click(lv, "stage_vacate", %{"player-id" => to_string(id)})

      assert has_element?(lv, "#confirm-bye-type-requested-half[checked]")
      refute has_element?(lv, "#confirm-level2")

      lv |> element("#confirm-bye-type-form") |> render_change(%{"bye_type" => "full-point"})
      assert has_element?(lv, "#confirm-bye-type-full-point[checked]")
      assert has_element?(lv, "#confirm-level2")

      lv |> element("#confirm-bye-type-form") |> render_change(%{"bye_type" => "requested-zero"})
      render_click(lv, "apply_confirm", %{})

      assert byes(t) == [{id, 1, "requested-zero"}]
      refute id in seated(t)
    end

    test "asks nothing with the setting off: a plain absence, as before", %{conn: conn, t: t} do
      t |> Ecto.Changeset.change(ask_bye_type: false) |> Repo.update!()
      [id | _] = seated(t)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      render_click(lv, "stage_vacate", %{"player-id" => to_string(id)})

      refute has_element?(lv, "#confirm-bye-type-form")
      render_click(lv, "apply_confirm", %{})
      assert byes(t) == [{id, 1, "absent"}]
    end

    test "refuses a half-point bye to a player not eligible for one (Q175/Q176)", %{
      conn: conn,
      t: t
    } do
      [id | _] = seated(t)

      Repo.get!(PairingsEngine.Tournaments.Player, id)
      |> Ecto.Changeset.change(no_half_bye: true)
      |> Repo.update!()

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      render_click(lv, "stage_vacate", %{"player-id" => to_string(id)})

      # Offered the zero instead.
      assert has_element?(lv, "#confirm-bye-type-requested-zero[checked]")

      lv |> element("#confirm-bye-type-form") |> render_change(%{"bye_type" => "requested-half"})
      assert has_element?(lv, "#confirm-half-bye-refused")
      assert has_element?(lv, ".pe-modal-go[disabled]")

      render_click(lv, "apply_confirm", %{})
      assert byes(t) == []

      round = Tournaments.get_round(t.id, 1)

      assert {:error, :half_bye_not_eligible} =
               Tournaments.vacate_seat(round, id, "requested-half")
    end

    test "a second half-point bye needs its own tick (Q174)", %{conn: conn, t: t} do
      [id | _] = seated(t)
      # A half-point bye already granted for a coming round.
      {:ok, _} =
        Tournaments.update_player(
          Repo.get!(PairingsEngine.Tournaments.Player, id),
          %{"absent_rounds" => "3", "bye_types" => %{"3" => "requested-half"}}
        )

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      render_click(lv, "stage_vacate", %{"player-id" => to_string(id)})

      assert has_element?(lv, "#confirm-second-half-bye")
      assert has_element?(lv, ".pe-modal-go[disabled]")
      render_click(lv, "apply_confirm", %{})
      refute Enum.any?(byes(t), &match?({^id, 1, _}, &1))

      render_click(lv, "toggle_half_ack", %{})
      refute has_element?(lv, ".pe-modal-go[disabled]")
      render_click(lv, "apply_confirm", %{})
      assert {id, 1, "requested-half"} in byes(t)

      round = Tournaments.get_round(t.id, 1)
      other = Enum.at(seated(t), 0)

      {:ok, _} =
        Tournaments.update_player(
          Repo.get!(PairingsEngine.Tournaments.Player, other),
          %{"absent_rounds" => "3", "bye_types" => %{"3" => "requested-half"}}
        )

      assert {:error, {:needs_acknowledgement, [:second_half_bye]}} =
               Tournaments.vacate_seat(round, other, "requested-half")
    end
  end
end
