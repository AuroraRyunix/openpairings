defmodule PairingsEngineWeb.FideModeLiveTest do
  @moduledoc """
  What the arbiter sees of FIDE mode's locks and of the way out:

    * the two-step "Leave FIDE mode" on Settings -> FIDE (TEC's Level 4 -
      VCL4THP Q43 for this path): a first warning, then the consequences,
      and only a confirm from the second step leaves;
    * every page of a tournament out of FIDE mode says so (Q46);
    * a setting FIDE mode holds is shown disabled, with the way out and no
      Unlock;
    * standings with a game still without a result say they are not final
      (Q161).
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Audit, Compliance, Pairing, Repo, Tournaments}

  setup :register_and_log_in_user

  defp create_tournament(scope, attrs \\ %{}) do
    {:ok, tournament} =
      Tournaments.create_tournament(
        scope,
        Map.merge(
          %{"name" => "FIDE mode page", "type" => "swiss", "rounds_count" => "5"},
          attrs
        )
      )

    for {name, i} <- Enum.with_index(~w(Ann Ben Cas Dan)) do
      {:ok, _} =
        Tournaments.create_player(tournament.id, %{
          tournament_id: tournament.id,
          name: name,
          fide_rating: 2000 - 100 * i
        })
    end

    Repo.update!(Ecto.Changeset.change(tournament, tiebreaks: ~w(BH SB)))
  end

  defp pair!(tournament) do
    {:ok, round} = Pairing.pair_next_round(Repo.reload!(tournament), [])
    Tournaments.get_round(tournament.id, round.number)
  end

  describe "leaving FIDE mode on Settings -> FIDE" do
    test "takes two steps, the second spelling out the cost", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      pair!(tournament)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/fide")
      assert has_element?(lv, "#leave-fide-start")

      lv |> element("#leave-fide-start") |> render_click()
      assert has_element?(lv, "#leave-fide-warn")
      refute has_element?(lv, "#leave-fide-confirm")

      lv |> element("#leave-fide-continue") |> render_click()
      assert has_element?(lv, "#leave-fide-consequences")
      assert render(lv) =~ "can never return to FIDE mode"
      assert Compliance.fide_mode?(Repo.reload!(tournament))

      lv |> element("#leave-fide-confirm") |> render_click()

      left = Repo.reload!(tournament)
      refute Compliance.fide_mode?(left)
      assert left.fide_compliance_lost_round == 1
      refute has_element?(lv, "#leave-fide-start")

      [entry] =
        Audit.list_for_tournament(tournament.id, action: "tournament.fide_compliance_lost")

      assert entry.details["code"] == "left_by_arbiter"
      assert entry.details["round"] == 1
    end

    test "staying, or a confirm that skipped the first warning, leaves nothing", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings/fide")

      render_click(lv, "leave_fide_confirm", %{})
      assert Compliance.fide_mode?(Repo.reload!(tournament))

      lv |> element("#leave-fide-start") |> render_click()
      lv |> element("#leave-fide-continue") |> render_click()
      lv |> element("#leave-fide-stay") |> render_click()

      assert Compliance.fide_mode?(Repo.reload!(tournament))
      assert has_element?(lv, "#leave-fide-start")
    end
  end

  describe "a tournament out of FIDE mode says so on every page (Q46)" do
    test "and one in FIDE mode does not", %{conn: conn, scope: scope} do
      in_mode = create_tournament(scope)
      out = create_tournament(scope, %{"pairing_system" => "keizer"})

      for path <- ["players", "pairings", "standings"] do
        {:ok, lv, _} = live(conn, "/t/#{out.id}/#{path}")
        assert has_element?(lv, "#not-fide-mode"), "no indication on #{path}"

        {:ok, lv, _} = live(conn, "/t/#{in_mode.id}/#{path}")
        refute has_element?(lv, "#not-fide-mode")
      end
    end
  end

  describe "settings FIDE mode holds" do
    test "are disabled, with the way out and no Unlock", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      pair!(tournament)

      {:ok, lv, _} = live(conn, ~p"/t/#{tournament.id}/settings")
      assert has_element?(lv, "input[name='tournament[rounds_count]'][disabled]")
      assert has_element?(lv, "#rounds-fide-lock")
      assert has_element?(lv, "#tiebreak-editor[disabled]")

      {:ok, lv, _} = live(conn, ~p"/t/#{tournament.id}/settings/scoring")
      assert has_element?(lv, "input[name='tournament[points_win]'][disabled]")
      assert has_element?(lv, "input[name='tournament[bye_value]'][disabled]")
      assert has_element?(lv, "#points-fide-lock")

      {:ok, lv, _} = live(conn, ~p"/t/#{tournament.id}/settings/options")
      assert has_element?(lv, "select[name='tournament[acceleration]'][disabled]")
      render_click(lv, "locked_hint", %{"field" => "pairing_system"})
      assert render(lv) =~ "Locked in FIDE mode"

      refute has_element?(
               lv,
               "button[phx-click='unlock_field'][phx-value-field='pairing_system']"
             )
    end

    test "a save of the rest of the page still lands", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      pair!(tournament)

      {:ok, lv, _} = live(conn, ~p"/t/#{tournament.id}/settings")
      render_submit(lv, "save", %{"tournament" => %{"name" => "Renamed", "venue" => "Hall"}})

      updated = Repo.reload!(tournament)
      assert updated.name == "Renamed"
      assert updated.tiebreaks == ~w(BH SB)
    end

    test "nothing is held before round 1", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, lv, _} = live(conn, ~p"/t/#{tournament.id}/settings")
      refute has_element?(lv, "input[name='tournament[rounds_count]'][disabled]")
      refute has_element?(lv, "#rounds-fide-lock")
    end
  end

  describe "standings with games still without a result (Q161)" do
    test "say they are not final", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      round = pair!(tournament)

      {:ok, lv, _} = live(conn, ~p"/t/#{tournament.id}/standings")
      assert has_element?(lv, "#missing-results-not-final")

      for p <- round.pairings, p.black_player_id do
        {:ok, _} = Tournaments.update_pairing_result(p, "1-0")
      end

      {:ok, lv, _} = live(conn, ~p"/t/#{tournament.id}/standings")
      refute has_element?(lv, "#missing-results-not-final")
    end
  end
end
