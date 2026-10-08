defmodule PairingsEngineWeb.SettingsRestrictionsLiveTest do
  @moduledoc """
  The Forbidden pairings page: rules by club or federation, several players
  kept apart in one go, pairs and groups edited in place, the effect on the
  next round, and - in FIDE mode once round 1 is paired - the Level-4
  double confirmation before any change (VCL4THP Q195/Q196).
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
            "name" => "Restrictions",
            "type" => "swiss",
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

  defp player(t, name, attrs \\ %{}) do
    {:ok, p} =
      Tournaments.create_player(t.id, Map.merge(%{"name" => name, "fide_rating" => 1800}, attrs))

    p
  end

  defp page(conn, t) do
    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/restrictions")
    lv
  end

  defp tick(lv, players),
    do: for(p <- players, do: render_click(lv, "toggle_player", %{"id" => p.id}))

  test "is reachable from the settings tabs", %{conn: conn, scope: scope} do
    t = tournament(scope)
    {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/settings/options")
    assert has_element?(lv, "a[href='/t/#{t.id}/settings/restrictions']")
  end

  test "a club rule is added from the form and shows what it does", %{conn: conn, scope: scope} do
    t = tournament(scope)

    for {n, club} <- [
          {"A1", "Rook"},
          {"A2", "Rook"},
          {"A3", "Rook"},
          {"B1", "Knight"},
          {"B2", "Knight"}
        ],
        do: player(t, n, %{"club" => club})

    lv = page(conn, t)

    lv
    |> form("#add-rule-form", %{
      "rule" => %{"kind" => "club", "soft" => "false", "window" => "all"}
    })
    |> render_submit()

    assert [rule] = Tournaments.list_pairing_rules(t.id)
    assert has_element?(lv, "#rule-#{rule.id}", "4 pairs")
    assert has_element?(lv, "#rule-#{rule.id}", "2 clubs")
    assert has_element?(lv, "#restrictions-forbidden-count", "4")
  end

  test "a wish for the last rounds is stored with its window", %{conn: conn, scope: scope} do
    t = tournament(scope)
    lv = page(conn, t)

    render_change(lv, "rule_change", %{"rule" => %{"window" => "last"}})
    assert has_element?(lv, "#add-rule-form input[name='rule[window_rounds]']")

    lv
    |> form("#add-rule-form", %{
      "rule" => %{
        "kind" => "federation",
        "names" => "BEL, ned",
        "soft" => "true",
        "window" => "last",
        "window_rounds" => "2"
      }
    })
    |> render_submit()

    assert [
             %{
               kind: "federation",
               soft: true,
               names: ["BEL", "ned"],
               window: "last",
               window_rounds: 2
             }
           ] =
             Tournaments.list_pairing_rules(t.id)
  end

  test "a rule is edited and removed in place", %{conn: conn, scope: scope} do
    t = tournament(scope)
    {:ok, rule} = Tournaments.add_pairing_rule(t, %{"kind" => "club"})
    lv = page(conn, t)

    lv |> element("#edit-rule-#{rule.id}") |> render_click()
    assert has_element?(lv, "#edit-rule-form-#{rule.id}")
    render_change(lv, "edit_rule_change", %{"rule" => %{"kind" => "club", "window" => "first"}})

    lv
    |> form("#edit-rule-form-#{rule.id}", %{
      "rule" => %{"kind" => "club", "soft" => "true", "window" => "first", "window_rounds" => "2"}
    })
    |> render_submit()

    assert [%{soft: true, window: "first", window_rounds: 2}] =
             Tournaments.list_pairing_rules(t.id)

    refute has_element?(lv, "#edit-rule-form-#{rule.id}")

    lv |> element("#remove-rule-#{rule.id}") |> render_click()
    assert Tournaments.list_pairing_rules(t.id) == []
  end

  test "two ticked players make a pair, three make a group", %{conn: conn, scope: scope} do
    t = tournament(scope)
    [a, b, c, d] = for n <- ~w(Ann Ben Cas Dirk), do: player(t, n)
    lv = page(conn, t)

    tick(lv, [a, b])
    assert has_element?(lv, "#selected-players", "Ann")
    lv |> form("#keep-apart-form", %{"soft" => "false"}) |> render_submit()

    assert [%{soft: false}] = Tournaments.list_forbidden_pairings(t.id)

    tick(lv, [b, c, d])
    assert has_element?(lv, "#keep-apart", "Keep these 3 apart")
    lv |> form("#keep-apart-form", %{"soft" => "true"}) |> render_submit()

    assert [%{kind: "group", soft: true, player_ids: ids} = group] =
             Tournaments.list_pairing_rules(t.id)

    assert Enum.sort(ids) == Enum.sort([b.id, c.id, d.id])
    assert has_element?(lv, "#group-#{group.id}", "3 pairs")

    # Edit the group: drop Dirk.
    lv |> element("#edit-group-#{group.id}") |> render_click()
    assert has_element?(lv, "#keep-apart", "Save group")
    tick(lv, [d])
    lv |> form("#keep-apart-form", %{"soft" => "true"}) |> render_submit()

    assert [%{player_ids: ids}] = Tournaments.list_pairing_rules(t.id)
    assert Enum.sort(ids) == Enum.sort([b.id, c.id])
  end

  test "a pair is made a wish and removed in place", %{conn: conn, scope: scope} do
    t = tournament(scope)
    [a, b] = for n <- ~w(Ann Ben), do: player(t, n)
    {:ok, fp} = Tournaments.add_forbidden_pairing(t, a.id, b.id)
    lv = page(conn, t)

    lv |> element("#soft-pair-#{fp.id}") |> render_click()
    assert [%{soft: true}] = Tournaments.list_forbidden_pairings(t.id)

    assert [%{action: "forbidden_pairing.changed"}] =
             Audit.list_for_tournament(t.id, action: "forbidden_pairing.changed")

    lv |> element("#remove-pair-#{fp.id}") |> render_click()
    assert Tournaments.list_forbidden_pairings(t.id) == []
  end

  test "the search narrows the list by name, club or federation", %{conn: conn, scope: scope} do
    t = tournament(scope)
    player(t, "Ann", %{"club" => "Rook"})
    player(t, "Ben", %{"club" => "Knight"})
    lv = page(conn, t)

    lv |> form("#player-search-form", %{"q" => "knig"}) |> render_change()
    assert has_element?(lv, "#player-options", "Ben")
    refute has_element?(lv, "#player-options", "Ann")
  end

  test "rules that leave the next round unpairable say so before Pair is pressed", %{
    conn: conn,
    scope: scope
  } do
    t = tournament(scope)
    for n <- ~w(A B C D), do: player(t, n, %{"club" => "Rook"})
    lv = page(conn, t)
    refute has_element?(lv, "#restrictions-unpairable")

    {:ok, _} = Tournaments.add_pairing_rule(t, %{"kind" => "club"})
    lv = page(conn, t)

    assert has_element?(lv, "#restrictions-unpairable")
    assert has_element?(lv, "#restrictions-isolated")
  end

  describe "FIDE mode" do
    test "before round 1 it says to set them now, and nothing asks", %{conn: conn, scope: scope} do
      t = tournament(scope)
      [a, b] = for n <- ~w(Ann Ben), do: player(t, n)
      lv = page(conn, t)

      assert has_element?(lv, "#restrictions-fide-note", "Set these before round 1 is paired")
      tick(lv, [a, b])
      lv |> form("#keep-apart-form", %{"soft" => "false"}) |> render_submit()

      refute has_element?(lv, "#fide-gate")
      assert Compliance.fide_mode?(Repo.reload!(t))
    end

    test "after round 1 a change asks twice, and cancelling changes nothing", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope)
      players = for n <- ~w(Ann Ben Cas Dirk), do: player(t, n)
      {:ok, _} = PairingsEngine.Pairing.pair_next_round(Repo.reload!(t))
      lv = page(conn, t)

      assert has_element?(lv, "#restrictions-fide-note", "Round 1 is paired")

      tick(lv, Enum.take(players, 2))
      lv |> form("#keep-apart-form", %{"soft" => "false"}) |> render_submit()
      assert has_element?(lv, "#fide-gate-warn")
      assert has_element?(lv, "#fide-gate-reasons", "Forbidden pairings")

      lv |> element("#fide-gate-cancel") |> render_click()
      assert Tournaments.list_forbidden_pairings(t.id) == []
      assert Compliance.fide_mode?(Repo.reload!(t))
    end

    test "after round 1, confirming twice adds it and leaves FIDE mode, recorded", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope)
      for n <- ~w(Ann Ben Cas Dirk), do: player(t, n)
      {:ok, _} = PairingsEngine.Pairing.pair_next_round(Repo.reload!(t))
      lv = page(conn, t)

      lv
      |> form("#add-rule-form", %{
        "rule" => %{"kind" => "club", "soft" => "false", "window" => "all"}
      })
      |> render_submit()

      assert Tournaments.list_pairing_rules(t.id) == []
      lv |> element("#fide-gate-continue") |> render_click()
      lv |> element("#fide-gate-confirm") |> render_click()

      assert [%{from_round: 2}] = Tournaments.list_pairing_rules(t.id)
      left = Repo.reload!(t)
      assert left.fide_compliance_lost_round == 1
      refute Compliance.fide_mode?(left)

      assert [%{details: %{"setting" => "forbidden_pairings", "round" => 1}}] =
               Audit.list_for_tournament(t.id, action: "tournament.fide_compliance_lost")

      assert [_] = Audit.list_for_tournament(t.id, action: "pairing_rule.added")
      refute has_element?(lv, "#restrictions-fide-note", "Round 1 is paired")
    end
  end
end
