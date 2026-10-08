defmodule PairingsEngineWeb.FideDepartureGateTest do
  @moduledoc """
  VCL4THP Q43: every path that takes a tournament out of FIDE mode first
  shows TEC's Level-4 double confirmation, and only the second answer acts.
  One family per path - a scoring save, an options save, a categories
  toggle, a pairing moved by something that is not a FIDE rule - each with
  both outcomes: cancelling leaves everything as it was, still in FIDE mode;
  confirming twice saves and leaves, with the exit recorded.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Audit, Compliance, Repo, Tournaments}

  setup :register_and_log_in_user

  defp tournament(scope, attrs \\ %{}) do
    {:ok, t} =
      Tournaments.create_tournament(
        scope,
        Map.merge(
          %{
            "name" => "Gate",
            "type" => "swiss",
            "pairing_engine" => "ainalrami",
            "start_date" => "2026-07-01",
            "rounds_count" => "5",
            "round_dates" => List.duplicate("2026-07-01", 5),
            "tiebreaks" => ["BH", "SB"],
            "chief_arbiter" => "Jane Arbiter",
            "federation" => "BEL",
            "rate_of_play" => "90 min + 30 sec/move"
          },
          attrs
        )
      )

    t
  end

  defp players(t, count, extra \\ %{}) do
    for n <- 1..count do
      {:ok, p} =
        Tournaments.create_player(t.id, %{
          "name" => "P#{n}",
          "fide_rating" => 2050 - n * 50,
          "extra_points" => Map.get(extra, n, 0.0)
        })

      p
    end
  end

  defp lost_audit(t),
    do: Audit.list_for_tournament(t.id, action: "tournament.fide_compliance_lost")

  defp pass_both(lv, prefix \\ "fide-gate") do
    assert has_element?(lv, "##{prefix}-warn")
    refute has_element?(lv, "##{prefix}-confirm")
    lv |> element("##{prefix}-continue") |> render_click()
    assert has_element?(lv, "##{prefix}-consequences")
    lv |> element("##{prefix}-confirm") |> render_click()
  end

  describe "a scoring save" do
    @draw_worth_more %{"tournament" => %{"points_draw" => "0.75"}}

    test "cancelling at either step saves nothing", %{conn: conn, scope: scope} do
      t = tournament(scope)
      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/settings/scoring")

      render_submit(lv, "save", @draw_worth_more)
      assert has_element?(lv, "#fide-gate-warn")
      assert has_element?(lv, "#fide-gate-reasons")
      assert Repo.reload!(t).points_draw == 0.5

      lv |> element("#fide-gate-cancel") |> render_click()
      refute has_element?(lv, "#fide-gate")
      assert Repo.reload!(t).points_draw == 0.5
      assert Compliance.fide_mode?(Repo.reload!(t))

      render_submit(lv, "save", @draw_worth_more)
      lv |> element("#fide-gate-continue") |> render_click()
      lv |> element("#fide-gate-stay") |> render_click()

      refute has_element?(lv, "#fide-gate")
      assert Repo.reload!(t).points_draw == 0.5
      assert Compliance.fide_mode?(Repo.reload!(t))
      assert lost_audit(t) == []
    end

    test "a confirm that skipped the first message does nothing", %{conn: conn, scope: scope} do
      t = tournament(scope)
      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/settings/scoring")

      render_submit(lv, "save", @draw_worth_more)
      render_click(lv, "fide_gate_confirm", %{})

      assert Repo.reload!(t).points_draw == 0.5
      assert Compliance.fide_mode?(Repo.reload!(t))
    end

    test "confirming twice saves it and leaves FIDE mode, recorded", %{conn: conn, scope: scope} do
      t = tournament(scope)
      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/settings/scoring")

      render_submit(lv, "save", @draw_worth_more)
      pass_both(lv)

      left = Repo.reload!(t)
      assert left.points_draw == 0.75
      refute Compliance.fide_mode?(left)
      assert left.fide_compliance_lost_round == 0
      refute has_element?(lv, "#fide-gate")

      assert [%{details: %{"setting" => "points_draw"}}] = lost_audit(t)
    end

    test "a save that leaves FIDE mode alone is not asked about", %{conn: conn, scope: scope} do
      t = tournament(scope)
      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/settings/scoring")

      render_submit(lv, "save", %{"tournament" => %{"points_win" => "1"}})

      refute has_element?(lv, "#fide-gate")
      assert Compliance.fide_mode?(Repo.reload!(t))
    end

    test "a tournament already out of FIDE mode saves at once", %{conn: conn, scope: scope} do
      t = tournament(scope)
      {:ok, _} = Tournaments.leave_fide_mode(Repo.reload!(t))
      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/settings/scoring")

      render_submit(lv, "save", @draw_worth_more)

      refute has_element?(lv, "#fide-gate")
      assert Repo.reload!(t).points_draw == 0.75
    end
  end

  describe "an options save" do
    @keizer %{"tournament" => %{"pairing_system" => "keizer"}}

    test "cancelling leaves the pairing system as it was", %{conn: conn, scope: scope} do
      t = tournament(scope)
      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/settings/options")

      render_submit(lv, "save", @keizer)
      assert has_element?(lv, "#fide-gate-warn")
      lv |> element("#fide-gate-cancel") |> render_click()

      assert Repo.reload!(t).pairing_system == "swiss"
      assert Compliance.fide_mode?(Repo.reload!(t))
    end

    test "confirming twice saves it and leaves FIDE mode, recorded", %{conn: conn, scope: scope} do
      t = tournament(scope)
      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/settings/options")

      render_submit(lv, "save", @keizer)
      pass_both(lv)

      left = Repo.reload!(t)
      assert left.pairing_system == "keizer"
      refute Compliance.fide_mode?(left)
      assert left.fide_compliance_lost_round == 0
      assert [%{details: %{"setting" => "pairing_system"}}] = lost_audit(t)
    end
  end

  describe "late entrants after the field (VCL4THP Q156)" do
    @after_field %{"tournament" => %{"late_entry_numbering" => "after"}}

    test "the Options page offers by rating, selected, and after the field - not the grandfathered value",
         %{conn: conn, scope: scope} do
      t = tournament(scope)
      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/settings/options")

      assert has_element?(lv, "#late-entry-numbering-select option[value='rating'][selected]")
      assert has_element?(lv, "#late-entry-numbering-select option[value='after']")
      refute has_element?(lv, "#late-entry-numbering-select option[value='end']")
    end

    test "cancelling keeps by rating, in FIDE mode", %{conn: conn, scope: scope} do
      t = tournament(scope)
      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/settings/options")

      render_submit(lv, "save", @after_field)
      assert has_element?(lv, "#fide-gate-warn")
      assert has_element?(lv, "#fide-gate-reasons")
      lv |> element("#fide-gate-cancel") |> render_click()

      assert Repo.reload!(t).late_entry_numbering == "rating"
      assert Compliance.fide_mode?(Repo.reload!(t))
      assert lost_audit(t) == []
    end

    test "confirming twice saves it and leaves FIDE mode, recorded", %{conn: conn, scope: scope} do
      t = tournament(scope)
      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/settings/options")

      render_submit(lv, "save", @after_field)
      pass_both(lv)

      left = Repo.reload!(t)
      assert left.late_entry_numbering == "after"
      refute Compliance.fide_mode?(left)
      assert left.fide_compliance_lost_round == 0
      assert [%{details: %{"setting" => "late_entry_numbering"}}] = lost_audit(t)

      # The stamp reaches the TRF26 report, like every other way out (Q44).
      players(t, 4)
      {:ok, _} = PairingsEngine.Pairing.pair_next_round(Repo.reload!(t))
      {:ok, text} = PairingsEngine.TrfExport.export(Repo.reload!(t))
      assert text =~ "### FIDE mode exited before Round 1 was paired"
    end

    test "a tournament that predates the default keeps its value, offered, and saves unasked",
         %{conn: conn, scope: scope} do
      t = tournament(scope)
      {:ok, _} = t |> Ecto.Changeset.change(late_entry_numbering: "end") |> Repo.update()

      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/settings/options")
      assert has_element?(lv, "#late-entry-numbering-select option[value='end'][selected]")

      render_submit(lv, "save", %{"tournament" => %{"late_entry_numbering" => "end"}})
      refute has_element?(lv, "#fide-gate")
      assert Repo.reload!(t).late_entry_numbering == "end"
      assert Compliance.fide_mode?(Repo.reload!(t))
    end
  end

  describe "the pair-by-category toggle" do
    defp categories_tournament(scope),
      do: tournament(scope, %{"categories_enabled" => true, "categories" => ["A", "B"]})

    test "cancelling leaves it off, in FIDE mode", %{conn: conn, scope: scope} do
      t = categories_tournament(scope)
      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/categories")

      render_click(lv, "toggle_pair_by_category", %{})
      assert has_element?(lv, "#fide-gate-warn")
      lv |> element("#fide-gate-cancel") |> render_click()

      refute Repo.reload!(t).pair_by_category
      assert Compliance.fide_mode?(Repo.reload!(t))
    end

    test "confirming twice turns it on and leaves FIDE mode, recorded", %{
      conn: conn,
      scope: scope
    } do
      t = categories_tournament(scope)
      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/categories")

      render_click(lv, "toggle_pair_by_category", %{})
      pass_both(lv)

      left = Repo.reload!(t)
      assert left.pair_by_category
      refute Compliance.fide_mode?(left)
      assert [%{details: %{"setting" => "pair_by_category"}}] = lost_audit(t)
    end
  end

  describe "a pairing moved by something that is not a FIDE rule" do
    # Acceleration points in the pairing (`Pairing.pairing_deviations/2`):
    # known only once the engine has run, so the round is written and
    # rolled back until the second confirmation.
    defp accelerated(scope) do
      t = tournament(scope, %{"extra_points_mode" => "acceleration"})
      players(t, 8, %{1 => 1.0, 2 => 1.0, 3 => 1.0, 4 => 1.0})
      t
    end

    test "cancelling leaves no round and FIDE mode", %{conn: conn, scope: scope} do
      t = accelerated(scope)
      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/pairings")

      render_click(lv, "pair", %{})
      assert has_element?(lv, "#fide-gate-warn")
      assert render(lv) =~ "Extra points in the pairing"

      assert PairingsEngine.Pairing.paired_rounds_count(t.id) == 0
      assert Compliance.fide_mode?(Repo.reload!(t))

      lv |> element("#fide-gate-cancel") |> render_click()

      assert PairingsEngine.Pairing.paired_rounds_count(t.id) == 0
      assert Compliance.fide_mode?(Repo.reload!(t))
      assert lost_audit(t) == []
    end

    test "confirming twice pairs the round and leaves FIDE mode, recorded", %{
      conn: conn,
      scope: scope
    } do
      t = accelerated(scope)
      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/pairings")

      render_click(lv, "pair", %{})
      pass_both(lv)

      assert PairingsEngine.Pairing.paired_rounds_count(t.id) == 1
      left = Repo.reload!(t)
      refute Compliance.fide_mode?(left)
      assert left.fide_compliance_lost_round == 1
      assert [%{details: %{"setting" => "extra_points_pairing"}}] = lost_audit(t)
    end

    test "a pairing that moves nothing is not asked about", %{conn: conn, scope: scope} do
      t = tournament(scope)
      players(t, 8)
      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/pairings")

      render_click(lv, "pair", %{})

      refute has_element?(lv, "#fide-gate")
      assert PairingsEngine.Pairing.paired_rounds_count(t.id) == 1
      assert Compliance.fide_mode?(Repo.reload!(t))
    end
  end
end
