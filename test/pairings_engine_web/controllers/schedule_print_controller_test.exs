defmodule PairingsEngineWeb.SchedulePrintControllerTest do
  use PairingsEngineWeb.ConnCase

  alias PairingsEngine.{Pairing, Repo, RoundRobin, Tournaments}

  import PairingsEngine.TeamFixtures

  setup :register_and_log_in_user

  defp round_robin(scope, n, attrs \\ %{}) do
    {:ok, t} =
      Tournaments.create_tournament(
        scope,
        Map.merge(
          %{"name" => "Club RR", "type" => "roundrobin", "pairing_system" => "round_robin"},
          attrs
        )
      )

    for i <- 1..n do
      {:ok, _} =
        Tournaments.create_player(t.id, %{
          "name" => "Player #{i}",
          "fide_rating" => "#{2400 - i * 10}"
        })
    end

    Repo.reload!(t)
  end

  defp doc(html), do: LazyHTML.from_document(html)

  defp has?(html, selector), do: html |> doc() |> LazyHTML.query(selector) |> Enum.count() > 0

  defp text(html, selector),
    do: html |> doc() |> LazyHTML.query(selector) |> LazyHTML.text()

  # Round 1 paired, its first board won by White, its second postponed with
  # an agreed date.
  defp played_round_one(scope) do
    t = round_robin(scope, 4, %{"venue" => "Club hall"})
    {:ok, _} = Pairing.pair_next_round(t)
    [first, second] = Enum.sort_by(Tournaments.get_round(t.id, 1).pairings, & &1.board)
    {:ok, _} = Tournaments.update_pairing_result(first, "1-0")
    {:ok, _} = Tournaments.update_pairing_result(second, "*")
    {:ok, _} = Tournaments.set_agreed_date(Repo.reload!(second), ~D[2026-11-05])
    {Repo.reload!(t), first, second}
  end

  describe "GET /t/:id/print/schedule" do
    test "prints every round before anything is paired, marked provisional", %{
      conn: conn,
      scope: scope
    } do
      t = round_robin(scope, 4)
      html = conn |> get(~p"/t/#{t.id}/print/schedule") |> html_response(200)

      for n <- 1..3, do: assert(has?(html, "#sched-round-#{n}"))
      refute has?(html, "#sched-round-4")
      assert text(html, "#sched-note") =~ "Provisional"
      assert text(html, "#sched-round-3") =~ "not paired yet"
      assert text(html, "#sched-round-1") =~ "Player 1"
    end

    test "the round dates from Settings print beside each round", %{conn: conn, scope: scope} do
      t = round_robin(scope, 4)

      {:ok, t} =
        Tournaments.update_tournament(t, %{
          "round_dates" => ["2026-10-01", "2026-10-08", "2026-10-15"]
        })

      html = conn |> get(~p"/t/#{t.id}/print/schedule") |> html_response(200)
      assert text(html, "#sched-round-2 .sched-date") =~ "08-10-2026"
    end

    test "results and postponed dates by default; each can be left off", %{
      conn: conn,
      scope: scope
    } do
      {t, _first, _second} = played_round_one(scope)

      html = conn |> get(~p"/t/#{t.id}/print/schedule") |> html_response(200)
      round1 = text(html, "#sched-round-1")
      assert round1 =~ "1-0"
      assert round1 =~ "postponed to 05-11-2026 (Club hall)"
      assert text(html, "#sched-note") =~ "From round 2 on"

      blank = conn |> get(~p"/t/#{t.id}/print/schedule?results=0") |> html_response(200)
      refute text(blank, "#sched-round-1") =~ "1-0"
      # The agreed date is not a result: it stays on the wall schedule.
      assert text(blank, "#sched-round-1") =~ "postponed to 05-11-2026"

      bare = conn |> get(~p"/t/#{t.id}/print/schedule?postponed=0") |> html_response(200)
      refute text(bare, "#sched-round-1") =~ "postponed to"
      assert text(bare, "#sched-round-1") =~ "*"
    end

    test "an odd field prints each round's bye", %{conn: conn, scope: scope} do
      t = round_robin(scope, 5)
      html = conn |> get(~p"/t/#{t.id}/print/schedule") |> html_response(200)

      for n <- 1..5, do: assert(has?(html, "#sched-round-#{n} .sched-bye"))
    end

    test "a double round robin prints both cycles", %{conn: conn, scope: scope} do
      t = round_robin(scope, 4, %{"rr_cycles" => "2"})
      html = conn |> get(~p"/t/#{t.id}/print/schedule") |> html_response(200)
      assert has?(html, "#sched-round-6")
      refute has?(html, "#sched-round-7")
    end

    test "fully paired, no note", %{conn: conn, scope: scope} do
      t = round_robin(scope, 4)
      {:ok, _} = RoundRobin.pair_all_rounds(t)
      html = conn |> get(~p"/t/#{t.id}/print/schedule") |> html_response(200)
      refute has?(html, "#sched-note")
      refute html =~ "not paired yet"
    end

    test "a Swiss has no schedule to print", %{conn: conn, scope: scope} do
      {:ok, t} = Tournaments.create_tournament(scope, %{"name" => "Swiss", "type" => "swiss"})
      assert conn |> get(~p"/t/#{t.id}/print/schedule") |> html_response(404)
    end

    test "printed in the app's language", %{conn: conn, scope: scope} do
      {t, _first, _second} = played_round_one(scope)
      conn = get(conn, ~p"/locale/nl?redirect_to=/")
      html = conn |> get(~p"/t/#{t.id}/print/schedule") |> html_response(200)

      assert html =~ "Schema - alle rondes"
      assert text(html, "#sched-round-1") =~ "uitgesteld naar 05-11-2026"
      assert text(html, "#sched-round-2") =~ "nog niet gepaard"
    end

    test "one player is too few", %{conn: conn, scope: scope} do
      t = round_robin(scope, 1)
      assert conn |> get(~p"/t/#{t.id}/print/schedule") |> html_response(409)
    end
  end

  describe "player cards" do
    test "a round robin's cards are filled in for every round before anything is paired", %{
      conn: conn,
      scope: scope
    } do
      t = round_robin(scope, 4)
      p1 = Enum.find(Tournaments.list_players(t.id), &(&1.name == "Player 1"))

      html = conn |> get(~p"/t/#{t.id}/print/cards") |> html_response(200)
      card = text(html, "#player-card-#{p1.id}")
      # Player 1 meets the other three, one a round.
      for other <- ["Player 2", "Player 3", "Player 4"], do: assert(card =~ other)

      blank = conn |> get(~p"/t/#{t.id}/print/cards?blank=1") |> html_response(200)
      assert has?(blank, "#player-card-#{p1.id}")
      refute text(blank, "#player-card-#{p1.id}") =~ "Player 2"
    end

    test "results, running score and the agreed date of a postponed game", %{
      conn: conn,
      scope: scope
    } do
      {t, first, second} = played_round_one(scope)

      html = conn |> get(~p"/t/#{t.id}/print/card/#{first.white_player_id}") |> html_response(200)
      card = text(html, "#player-card-#{first.white_player_id}")
      assert card =~ "Player"
      assert html =~ ~s(<td class="res">1</td><td class="num">1</td>)

      postponed =
        conn |> get(~p"/t/#{t.id}/print/card/#{second.white_player_id}") |> html_response(200)

      assert text(postponed, "#player-card-#{second.white_player_id}") =~
               "postponed to 05-11-2026"

      plain =
        conn
        |> get(~p"/t/#{t.id}/print/card/#{first.white_player_id}?results=0")
        |> html_response(200)

      refute plain =~ ~s(<td class="res">1</td>)
    end

    test "a Swiss card has its played rounds, the rest to fill in", %{conn: conn, scope: scope} do
      {:ok, t} =
        Tournaments.create_tournament(scope, %{
          "name" => "Swiss",
          "type" => "swiss",
          "rounds_count" => "3"
        })

      for i <- 1..4,
          do:
            {:ok, _} =
              Tournaments.create_player(t.id, %{"name" => "S#{i}", "fide_rating" => "#{2000 - i}"})

      {:ok, _} = Pairing.pair_next_round(Repo.reload!(t))
      board = hd(Tournaments.get_round(t.id, 1).pairings)

      html = conn |> get(~p"/t/#{t.id}/print/cards") |> html_response(200)
      card = text(html, "#player-card-#{board.white_player_id}")
      assert card =~ board.black_player.name
      # Three rows, rounds 2 and 3 empty.
      rows =
        html
        |> doc()
        |> LazyHTML.query("#player-card-#{board.white_player_id} tbody tr")
        |> Enum.count()

      assert rows == 3
    end
  end

  describe "team round robin" do
    setup %{scope: scope} do
      {t, teams} =
        team_round_robin(
          for(i <- 1..3, do: {"Team #{i}", [2100 - i * 10, 2000 - i * 10]}),
          user_id: scope.user.id
        )

      %{t: t, teams: teams}
    end

    test "the schedule prints every match with its boards", %{conn: conn, t: t} do
      html = conn |> get(~p"/t/#{t.id}/print/team-schedule") |> html_response(200)
      for n <- 1..3, do: assert(has?(html, "#sched-round-#{n}"))
      assert text(html, "#sched-round-1") =~ "Team 1"
      assert has?(html, "#sched-round-1 table")
      # Three teams: one sits out each round.
      assert text(html, "#sched-round-1 .sched-bye") =~ "does not play this round"

      no_boards = conn |> get(~p"/t/#{t.id}/print/team-schedule?boards=0") |> html_response(200)
      refute has?(no_boards, "#sched-round-1 table")

      # The individual route sends a team event to the team version.
      routed = conn |> get(~p"/t/#{t.id}/print/schedule") |> html_response(200)
      assert has?(routed, "#sched-round-1 .sched-match")
    end

    test "results and the match score once played", %{conn: conn, t: t} do
      t = pair_all!(t)
      round = Tournaments.get_round(t.id, 1)

      for p <- round.pairings,
          p.white_player_id && p.black_player_id,
          do: {:ok, _} = Tournaments.update_pairing_result(p, "1-0")

      html = conn |> get(~p"/t/#{t.id}/print/team-schedule") |> html_response(200)
      assert text(html, "#sched-round-1") =~ "(1 - 1)"
      refute has?(html, "#sched-note")
    end

    test "team schedules: all teams, or one", %{conn: conn, t: t, teams: [t1, t2 | _]} do
      html = conn |> get(~p"/t/#{t.id}/print/team-cards") |> html_response(200)
      assert has?(html, "#team-card-#{t1.id}")
      assert has?(html, "#team-card-#{t2.id}")
      assert text(html, "#team-card-#{t1.id}") =~ "Team 2"

      one = conn |> get(~p"/t/#{t.id}/print/team-cards?team=#{t2.id}") |> html_response(200)
      refute has?(one, "#team-card-#{t1.id}")
      assert has?(one, "#team-card-#{t2.id}")

      assert conn |> get(~p"/t/#{t.id}/print/team-cards?team=0") |> html_response(404)
    end

    test "a player's card shows the team's opponent, board and colour", %{conn: conn, t: t} do
      player = Enum.find(Tournaments.list_players(t.id), &(&1.name == "Team 1 1"))
      html = conn |> get(~p"/t/#{t.id}/print/card/#{player.id}") |> html_response(200)
      card = text(html, "#player-card-#{player.id}")
      assert card =~ "Team: Team 1"
      assert card =~ "Team 2"
      assert card =~ "Team 3"
      assert card =~ "White" or card =~ "Black"
    end

    test "a team schedule is only for a team round robin", %{conn: conn, scope: scope} do
      t = round_robin(scope, 4)
      assert conn |> get(~p"/t/#{t.id}/print/team-schedule") |> html_response(404)
      assert conn |> get(~p"/t/#{t.id}/print/team-cards") |> html_response(404)
    end
  end
end
