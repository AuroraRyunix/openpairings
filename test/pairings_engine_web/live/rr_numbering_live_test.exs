defmodule PairingsEngineWeb.RrNumberingLiveTest do
  @moduledoc """
  The first pairing of a round robin asks how the players are numbered (by
  rating, as entered, by lot, or as set on the Players page), shows the list
  that gives, and fixes it; the Players page's "Start numbers" dialog offers
  the same three. The numbering rules are
  `PairingsEngine.StartingNumbersChoiceTest`.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Audit, Repo, StartingNumbers, Tournaments}
  alias PairingsEngine.Tournaments.Player

  setup :register_and_log_in_user

  # Entered in an order that is neither the rating order nor the alphabet.
  @entered [{"Dave", 1700}, {"Alice", 2000}, {"Carol", 1800}, {"Bob", 1900}]

  defp tournament(scope, players \\ @entered) do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "Round robin numbering",
        "type" => "roundrobin",
        "pairing_system" => "round_robin",
        "start_date" => "2026-07-15",
        "rounds_count" => "3",
        "round_dates" => List.duplicate("2026-07-15", 3),
        "tiebreaks" => ["SB"],
        "chief_arbiter" => "Jane Arbiter",
        "federation" => "BEL",
        "rate_of_play" => "90 min + 30 sec/move"
      })

    people =
      for {name, rating} <- players, into: %{} do
        {:ok, p} = Tournaments.create_player(t.id, %{name: name, fide_rating: rating})
        {name, p}
      end

    {Repo.reload!(t), people}
  end

  defp number(player), do: Repo.get!(Player, player.id).pairing_number

  defp listed(lv) do
    lv
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#rr-numbers-list tbody tr td:nth-child(2)")
    |> Enum.map(&LazyHTML.text/1)
  end

  defp starting_number_audit(t),
    do:
      t.id
      |> Audit.list_for_tournament()
      |> Enum.filter(&(&1.action == "player.starting_numbers_set"))

  defp board_sets(t) do
    t.id
    |> Tournaments.get_round(1)
    |> Repo.preload(:pairings)
    |> Map.fetch!(:pairings)
    |> Enum.map(&MapSet.new([&1.white_player_id, &1.black_player_id]))
  end

  test "pairing asks first: nothing is paired until the dialog is confirmed",
       %{conn: conn, scope: scope} do
    {t, _p} = tournament(scope)
    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

    lv |> element("#pair-round") |> render_click()

    assert has_element?(lv, "#rr-numbers-dialog")
    assert has_element?(lv, "#rr-numbers-mode-rating")
    assert has_element?(lv, "#rr-numbers-mode-entered")
    assert has_element?(lv, "#rr-numbers-mode-lots")
    refute has_element?(lv, "#rr-numbers-mode-set")
    assert has_element?(lv, "#rr-numbers-lock-note")
    assert has_element?(lv, "#rr-numbers-confirm")
    assert Tournaments.get_round(t.id, 1) == nil
    assert starting_number_audit(t) == []

    lv |> element("#rr-numbers-cancel") |> render_click()
    refute has_element?(lv, "#rr-numbers-dialog")
    assert Tournaments.get_round(t.id, 1) == nil
  end

  test "by rating is preselected and lists the field by rating",
       %{conn: conn, scope: scope} do
    {t, _p} = tournament(scope)
    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
    lv |> element("#pair-round") |> render_click()

    assert has_element?(lv, "#rr-numbers-mode-rating[checked]")
    assert listed(lv) == ~w(Alice Bob Carol Dave)
  end

  test "as entered lists and fixes the entry order, and the table pairs on it",
       %{conn: conn, scope: scope} do
    {t, p} = tournament(scope)
    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
    lv |> element("#pair-round") |> render_click()
    lv |> element("#rr-numbers-mode-entered") |> render_click()

    assert has_element?(lv, "#rr-numbers-mode-entered[checked]")
    assert listed(lv) == ~w(Dave Alice Carol Bob)
    # Shown, not yet fixed.
    assert number(p["Dave"]) == nil

    lv |> element("#rr-numbers-confirm") |> render_click()

    assert Enum.map(~w(Dave Alice Carol Bob), &number(p[&1])) == [1, 2, 3, 4]
    # Berger round 1 for four: 1-4, 2-3.
    sets = board_sets(t)
    assert MapSet.new([p["Dave"].id, p["Bob"].id]) in sets
    assert MapSet.new([p["Alice"].id, p["Carol"].id]) in sets

    assert [entry] = starting_number_audit(t)
    assert entry.details["mode"] == "entered"
    assert entry.details["via"] == "pair"
    assert Enum.map(entry.details["order"], & &1["name"]) == ~w(Dave Alice Carol Bob)
  end

  test "by rating fixes the rating order and records the choice",
       %{conn: conn, scope: scope} do
    {t, p} = tournament(scope)
    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
    lv |> element("#pair-round") |> render_click()
    lv |> element("#rr-numbers-confirm") |> render_click()

    assert Enum.map(~w(Alice Bob Carol Dave), &number(p[&1])) == [1, 2, 3, 4]
    assert [entry] = starting_number_audit(t)
    assert entry.details["mode"] == "rating"
    assert entry.details["seed"] == nil
  end

  test "equal ratings number the same way every time", %{conn: conn, scope: scope} do
    {t, p} = tournament(scope, [{"Yves", 1600}, {"Xena", 1600}, {"Wim", 1600}, {"Una", 1600}])
    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
    lv |> element("#pair-round") |> render_click()

    first = listed(lv)
    assert first == ~w(Una Wim Xena Yves)

    lv |> element("#rr-numbers-cancel") |> render_click()
    lv |> element("#pair-round") |> render_click()
    assert listed(lv) == first

    lv |> element("#rr-numbers-confirm") |> render_click()
    assert Enum.map(first, &number(p[&1])) == [1, 2, 3, 4]
  end

  test "by lot: nothing to confirm until the lots are drawn, and the draw is on record",
       %{conn: conn, scope: scope} do
    {t, p} = tournament(scope)
    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
    lv |> element("#pair-round") |> render_click()
    lv |> element("#rr-numbers-mode-lots") |> render_click()

    assert has_element?(lv, "#rr-numbers-confirm[disabled]")
    assert listed(lv) == []

    lv |> element("#rr-numbers-draw") |> render_click()
    refute has_element?(lv, "#rr-numbers-confirm[disabled]")
    assert has_element?(lv, "#rr-numbers-seed")
    drawn = listed(lv)
    assert Enum.sort(drawn) == ~w(Alice Bob Carol Dave)

    lv |> element("#rr-numbers-confirm") |> render_click()

    assert Enum.map(drawn, &number(p[&1])) == [1, 2, 3, 4]

    assert [entry] = starting_number_audit(t)
    assert entry.details["mode"] == "lots"
    seed = entry.details["seed"]
    assert is_integer(seed)

    # The trail reproduces the draw: same seed on the entry order.
    entry_ids = t.id |> Tournaments.list_players() |> Enum.sort_by(& &1.id) |> Enum.map(& &1.id)

    assert Enum.map(entry.details["order"], & &1["id"]) ==
             StartingNumbers.shuffle_by_seed(entry_ids, seed)
  end

  test "numbers set on the Players page are preselected and kept",
       %{conn: conn, scope: scope} do
    {t, p} = tournament(scope)
    {:ok, _} = StartingNumbers.set_order(t, Enum.map(~w(Carol Dave Alice Bob), &p[&1].id))

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
    lv |> element("#pair-round") |> render_click()

    assert has_element?(lv, "#rr-numbers-mode-set[checked]")
    assert listed(lv) == ~w(Carol Dave Alice Bob)

    lv |> element("#rr-numbers-confirm") |> render_click()
    assert Enum.map(~w(Carol Dave Alice Bob), &number(p[&1])) == [1, 2, 3, 4]
    assert [%{details: %{"mode" => "set"}}] = starting_number_audit(t)
  end

  test "numbers equal to the entry order say so", %{conn: conn, scope: scope} do
    {t, _p} = tournament(scope)
    {:ok, _} = StartingNumbers.by_entry(t)

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
    lv |> element("#pair-round") |> render_click()

    assert has_element?(lv, "#rr-numbers-set-note")
  end

  test "once round 1 exists the question is not asked again",
       %{conn: conn, scope: scope} do
    {t, _p} = tournament(scope)
    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
    lv |> element("#pair-round") |> render_click()
    lv |> element("#rr-numbers-confirm") |> render_click()

    render_click(lv, "rr_numbers_open", %{})
    refute has_element?(lv, "#rr-numbers-dialog")
    refute StartingNumbers.editable?(Repo.reload!(t))
  end

  test "the pair-by-hand dialog asks the same question and fixes the numbers",
       %{conn: conn, scope: scope} do
    {t, p} = tournament(scope)
    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

    lv |> element("#rr-pair-by-hand") |> render_click()
    assert has_element?(lv, "#mpa-rr_round-dialog #rr-numbers")
    refute has_element?(lv, "#rr-numbers-dialog")

    lv |> element("#rr-numbers-mode-entered") |> render_click()
    lv |> element("#mpa-ack") |> render_click()
    lv |> element("#rr-pair-by-hand-confirm") |> render_click()

    assert Enum.map(~w(Dave Alice Carol Bob), &number(p[&1])) == [1, 2, 3, 4]
    assert [entry] = starting_number_audit(t)
    assert entry.details["mode"] == "entered"
    assert entry.details["via"] == "by_hand"
  end

  test "the Players page offers the same three", %{conn: conn, scope: scope} do
    {t, p} = tournament(scope)
    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/players")

    lv |> element("#open-starting-numbers") |> render_click()
    assert has_element?(lv, "#sn-draw-lots")
    assert has_element?(lv, "#sn-by-rating")
    assert has_element?(lv, "#sn-by-entry")

    lv |> element("#sn-by-entry") |> render_click()
    assert Enum.map(~w(Dave Alice Carol Bob), &number(p[&1])) == [1, 2, 3, 4]
    assert [%{details: %{"mode" => "entered"}}] = starting_number_audit(t)

    lv |> element("#sn-draw-lots") |> render_click()
    [lots | _] = starting_number_audit(t)
    assert lots.details["mode"] == "lots"
    assert is_integer(lots.details["seed"])
    assert length(lots.details["order"]) == 4
  end
end
