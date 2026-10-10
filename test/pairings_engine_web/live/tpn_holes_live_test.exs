defmodule PairingsEngineWeb.TpnHolesLiveTest do
  # The Pairings page stopping "Pair round N" (N = 2..4) when the pairing
  # numbers do not follow the ratings, its three answers, the note once
  # round 4 is paired, the numbers an unpaired round 1 gives back, and the
  # grandfathered "late entrants at the end" notice on the Pairings and
  # Options pages.
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias PairingsEngine.{Audit, Compliance, Pairing, Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Player, Tournament}

  setup :register_and_log_in_user

  defp tournament(scope, late_entry_numbering \\ "end") do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "Holes",
        "type" => "swiss",
        "start_date" => "2026-07-01",
        "rounds_count" => "7",
        "round_dates" => List.duplicate("2026-07-01", 7),
        "tiebreaks" => ["BH", "SB"],
        "chief_arbiter" => "Jane Arbiter",
        "federation" => "BEL",
        "rate_of_play" => "90 min + 30 sec/move"
      })

    # What the migration left on every tournament older than the default.
    Repo.update_all(from(x in Tournament, where: x.id == ^t.id),
      set: [late_entry_numbering: late_entry_numbering, round_one_absentees_late: false]
    )

    Repo.reload!(t)
  end

  defp add_player(t, name, rating) do
    {:ok, p} = Tournaments.create_player(t.id, %{"name" => name, "fide_rating" => rating})
    p
  end

  defp field(t, count \\ 6),
    do: for(n <- 1..count, do: add_player(t, "P#{n}", 2000 - n * 50))

  defp enter_results(t) do
    round = Tournaments.get_round(t.id, Pairing.paired_rounds_count(t.id))

    for p <- round.pairings, p.black_player_id != nil and p.result in [nil, ""] do
      {:ok, _} = Tournaments.update_pairing_result(p, "1-0")
    end
  end

  defp play_round(t) do
    {:ok, _} = Pairing.pair_next_round(Repo.reload!(t))
    enter_results(t)
  end

  defp number(%Player{id: id}), do: Repo.get!(Player, id).pairing_number
  defp paired(t), do: Pairing.paired_rounds_count(t.id)
  defp audit(t, action), do: Audit.list_for_tournament(t.id, action: action)

  defp ratings_by_number(t) do
    t.id
    |> Tournaments.list_players()
    |> Enum.filter(& &1.pairing_number)
    |> Enum.sort_by(& &1.pairing_number)
    |> Enum.map(& &1.fide_rating)
  end

  # On the round that is next to pair, where the pair button is.
  defp open(conn, t) do
    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings?round=#{paired(t) + 1}")
    lv
  end

  describe "the production sequence, on the page" do
    test "practice rounds give their numbers back; the real round 1 follows the ratings",
         %{conn: conn, scope: scope} do
      t = tournament(scope)
      for n <- 1..13, do: add_player(t, "First#{n}", 1900 - n * 40)
      lv = open(conn, t)

      for _ <- 1..3 do
        lv |> element("#pair-round") |> render_click()
        refute has_element?(lv, "#tpn-gate-dialog")
        assert paired(t) == 1
        render_click(lv, "unpair", %{})
        assert paired(t) == 0
        assert ratings_by_number(t) == []
      end

      assert [%{details: %{"round" => 1, "numbers_cleared" => 13}} | _] =
               audit(t, "pairing.round_deleted")

      for n <- 1..16, do: add_player(t, "Second#{n}", 2260 - n * 30)
      for n <- 1..11, do: add_player(t, "Third#{n}", 2100 - n * 35)

      lv = open(conn, t)
      lv |> element("#pair-round") |> render_click()
      refute has_element?(lv, "#tpn-gate-dialog")
      assert paired(t) == 1

      ratings = ratings_by_number(t)
      assert length(ratings) == 40
      assert ratings == Enum.sort(ratings, :desc)
      refute has_element?(lv, "#tpn-out-of-order")
    end
  end

  describe "pairing rounds 2 to 4 with numbers out of place" do
    setup %{scope: scope} do
      t = tournament(scope)
      # Ten with the late entrant: enough that rounds 2 to 5 always have a
      # legal pairing, whatever the colour draw did to round 1.
      field(t, 9)
      play_round(t)
      im = add_player(t, "Late, IM", 2365)
      %{t: t, im: im}
    end

    test "the pair button stops and says who, and Cancel pairs nothing",
         %{conn: conn, t: t, im: im} do
      lv = open(conn, t)
      assert has_element?(lv, "#tpn-out-of-order-#{im.id}")

      lv |> element("#pair-round") |> render_click()

      assert has_element?(lv, "#tpn-gate-dialog[role=alertdialog]")
      assert has_element?(lv, "#tpn-gate-appended")
      refute has_element?(lv, "#tpn-gate-imported")
      assert has_element?(lv, "#tpn-gate-#{im.id}")
      refute has_element?(lv, "#tpn-gate-more")
      assert has_element?(lv, "#tpn-gate-renumber")
      assert has_element?(lv, "#tpn-gate-pair-anyway")
      assert paired(t) == 1

      lv |> element("#tpn-gate-cancel") |> render_click()
      refute has_element?(lv, "#tpn-gate-dialog")
      assert paired(t) == 1
      assert number(im) == nil
    end

    test "Renumber by rating and pair: the regeneration, then the round",
         %{conn: conn, t: t, im: im} do
      lv = open(conn, t)
      lv |> element("#pair-round") |> render_click()
      lv |> element("#tpn-gate-renumber") |> render_click()

      refute has_element?(lv, "#tpn-gate-dialog")
      assert paired(t) == 2
      assert number(im) == 1
      assert ratings_by_number(t) == Enum.sort(ratings_by_number(t), :desc)
      refute has_element?(lv, "#tpn-out-of-order")

      assert [%{details: %{"regenerated" => 10, "round" => 1}}] =
               audit(t, "player.pairing_numbers_changed")

      assert audit(t, "pairing.tpn_order_accepted") == []
      assert Compliance.fide_mode?(Repo.reload!(t))
    end

    test "Pair anyway: audited, not a FIDE-mode departure, and not asked again for the same players",
         %{conn: conn, t: t, im: im} do
      lv = open(conn, t)
      lv |> element("#pair-round") |> render_click()
      lv |> element("#tpn-gate-pair-anyway") |> render_click()

      refute has_element?(lv, "#tpn-gate-dialog")
      assert paired(t) == 2
      assert number(im) == 10

      assert [%{details: %{"round" => 2, "count" => 10, "players" => names}}] =
               audit(t, "pairing.tpn_order_accepted")

      assert names =~ "Late, IM"
      assert Compliance.fide_mode?(Repo.reload!(t))
      assert audit(t, "tournament.fide_compliance_lost") == []

      # Round 3: the same players are out of place, so no question.
      enter_results(t)
      lv = open(conn, t)
      refute has_element?(lv, "#tpn-out-of-order")
      lv |> element("#pair-round") |> render_click()
      refute has_element?(lv, "#tpn-gate-dialog")
      assert paired(t) == 3

      # Round 4, with somebody new out of place: asked again.
      enter_results(t)
      fm = add_player(t, "Late, FM", 2260)
      lv = open(conn, t)
      lv |> element("#pair-round") |> render_click()
      assert has_element?(lv, "#tpn-gate-#{fm.id}")
      assert paired(t) == 3
    end

    test "after round 4: no dialog, and a note that says why nothing can be done",
         %{conn: conn, t: t, im: im} do
      lv = open(conn, t)
      lv |> element("#pair-round") |> render_click()
      lv |> element("#tpn-gate-pair-anyway") |> render_click()
      enter_results(t)
      for _ <- 3..4, do: play_round(t)

      lv = open(conn, t)
      refute has_element?(lv, "#tpn-out-of-order")
      assert has_element?(lv, "#tpn-locked-note")
      assert has_element?(lv, "#tpn-locked-#{im.id}")

      lv |> element("#pair-round") |> render_click()
      refute has_element?(lv, "#tpn-gate-dialog")
      assert paired(t) == 5
      assert has_element?(lv, "#tpn-locked-note")
    end
  end

  test "a long list is capped", %{conn: conn, scope: scope} do
    t = tournament(scope)
    field(t, 16)
    play_round(t)
    add_player(t, "Late, IM", 2365)

    lv = open(conn, t)
    lv |> element("#pair-round") |> render_click()
    assert has_element?(lv, "#tpn-gate-more")

    assert lv
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.query("#tpn-gate-list li")
           |> Enum.count() == 13
  end

  test "numbers that came with an imported file: the same question, saying so",
       %{conn: conn, scope: scope} do
    t = tournament(scope, "rating")
    [first, _, _, _, _, last] = field(t)
    play_round(t)

    Repo.update_all(from(x in Tournament, where: x.id == ^t.id),
      set: [pairing_numbers_origin: "import"]
    )

    Repo.update_all(from(p in Player, where: p.id == ^first.id), set: [pairing_number: 6])
    Repo.update_all(from(p in Player, where: p.id == ^last.id), set: [pairing_number: 1])

    lv = open(conn, t)
    lv |> element("#pair-round") |> render_click()
    assert has_element?(lv, "#tpn-gate-imported")
    refute has_element?(lv, "#tpn-gate-appended")
    assert has_element?(lv, "#tpn-gate-#{first.id}")
    assert has_element?(lv, "#tpn-gate-renumber")
    assert has_element?(lv, "#tpn-gate-pair-anyway")
    assert has_element?(lv, "#tpn-gate-cancel")
  end

  test "a round robin is never asked", %{conn: conn, scope: scope} do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "RR",
        "type" => "roundrobin",
        "pairing_system" => "round_robin",
        "rounds_count" => "5",
        "round_dates" => List.duplicate("2026-07-01", 5),
        "tiebreaks" => ["SB"]
      })

    for n <- 1..6, do: add_player(t, "P#{n}", 1500 + n * 50)
    lv = open(conn, t)
    render_click(lv, "pair", %{})
    refute has_element?(lv, "#tpn-gate-dialog")
    refute has_element?(lv, "#tpn-locked-note")
    refute has_element?(lv, "#late-entry-notice")
  end

  describe "the \"late entrants at the end\" notice" do
    test "on the Pairings page: switch sets by rating and the notice goes",
         %{conn: conn, scope: scope} do
      t = tournament(scope)
      field(t)
      play_round(t)

      lv = open(conn, t)
      assert has_element?(lv, "#late-entry-notice")
      lv |> element("#late-entry-notice-switch") |> render_click()

      refute has_element?(lv, "#late-entry-notice")
      assert Repo.reload!(t).late_entry_numbering == "rating"

      assert [%{details: %{"changed_fields" => %{"late_entry_numbering" => ["end", "rating"]}}}] =
               audit(t, "tournament.settings_updated")

      refute has_element?(open(conn, t), "#late-entry-notice")
    end

    test "on the Options page: keep leaves the setting and is remembered",
         %{conn: conn, scope: scope} do
      t = tournament(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/options")
      assert has_element?(lv, "#late-entry-notice")
      lv |> element("#late-entry-notice-keep") |> render_click()

      refute has_element?(lv, "#late-entry-notice")
      assert Repo.reload!(t).late_entry_numbering == "end"
      assert [_] = audit(t, "tournament.late_entry_numbering_kept")

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/options")
      refute has_element?(lv, "#late-entry-notice")
      refute has_element?(open(conn, t), "#late-entry-notice")
    end

    test "on the Options page: switch moves the select with it", %{conn: conn, scope: scope} do
      t = tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/options")
      lv |> element("#late-entry-notice-switch") |> render_click()

      assert Repo.reload!(t).late_entry_numbering == "rating"
      assert has_element?(lv, "#late-entry-numbering-select option[value=rating][selected]")
      refute has_element?(lv, "#late-entry-numbering-select option[value=end]")
    end

    test "not for a tournament already on by rating, nor once round 4 is paired",
         %{conn: conn, scope: scope} do
      refute has_element?(open(conn, tournament(scope, "rating")), "#late-entry-notice")

      t = tournament(scope)
      field(t, 8)
      for _ <- 1..4, do: play_round(t)
      refute has_element?(open(conn, t), "#late-entry-notice")

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/options")
      refute has_element?(lv, "#late-entry-notice")
    end
  end

  test "a tournament made with the New tournament form numbers late entrants by rating",
       %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/")
    lv |> element("button", "New tournament") |> render_click()

    lv
    |> form("#new-tournament-form",
      tournament: %{name: "Brand New", pairing_system: "swiss", rounds_count: "7"}
    )
    |> render_submit()

    t = Repo.one!(from x in Tournament, where: x.name == "Brand New")
    assert t.late_entry_numbering == "rating"
    assert t.round_one_absentees_late
    refute Tournaments.late_entry_notice?(t)
  end
end
