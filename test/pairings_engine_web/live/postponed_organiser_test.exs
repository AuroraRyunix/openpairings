defmodule PairingsEngineWeb.PostponedOrganiserTest do
  @moduledoc """
  Postponed games from the organiser's side: the pending marks on the
  standings, the pair confirmation that names the players, the guard before
  anything reads as the end of the event, the Players page card, the agreed
  date with its history, the notices and calendar file, the rating-period
  note on the Export page, and team matches with a board still to play.
  """
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest
  import PairingsEngine.TeamFixtures

  alias PairingsEngine.{Audit, PostponedCalendar, PostponedGames, Repo, Snapshot, Tournaments}
  alias PairingsEngine.Pairing, as: Engine

  setup :register_and_log_in_user

  # Complete setup, four players, round 1 paired, postponed games allowed.
  defp tournament(scope) do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "Club championship",
        "type" => "swiss",
        "start_date" => "2026-09-01",
        "rounds_count" => "3",
        "round_dates" => ["2026-09-01", "2026-09-08", "2026-09-15"],
        "tiebreaks" => ["BH", "SB"],
        "venue" => "Club house",
        "city" => "Ghent",
        "postponed_games" => "true"
      })

    for {name, rating} <- [{"Alice", 2000}, {"Bob", 1900}, {"Carol", 1800}, {"Dave", 1700}] do
      {:ok, _} = Tournaments.create_player(t.id, %{"name" => name, "fide_rating" => "#{rating}"})
    end

    {:ok, _} = Engine.pair_next_round(t)
    Tournaments.get_tournament!(t.id)
  end

  # Round 1 with its first board postponed and the other one won by White.
  defp with_postponed(scope) do
    t = tournament(scope)
    [postponed, other] = Tournaments.get_round(t.id, 1).pairings
    {:ok, _} = Tournaments.update_pairing_result(postponed, "*")
    {:ok, _} = Tournaments.update_pairing_result(other, "1-0")
    {t, Repo.preload(Repo.reload!(postponed), [:white_player, :black_player])}
  end

  defp play!(pairing, result) do
    {:ok, _} =
      Tournaments.update_pairing_result(Repo.reload!(pairing), result,
        acknowledged: [:adjourned_non_draw_result, :finalised_result_changed]
      )
  end

  describe "the standings mark who still has a game to play" do
    test "on the page, beside both players, until it is played", %{conn: conn, scope: scope} do
      {t, game} = with_postponed(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/standings")
      assert has_element?(lv, "#pending-#{game.white_player_id}", "1 pending")
      assert has_element?(lv, "#pending-#{game.black_player_id}")
      assert has_element?(lv, ".pending-chip", "1 pending")

      play!(game, "1/2-1/2")
      render(lv)

      refute has_element?(lv, "#pending-#{game.white_player_id}")
      refute has_element?(lv, ".pending-chip")
    end

    test "on the printed standings", %{conn: conn, scope: scope} do
      {t, game} = with_postponed(scope)

      marks = fn ->
        conn
        |> get(~p"/t/#{t.id}/print/standings")
        |> html_response(200)
        |> LazyHTML.from_document()
        |> LazyHTML.query(".pending")
        |> Enum.count()
      end

      assert marks.() == 2

      play!(game, "1-0")
      assert marks.() == 0
    end
  end

  describe "the end-of-event guard" do
    test "the Print page counts the unplayed games and links each to its round", %{
      conn: conn,
      scope: scope
    } do
      {t, game} = with_postponed(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/print")

      assert has_element?(lv, "#print-postponed-unplayed", "1 postponed game still unplayed")

      assert has_element?(
               lv,
               "#print-postponed-unplayed-game-#{game.id}[href='/t/#{t.id}/pairings?round=1']"
             )

      assert has_element?(lv, "#print-postponed-notices")

      play!(game, "1/2-1/2")
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/print")
      refute has_element?(lv, "#print-postponed-unplayed")
      refute has_element?(lv, "#print-postponed-notices")
    end

    test "the Standings page lists the games under its not-final banner", %{
      conn: conn,
      scope: scope
    } do
      {t, game} = with_postponed(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/standings")
      assert has_element?(lv, "#postponed-not-final-game-#{game.id}")
    end

    test "archiving says how many are unplayed first", %{conn: conn, scope: scope} do
      {t, _game} = with_postponed(scope)

      {:ok, lv, _html} = live(conn, ~p"/")

      assert has_element?(
               lv,
               "#archive-#{t.id}[data-confirm*='1 postponed game is still unplayed']"
             )

      assert has_element?(lv, "#tournament-pending-#{t.id}", "1 pending")
    end

    test "archiving a tournament with nothing open asks as before", %{conn: conn, scope: scope} do
      t = tournament(scope)

      {:ok, lv, _html} = live(conn, ~p"/")
      assert has_element?(lv, "#archive-#{t.id}[data-confirm^='Archive']")
      refute has_element?(lv, "#tournament-pending-#{t.id}")
    end
  end

  describe "the Players page card" do
    test "lists each open game with its round, players and agreed date", %{
      conn: conn,
      scope: scope
    } do
      {t, game} = with_postponed(scope)
      {:ok, _} = Tournaments.set_agreed_date(game, ~D[2026-10-05], scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/players")

      assert has_element?(lv, "#postponed-overview #postponed-overview-#{game.id}", "05-10-2026")
      assert has_element?(lv, "#postponed-overview-#{game.id}", game.white_player.name)

      assert has_element?(
               lv,
               "#postponed-overview-#{game.id} a[href='/t/#{t.id}/pairings?round=1']"
             )

      play!(game, "1/2-1/2")
      render(lv)
      refute has_element?(lv, "#postponed-overview")
    end

    test "is not there when nothing is postponed", %{conn: conn, scope: scope} do
      t = tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/players")
      refute has_element?(lv, "#postponed-overview")
    end

    test "its link opens the Pairings page on that round", %{conn: conn, scope: scope} do
      {t, game} = with_postponed(scope)
      {:ok, _} = Engine.pair_next_round(Tournaments.get_tournament!(t.id))

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings?round=1")
      assert has_element?(lv, "#pairing-row-#{game.id}")
    end
  end

  describe "the agreed date and its history" do
    test "is set, moved and cleared from the Pairings page, with who and when", %{
      conn: conn,
      scope: scope
    } do
      {t, game} = with_postponed(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

      assert has_element?(lv, "#postponed-agreed-#{game.id}", "no date agreed yet")
      refute has_element?(lv, "#postponed-ics-#{game.id}")

      submit = fn date ->
        lv
        |> element("#agreed-date-form-#{game.id}")
        |> render_submit(%{"pairing-id" => "#{game.id}", "agreed_date" => date})
      end

      submit.("2026-10-05")
      assert Repo.reload!(game).agreed_date == ~D[2026-10-05]
      assert has_element?(lv, "#postponed-agreed-#{game.id}", "05-10-2026")
      assert has_element?(lv, "#postponed-ics-#{game.id}")

      submit.("2026-10-12")
      submit.("")

      pairing = Repo.reload!(game)
      assert pairing.agreed_date == nil

      assert [
               %{"from" => nil, "to" => "2026-10-05"},
               %{"from" => "2026-10-05", "to" => "2026-10-12"},
               %{"from" => "2026-10-12", "to" => nil}
             ] = pairing.agreed_date_log

      assert Enum.all?(pairing.agreed_date_log, &(&1["by"] == scope.user.email))

      assert has_element?(lv, "#agreed-date-log-#{game.id}", "Date changed 3 times")
      assert has_element?(lv, "#agreed-date-log-#{game.id}", "05-10-2026 → 12-10-2026")
      assert has_element?(lv, "#agreed-date-log-#{game.id}", scope.user.email)

      actions = t.id |> Audit.list_for_tournament() |> Enum.map(& &1.action)
      assert Enum.count(actions, &(&1 == "pairing.postponed_date_set")) == 3
    end

    test "saving the same date again logs nothing", %{scope: scope} do
      {_t, game} = with_postponed(scope)
      {:ok, _} = Tournaments.set_agreed_date(game, ~D[2026-10-05], scope)
      {:ok, _} = Tournaments.set_agreed_date(game, ~D[2026-10-05], scope)

      assert length(Repo.reload!(game).agreed_date_log) == 1
    end

    test "is refused once the game is played", %{scope: scope} do
      {_t, game} = with_postponed(scope)
      play!(game, "1/2-1/2")

      assert {:error, :not_open_postponed_game} =
               Tournaments.set_agreed_date(game, ~D[2026-10-05], scope)
    end

    test "survives a backup and restore", %{scope: scope} do
      {t, game} = with_postponed(scope)
      {:ok, _} = Tournaments.set_agreed_date(game, ~D[2026-10-05], scope)

      envelope =
        PairingsEngine.TournamentExport.export_tournament(Tournaments.get_tournament!(t.id))

      {:ok, [copy]} = PairingsEngine.TournamentImport.import(envelope, scope)

      [restored] = PostponedGames.open_games(copy)
      assert restored.pairing.agreed_date == ~D[2026-10-05]
      assert [%{"to" => "2026-10-05"}] = restored.pairing.agreed_date_log
    end

    test "travels to OpenResults beside the postponed flag", %{scope: scope} do
      {t, game} = with_postponed(scope)
      {:ok, _} = Tournaments.set_agreed_date(game, ~D[2026-10-05], scope)

      Tournaments.get_tournament!(t.id)
      |> Ecto.Changeset.change(publish_mode: "immediate")
      |> Repo.update!()

      snapshot = Snapshot.build(Tournaments.get_tournament!(t.id))
      [round] = snapshot["rounds"]
      board = Enum.find(round["boards"], &(&1["board"] == game.board))
      other = Enum.find(round["boards"], &(&1["board"] != game.board))

      assert board["postponed"] == true
      assert board["postponed_date"] == "2026-10-05"
      refute Map.has_key?(other, "postponed_date")
    end
  end

  describe "the player notice and calendar file" do
    test "prints a notice for each player with opponent, date and venue", %{
      conn: conn,
      scope: scope
    } do
      {t, game} = with_postponed(scope)
      {:ok, _} = Tournaments.set_agreed_date(game, ~D[2026-10-05], scope)

      doc =
        conn
        |> get(~p"/t/#{t.id}/print/postponed?#{[game: game.id]}")
        |> html_response(200)
        |> LazyHTML.from_document()

      white_notice = LazyHTML.query(doc, "#notice-#{game.id}-#{game.white_player_id}")
      black_notice = LazyHTML.query(doc, "#notice-#{game.id}-#{game.black_player_id}")

      assert Enum.count(white_notice) == 1
      assert Enum.count(black_notice) == 1

      text = LazyHTML.text(white_notice)
      assert text =~ game.black_player.name
      assert text =~ "05-10-2026"
      assert text =~ "Club house, Ghent"
    end

    test "all open games print together; an unknown game is a 404", %{conn: conn, scope: scope} do
      {t, game} = with_postponed(scope)

      html = conn |> get(~p"/t/#{t.id}/print/postponed") |> html_response(200)
      assert html =~ "notice-#{game.id}-#{game.white_player_id}"
      assert html =~ "still to be agreed with the arbiter"

      assert conn |> get(~p"/t/#{t.id}/print/postponed?#{[game: 0]}") |> response(404)
    end

    test "the calendar file is an all-day event on the agreed date", %{conn: conn, scope: scope} do
      {t, game} = with_postponed(scope)

      assert conn
             |> get(~p"/t/#{t.id}/export/postponed/#{game.id}/calendar")
             |> response(404)

      {:ok, _} = Tournaments.set_agreed_date(game, ~D[2026-10-05], scope)

      resp = get(conn, ~p"/t/#{t.id}/export/postponed/#{game.id}/calendar")
      body = response(resp, 200)

      assert ["text/calendar" <> _] = get_resp_header(resp, "content-type")
      assert body =~ "BEGIN:VCALENDAR\r\n"
      assert body =~ "DTSTART;VALUE=DATE:20261005\r\n"
      assert body =~ "DTEND;VALUE=DATE:20261006\r\n"
      assert body =~ "LOCATION:Club house\\, Ghent\r\n"
      assert body =~ game.white_player.name
    end

    test "long lines are folded and text escaped" do
      ics =
        PostponedCalendar.ics(
          ~D[2026-10-05],
          "uid-1",
          String.duplicate("é", 60),
          "a; b, c\nd",
          nil
        )

      assert ics =~ "DESCRIPTION:a\\; b\\, c\\nd\r\n"
      refute ics =~ "LOCATION"

      for line <- String.split(ics, "\r\n"), do: assert(byte_size(line) <= 75)
    end
  end

  describe "the rating-period note on the Export page" do
    test "names the month a late game was played in and the end of it", %{
      conn: conn,
      scope: scope
    } do
      {t, game} = with_postponed(scope)
      post(conn, ~p"/t/#{t.id}/export/trf", %{"rounds" => "1", "finalise" => "true"})
      play!(game, "0-1")
      {:ok, _} = Tournaments.set_played_on(Repo.reload!(game), ~D[2026-10-14])

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/export")

      assert has_element?(lv, "#postponed-rating-periods #rating-period-2026-10", "October 2026")
      assert has_element?(lv, "#rating-period-2026-10", "31-10-2026")
    end

    test "is not shown while nothing waits for the postponed-games file", %{
      conn: conn,
      scope: scope
    } do
      {t, _game} = with_postponed(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/export")
      refute has_element?(lv, "#postponed-rating-periods")
    end

    test "the period is the calendar month, the deadline its last day" do
      assert PostponedGames.rating_period(~D[2026-02-10]) ==
               %{period: ~D[2026-02-01], deadline: ~D[2026-02-28]}
    end
  end

  describe "team matches with a postponed board" do
    defp team_event(scope) do
      {t, _teams} =
        team_swiss(
          [
            {"Alpha", [2200, 2100]},
            {"Beta", [2000, 1900]},
            {"Gamma", [1800, 1700]},
            {"Delta", [1600, 1500]}
          ],
          rounds: 3,
          postponed_games: true,
          user_id: scope.user.id,
          start_date: "2026-09-01",
          round_dates: ["2026-09-01", "2026-09-08", "2026-09-15"]
        )

      pair_next!(t)
      [first, second] = t |> PairingsEngine.TeamStandings.matches() |> Enum.reject(& &1.bye?)
      [row1, row2] = first.boards
      {:ok, _} = Tournaments.update_pairing_result(row1.pairing, "*")
      {:ok, _} = Tournaments.update_pairing_result(row2.pairing, "1-0")
      for %{pairing: p} <- second.boards, do: Tournaments.update_pairing_result(p, "1/2-1/2")
      {t, first, second}
    end

    test "read as pending on the Pairings page and the team standings", %{
      conn: conn,
      scope: scope
    } do
      {t, first, second} = team_event(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      assert has_element?(lv, "#match-pending-#{first.match_id}", "1 board pending")
      refute has_element?(lv, "#match-pending-#{second.match_id}")
      assert has_element?(lv, "#match-provisional-#{first.match_id}", "provisional")

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/standings")
      assert has_element?(lv, "#team-pending-#{first.team_a_id}", "1 board pending")
      assert has_element?(lv, "#team-pending-#{first.team_b_id}", "1 board pending")
      refute has_element?(lv, "#team-pending-#{second.team_a_id}")
    end

    test "the provisional match points still count, as they did", %{scope: scope} do
      {t, first, _second} = team_event(scope)

      t = Repo.reload!(t)
      entries = PairingsEngine.TeamStandings.standings(t)
      a = Enum.find(entries, &(&1.team.id == first.team_a_id))
      b = Enum.find(entries, &(&1.team.id == first.team_b_id))

      # One board won, one postponed and counted as a draw: 1.5 - 0.5, so
      # the match is decided provisionally and its match points count.
      assert a.pending_boards == 1
      assert b.pending_boards == 1
      assert a.mp + b.mp == t.team_match_points_win + t.team_match_points_loss
    end

    test "print as pending on the team pairing sheet and team standings", %{
      conn: conn,
      scope: scope
    } do
      {t, _first, _second} = team_event(scope)

      assert conn |> get(~p"/t/#{t.id}/print/team-pairings?round=1") |> html_response(200) =~
               "1 board pending"

      assert conn |> get(~p"/t/#{t.id}/print/team-standings") |> html_response(200) =~
               "(1 board pending)"
    end
  end
end
