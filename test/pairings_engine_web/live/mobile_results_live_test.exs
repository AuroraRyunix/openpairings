defmodule PairingsEngineWeb.MobileResultsLiveTest do
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest
  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.{Audit, Mobile, Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Pairing, Round}
  alias PairingsEngineWeb.AuditLive
  alias PairingsEngine.Pairing, as: Engine

  defp enrolled_conn(conn, tournament, opts \\ []) do
    {:ok, enrollment} = Mobile.create_enrollment(tournament.id, opts)
    init_test_session(conn, %{mobile_enrollment_id: enrollment.id})
  end

  defp paired_tournament do
    scope = user_scope_fixture()

    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{"name" => "Mobile T", "type" => "swiss"})

    {:ok, _white} =
      Tournaments.create_player(tournament.id, %{
        "name" => "White Player",
        "fide_rating" => "2000"
      })

    {:ok, _black} =
      Tournaments.create_player(tournament.id, %{
        "name" => "Black Player",
        "fide_rating" => "1900"
      })

    assert {:ok, _round} = Engine.pair_next_round(tournament)
    tournament
  end

  # Everything below (level/round/board-range enforcement) is built by
  # inserting `Round`/`Pairing` rows directly rather than going through
  # `Engine.pair_next_round/1`, unlike `paired_tournament/0` above - it needs
  # no `@tag :javafo` and no jar most checkouts of this repo don't have (see
  # `test/test_helper.exs`), and it is the only way to get a SPECIFIC board
  # already carrying a result, or a SECOND round, without depending on what
  # the real pairing engine happens to produce.
  defp new_tournament(name \\ "Mobile Level Test") do
    scope = user_scope_fixture()
    {:ok, tournament} = Tournaments.create_tournament(scope, %{"name" => name, "type" => "swiss"})
    tournament
  end

  defp two_players(tournament) do
    {:ok, white} =
      Tournaments.create_player(tournament.id, %{
        "name" => "White Player",
        "fide_rating" => "2000"
      })

    {:ok, black} =
      Tournaments.create_player(tournament.id, %{
        "name" => "Black Player",
        "fide_rating" => "1900"
      })

    {white, black}
  end

  # `boards` is `[{white_player, black_player, result}, ...]`, one per board,
  # numbered 1.. in list order.
  defp insert_round(tournament, number, status, boards) do
    round = Repo.insert!(%Round{tournament_id: tournament.id, number: number, status: status})

    boards
    |> Enum.with_index(1)
    |> Enum.each(fn {{white, black, result}, board} ->
      Repo.insert!(%Pairing{
        round_id: round.id,
        board: board,
        white_player_id: white.id,
        black_player_id: black.id,
        result: result
      })
    end)

    round
  end

  @tag :javafo
  test "shows each player's rating and their score entering the round", %{conn: conn} do
    tournament = paired_tournament()
    conn = enrolled_conn(conn, tournament)

    {:ok, _lv, html} = live(conn, ~p"/m/results")

    assert html =~ "2000"
    assert html =~ "1900"
    assert html =~ "0 pts"
  end

  @tag :javafo
  test "locking blocks result entry until unlocked again", %{conn: conn} do
    tournament = paired_tournament()
    conn = enrolled_conn(conn, tournament)

    {:ok, lv, html} = live(conn, ~p"/m/results")
    refute html =~ "locked - tap the lock to enter results"

    pairing = tournament.id |> Tournaments.get_round(1) |> Map.fetch!(:pairings) |> hd()

    lv |> element("button.mobile-lock-btn") |> render_click()
    assert render(lv) =~ "locked - tap the lock to enter results"

    # The result buttons are also `disabled` while locked (Phoenix.LiveViewTest
    # itself refuses to click a disabled element, mirroring a real browser) -
    # send the event directly to exercise the actual server-side guard.
    render_click(lv, "set_result", %{"id" => to_string(pairing.id), "result" => "1-0"})

    assert Tournaments.get_round(tournament.id, 1).pairings
           |> Enum.find(&(&1.id == pairing.id))
           |> Map.fetch!(:result) == ""

    lv |> element("button.mobile-lock-btn") |> render_click()

    render_click(lv, "set_result", %{"id" => to_string(pairing.id), "result" => "1-0"})

    assert Tournaments.get_round(tournament.id, 1).pairings
           |> Enum.find(&(&1.id == pairing.id))
           |> Map.fetch!(:result) == "1-0"
  end

  describe "extra results (forfeits/asymmetric codes, behind \"More…\")" do
    @tag :javafo
    test "the extra codes are hidden until \"More…\" is tapped, then settable", %{conn: conn} do
      tournament = paired_tournament()
      conn = enrolled_conn(conn, tournament)

      {:ok, lv, html} = live(conn, ~p"/m/results")
      pairing = tournament.id |> Tournaments.get_round(1) |> Map.fetch!(:pairings) |> hd()

      refute html =~ "1-0 FF"

      html = lv |> element("button.mobile-more") |> render_click()
      assert html =~ "1-0 FF"
      assert html =~ "0-0 FF"

      render_click(lv, "set_result", %{"id" => to_string(pairing.id), "result" => "1-0FF"})

      assert Tournaments.get_round(tournament.id, 1).pairings
             |> Enum.find(&(&1.id == pairing.id))
             |> Map.fetch!(:result) == "1-0FF"
    end

    @tag :javafo
    test "the played-but-unrated codes are offered and writable from a phone", %{conn: conn} do
      # The write guard was a hand-copied ten-item list whose comment claimed
      # it mirrored the Pairings page. It had been missing these three since
      # the day they shipped, so a helper at the board could not record a
      # game that ended before the minimum number of moves.
      tournament = paired_tournament()
      conn = enrolled_conn(conn, tournament)

      {:ok, lv, _html} = live(conn, ~p"/m/results")
      pairing = tournament.id |> Tournaments.get_round(1) |> Map.fetch!(:pairings) |> hd()

      html = lv |> element("button.mobile-more") |> render_click()
      assert html =~ "1-0 (played, not rated)"

      render_click(lv, "set_result", %{"id" => to_string(pairing.id), "result" => "1/2-1/2U"})

      assert Tournaments.get_round(tournament.id, 1).pairings
             |> Enum.find(&(&1.id == pairing.id))
             |> Map.fetch!(:result) == "1/2-1/2U"
    end

    @tag :javafo
    test "a board already carrying an extra-code result shows its panel without a tap", %{
      conn: conn
    } do
      tournament = paired_tournament()
      round = Tournaments.get_round(tournament.id, 1)
      pairing = hd(round.pairings)
      Tournaments.update_pairing_result(pairing, "0-0FF")

      conn = enrolled_conn(conn, tournament)
      {:ok, _lv, html} = live(conn, ~p"/m/results")

      assert html =~ "0-0 FF (double forfeit)"
    end
  end

  describe "audit trail" do
    @tag :javafo
    test "entering a result from a phone writes an audit row (previously wrote nothing at all)",
         %{conn: conn} do
      tournament = paired_tournament()
      {:ok, enrollment} = Mobile.create_enrollment(tournament.id, label: "Board 3 tablet")
      conn = init_test_session(conn, %{mobile_enrollment_id: enrollment.id})

      {:ok, lv, _html} = live(conn, ~p"/m/results")

      round = Tournaments.get_round(tournament.id, 1)
      pairing = hd(round.pairings)

      render_click(lv, "set_result", %{"id" => to_string(pairing.id), "result" => "1-0"})

      [entry] = Audit.list_for_tournament(tournament.id)
      assert entry.action == "pairing.result_entered"
      assert entry.user_id == nil
      assert entry.details["via"] == "mobile"
      assert entry.details["enrollment_id"] == enrollment.id
      assert entry.details["enrollment_label"] == "Board 3 tablet"

      assert AuditLive.describe(entry.action, entry.details) =~
               ~s(via phone, "Board 3 tablet")
    end

    @tag :javafo
    test "a phone with no label is still identifiable, by enrollment id", %{conn: conn} do
      tournament = paired_tournament()
      {:ok, enrollment} = Mobile.create_enrollment(tournament.id)
      conn = init_test_session(conn, %{mobile_enrollment_id: enrollment.id})

      {:ok, lv, _html} = live(conn, ~p"/m/results")

      round = Tournaments.get_round(tournament.id, 1)
      pairing = hd(round.pairings)

      render_click(lv, "set_result", %{"id" => to_string(pairing.id), "result" => "1/2-1/2"})

      [entry] = Audit.list_for_tournament(tournament.id)

      assert AuditLive.describe(entry.action, entry.details) =~
               "via phone, enrollment ##{enrollment.id}"
    end

    test "records the level the phone was minted with, so the trail says what it could do", %{
      conn: conn
    } do
      tournament = new_tournament()
      {white, black} = two_players(tournament)
      insert_round(tournament, 1, "playing", [{white, black, ""}])

      conn = enrolled_conn(conn, tournament, level: "deputy")
      {:ok, lv, _html} = live(conn, ~p"/m/results")

      pairing = tournament.id |> Tournaments.get_round(1) |> Map.fetch!(:pairings) |> hd()

      render_click(lv, "set_result", %{"id" => to_string(pairing.id), "result" => "1-0"})

      [entry] = Audit.list_for_tournament(tournament.id)
      assert entry.details["enrollment_level"] == "deputy"
      assert AuditLive.describe(entry.action, entry.details) =~ "deputy"
    end
  end

  describe "revoking an enrollment reaches the phone that is holding it" do
    @tag :javafo
    test "the revoked phone is sent back to the code-entry page", %{conn: conn} do
      # `revoke/1` only wrote `revoked_at` and told nobody. The page kept
      # reloading the round on every tournament change and re-checked the
      # enrollment only when it tried to WRITE, so from the helper's side
      # revoking did nothing at all until they next tapped a result.
      tournament = paired_tournament()
      {:ok, enrollment} = Mobile.create_enrollment(tournament.id)
      conn = init_test_session(conn, %{mobile_enrollment_id: enrollment.id})

      {:ok, lv, _html} = live(conn, ~p"/m/results")

      {:ok, _revoked} = Mobile.revoke(enrollment)

      assert_redirect(lv, ~p"/m")
    end

    @tag :javafo
    test "a different phone on the same tournament stays put", %{conn: conn} do
      # The broadcast goes to the whole tournament topic, so the id has to
      # be checked - otherwise revoking one phone would evict all of them.
      tournament = paired_tournament()
      {:ok, mine} = Mobile.create_enrollment(tournament.id)
      {:ok, theirs} = Mobile.create_enrollment(tournament.id)

      conn = init_test_session(conn, %{mobile_enrollment_id: mine.id})
      {:ok, lv, _html} = live(conn, ~p"/m/results")

      {:ok, _revoked} = Mobile.revoke(theirs)

      refute_redirected(lv, ~p"/m")
      assert render(lv) =~ "White Player"
    end
  end

  describe "helper level (the default for a newly minted enrolment)" do
    test "may fill a board that is currently blank", %{conn: conn} do
      tournament = new_tournament()
      {white, black} = two_players(tournament)
      insert_round(tournament, 1, "playing", [{white, black, ""}])

      conn = enrolled_conn(conn, tournament)
      {:ok, lv, _html} = live(conn, ~p"/m/results")

      pairing = tournament.id |> Tournaments.get_round(1) |> Map.fetch!(:pairings) |> hd()

      render_click(lv, "set_result", %{"id" => to_string(pairing.id), "result" => "1-0"})

      assert Tournaments.get_round(tournament.id, 1).pairings
             |> Enum.find(&(&1.id == pairing.id))
             |> Map.fetch!(:result) == "1-0"
    end

    test "may NOT change a board that already carries a result", %{conn: conn} do
      tournament = new_tournament()
      {white, black} = two_players(tournament)
      insert_round(tournament, 1, "playing", [{white, black, "1-0"}])

      conn = enrolled_conn(conn, tournament)
      {:ok, lv, _html} = live(conn, ~p"/m/results")

      pairing = tournament.id |> Tournaments.get_round(1) |> Map.fetch!(:pairings) |> hd()

      html = render_click(lv, "set_result", %{"id" => to_string(pairing.id), "result" => "0-1"})

      assert html =~ "already has a result - only the arbiter can change it"

      assert Tournaments.get_round(tournament.id, 1).pairings
             |> Enum.find(&(&1.id == pairing.id))
             |> Map.fetch!(:result) == "1-0"
    end

    test "may not select an earlier round - via the event, not just the missing button", %{
      conn: conn
    } do
      tournament = new_tournament()
      {white, black} = two_players(tournament)
      insert_round(tournament, 1, "finished", [{white, black, "1-0"}])
      insert_round(tournament, 2, "playing", [{black, white, ""}])

      conn = enrolled_conn(conn, tournament)
      {:ok, lv, html} = live(conn, ~p"/m/results")

      # A helper has no round switcher at all, even with two rounds paired -
      # there is only one round it is ever allowed to be on.
      refute html =~ "mobile-round-btn"
      assert html =~ "Round 2"

      html = render_click(lv, "select_round", %{"number" => "1"})

      assert html =~ "Helpers can only view the current round"
      # Still on round 2 - the refused switch did not happen.
      assert html =~ "Round 2"

      # And round 1's already-entered result was not touched by any of this.
      round1_pairing = tournament.id |> Tournaments.get_round(1) |> Map.fetch!(:pairings) |> hd()
      assert round1_pairing.result == "1-0"
    end

    test "may not touch a board outside its range - via the event, not just hiding it", %{
      conn: conn
    } do
      tournament = new_tournament()
      {a, b} = two_players(tournament)

      {:ok, c} =
        Tournaments.create_player(tournament.id, %{"name" => "C Player", "fide_rating" => "1700"})

      {:ok, d} =
        Tournaments.create_player(tournament.id, %{"name" => "D Player", "fide_rating" => "1600"})

      insert_round(tournament, 1, "playing", [{a, b, ""}, {c, d, ""}])

      conn = enrolled_conn(conn, tournament, board_from: 1, board_to: 1)
      {:ok, lv, html} = live(conn, ~p"/m/results")

      assert html =~ "Board 1"
      refute html =~ "Board 2"

      board2 =
        tournament.id
        |> Tournaments.get_round(1)
        |> Map.fetch!(:pairings)
        |> Enum.find(&(&1.board == 2))

      html = render_click(lv, "set_result", %{"id" => to_string(board2.id), "result" => "1-0"})

      assert html =~ "outside the boards this phone is allowed to enter"

      assert Tournaments.get_round(tournament.id, 1).pairings
             |> Enum.find(&(&1.id == board2.id))
             |> Map.fetch!(:result) == ""
    end

    test "is moved to a newly paired round automatically, having no switcher of its own", %{
      conn: conn
    } do
      tournament = new_tournament()
      {white, black} = two_players(tournament)
      insert_round(tournament, 1, "playing", [{white, black, ""}])

      conn = enrolled_conn(conn, tournament)
      {:ok, lv, html} = live(conn, ~p"/m/results")
      assert html =~ "Round 1"

      insert_round(tournament, 2, "playing", [{black, white, ""}])
      Tournaments.broadcast_tournament_change(tournament.id, :rounds)

      assert render(lv) =~ "Round 2"
    end
  end

  describe "deputy level (today's original behaviour, preserved for a backfilled enrolment)" do
    test "may correct an existing result on an earlier round", %{conn: conn} do
      tournament = new_tournament()
      {white, black} = two_players(tournament)
      insert_round(tournament, 1, "finished", [{white, black, "1-0"}])
      insert_round(tournament, 2, "playing", [{black, white, ""}])

      # level: "deputy" is exactly what the backfill migration set on every
      # enrolment that existed before `level` did - this test is that
      # behaviour, exercised the same way a helper's is above.
      conn = enrolled_conn(conn, tournament, level: "deputy")
      {:ok, lv, html} = live(conn, ~p"/m/results")

      assert html =~ "mobile-round-btn"

      html = render_click(lv, "select_round", %{"number" => "1"})
      assert html =~ "Round 1"

      round1_pairing = tournament.id |> Tournaments.get_round(1) |> Map.fetch!(:pairings) |> hd()

      render_click(lv, "set_result", %{"id" => to_string(round1_pairing.id), "result" => "0-1"})

      assert Tournaments.get_round(tournament.id, 1).pairings
             |> Enum.find(&(&1.id == round1_pairing.id))
             |> Map.fetch!(:result) == "0-1"
    end

    test "board range still applies, same as for a helper", %{conn: conn} do
      tournament = new_tournament()
      {a, b} = two_players(tournament)

      {:ok, c} =
        Tournaments.create_player(tournament.id, %{"name" => "C Player", "fide_rating" => "1700"})

      {:ok, d} =
        Tournaments.create_player(tournament.id, %{"name" => "D Player", "fide_rating" => "1600"})

      insert_round(tournament, 1, "playing", [{a, b, ""}, {c, d, ""}])

      conn = enrolled_conn(conn, tournament, level: "deputy", board_from: 1, board_to: 1)
      {:ok, lv, html} = live(conn, ~p"/m/results")

      refute html =~ "Board 2"

      board2 =
        tournament.id
        |> Tournaments.get_round(1)
        |> Map.fetch!(:pairings)
        |> Enum.find(&(&1.board == 2))

      html = render_click(lv, "set_result", %{"id" => to_string(board2.id), "result" => "1-0"})
      assert html =~ "outside the boards this phone is allowed to enter"
    end
  end
end
