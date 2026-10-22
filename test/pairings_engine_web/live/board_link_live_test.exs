defmodule PairingsEngineWeb.BoardLinkLiveTest do
  @moduledoc """
  The arbiter's side of the board link: the Settings page that hands out
  codes, the column on the Pairings page that shows what a board saw, the
  page of one game, and the PGN downloads.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import PairingsEngine.AccountsFixtures
  import PairingsEngine.BoardLinkFixtures

  alias PairingsEngine.{BoardLink, Repo, TournamentGroups, Tournaments}
  alias PairingsEngine.BoardLink.Link
  alias PairingsEngine.Tournaments.Pairing

  setup :register_and_log_in_user

  setup %{scope: scope} do
    paired_tournament(scope)
  end

  describe "Settings, Live boards" do
    test "a new code is shown once, as text and as a QR code", %{conn: conn, tournament: t} do
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/boards")

      assert has_element?(lv, "#tournament-codes-none")
      refute has_element?(lv, "#tournament-codes-fresh")
      # No group, no group card.
      refute has_element?(lv, "#group-codes")

      lv |> element("#tournament-codes-new") |> render_click()

      assert has_element?(lv, "#tournament-codes-fresh")
      assert has_element?(lv, "#tournament-codes-qr svg")
      code = lv |> element("#tournament-codes-code") |> render()
      assert code =~ "/api/boards/v1#oplt_"

      [link] = Repo.all(Link)
      assert has_element?(lv, "#board-link-#{link.id}")
      assert has_element?(lv, "#board-link-seen-#{link.id}", "Never used")

      # Gone when dismissed, and not there for the next visitor.
      lv |> element("#tournament-codes-hide") |> render_click()
      refute has_element?(lv, "#tournament-codes-fresh")

      {:ok, lv, html} = live(conn, ~p"/t/#{t.id}/settings/boards")
      refute has_element?(lv, "#tournament-codes-fresh")
      refute html =~ "oplt_"
      assert has_element?(lv, "#board-link-#{link.id}")
    end

    test "the code on screen opens the API", %{conn: conn, tournament: t} do
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/boards")
      lv |> element("#tournament-codes-new") |> render_click()

      [_, secret] =
        Regex.run(~r/#(oplt_[A-Za-z0-9_-]+)/, lv |> element("#tournament-codes-code") |> render())

      assert {:ok, %Link{tournament_id: id}} = BoardLink.authenticate(secret)
      assert id == t.id
    end

    test "withdrawing a code", %{conn: conn, scope: scope, tournament: t} do
      {:ok, link, secret} = BoardLink.create_link(scope, t)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/boards")

      lv |> element("#board-link-revoke-#{link.id}") |> render_click()

      refute has_element?(lv, "#board-link-#{link.id}")
      assert :error = BoardLink.authenticate(secret)
    end

    test "a box that called is shown with its name, version and boards", %{
      conn: conn,
      scope: scope,
      tournament: t
    } do
      {:ok, link, _secret} = BoardLink.create_link(scope, t)
      link = BoardLink.touch(link, %{name: "Hall A", version: "0.4.0"})
      BoardLink.put_box_boards(link, %{t.id => 6})

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/boards")

      assert has_element?(lv, "#board-link-box-#{link.id}", "Hall A")
      assert has_element?(lv, "#board-link-box-#{link.id}", "0.4.0")
      assert has_element?(lv, "#board-link-seen-#{link.id}", "Connected")
      assert has_element?(lv, "#board-link-boards-#{link.id}", "6")
    end

    test "a tournament in a group can make a code for the group", %{
      conn: conn,
      scope: scope,
      tournament: t
    } do
      {:ok, _group} = TournamentGroups.create_group(scope, t, "The Event")
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/boards")

      assert has_element?(lv, "#group-codes")
      lv |> element("#group-codes-new") |> render_click()

      assert lv |> element("#group-codes-code") |> render() =~ "#oplg_"
      refute has_element?(lv, "#tournament-codes-fresh")
      assert [%Link{tournament_id: nil, group_id: group_id}] = Repo.all(Link)
      assert is_integer(group_id)
    end

    test "without publishing there is no relay key to ask for", %{conn: conn, tournament: t} do
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/boards")

      assert has_element?(lv, "#boards-no-target")
      refute has_element?(lv, "#relay-key-form")
      refute has_element?(lv, "#boards-live-toggle")
    end

    test "account-wide links that reach the tournament are listed, read-only",
         %{conn: conn, scope: scope, tournament: t} do
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/boards")
      refute has_element?(lv, "#account-codes")

      {:ok, link, _secret} = BoardLink.connect(scope, label: "Hall box")
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/boards")

      assert has_element?(lv, "#account-codes")
      assert has_element?(lv, "#account-code-#{link.id}", "Hall box")
      assert has_element?(lv, "#account-code-meta-#{link.id}", scope.user.email)
      assert has_element?(lv, "#account-code-meta-#{link.id}", "Never used")
      assert has_element?(lv, "#account-code-withdraw-#{link.id}[href='/users/settings']")
      refute has_element?(lv, "#board-link-#{link.id}")
    end

    test "an account link of somebody else has no withdraw link", %{
      conn: conn,
      scope: scope,
      tournament: t
    } do
      other = user_fixture()
      other_scope = PairingsEngine.Accounts.Scope.for_user(other)

      {:ok, _} =
        %PairingsEngine.Tournaments.Collaborator{}
        |> PairingsEngine.Tournaments.Collaborator.changeset(%{
          tournament_id: t.id,
          user_id: other.id,
          email: other.email,
          status: "accepted"
        })
        |> Repo.insert()

      {:ok, link, _secret} = BoardLink.connect(other_scope, label: "Their box")
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/boards")

      assert has_element?(lv, "#account-code-#{link.id}")
      assert has_element?(lv, "#account-code-other-#{link.id}")
      refute has_element?(lv, "#account-code-withdraw-#{link.id}")
      assert scope.user.id != other.id
    end

    test "somebody who may not open the tournament never sees account links", %{
      scope: scope,
      tournament: t
    } do
      {:ok, _link, _secret} = BoardLink.connect(scope, label: "Hall box")
      stranger = build_conn() |> log_in_user(user_fixture())

      assert_raise Ecto.NoResultsError, fn ->
        live(stranger, ~p"/t/#{t.id}/settings/boards")
      end
    end

    test "somebody who may not open the tournament gets nothing", %{tournament: t} do
      stranger = build_conn() |> log_in_user(user_fixture())

      assert_raise Ecto.NoResultsError, fn ->
        live(stranger, ~p"/t/#{t.id}/settings/boards")
      end

      assert_raise Ecto.NoResultsError, fn ->
        live(stranger, ~p"/t/#{t.id}/games/anything")
      end
    end

    test "signed out, the page is a log-in redirect", %{tournament: t} do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} =
               live(build_conn(), ~p"/t/#{t.id}/settings/boards")
    end

    test "an archived tournament offers no new code", %{conn: conn, tournament: t} do
      {:ok, _archived} = Tournaments.archive_tournament(t)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/boards")

      assert has_element?(lv, "#tournament-codes-new[disabled]")
      # And the event behind the button refuses too.
      render_click(lv, "new_code", %{"scope" => "tournament"})
      assert [] == Repo.all(Link)
    end

    test "the settings pages link to it", %{conn: conn, tournament: t} do
      {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/settings/about")
      assert html =~ ~s|href="/t/#{t.id}/settings/boards"|
    end
  end

  describe "the board column on the Pairings page" do
    setup %{scope: scope, tournament: t} do
      {:ok, link, _secret} = BoardLink.create_link(scope, t)
      %{link: link}
    end

    test "is not there for a tournament without boards", %{conn: conn, scope: scope} do
      plain = paired_tournament(scope, %{name: "No Boards"})
      {:ok, lv, _html} = live(conn, ~p"/t/#{plain.tournament.id}/pairings")

      refute has_element?(lv, "#board-column")
      refute has_element?(lv, ".pairing-boardlink")
    end

    test "is quiet where the board reported nothing", %{conn: conn, tournament: t, boards: boards} do
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

      assert has_element?(lv, "#board-column")

      for board <- boards do
        assert has_element?(lv, "#board-report-#{board.id}.none")
        refute has_element?(lv, "#board-report-#{board.id}.mismatch")
      end
    end

    test "shows what the board saw; quiet on a match, red on a mismatch", %{
      conn: conn,
      link: link,
      tournament: t,
      boards: [board1, board2]
    } do
      finished = %{"status" => "finished", "result" => "1-0"}
      {:ok, _} = BoardLink.report(link, t, report_for(board1, finished))
      {:ok, _} = BoardLink.report(link, t, report_for(board2, finished))
      {:ok, _} = Tournaments.update_pairing_result(board1, "1-0")
      {:ok, _} = Tournaments.update_pairing_result(board2, "0-1")

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

      assert has_element?(lv, "#board-report-#{board1.id}.match", "1-0")
      refute has_element?(lv, "#board-report-#{board1.id}.mismatch")

      assert has_element?(lv, "#board-report-#{board2.id}.mismatch", "1-0")
      assert has_element?(lv, "#board-report-#{board2.id}[data-state=mismatch]")

      assert lv |> element("#board-report-#{board2.id}") |> render() =~
               "The board saw 1-0, the result entered is 0-1"

      # Each is the way to the game.
      assert has_element?(
               lv,
               ~s|#board-report-#{board2.id}[href="/t/#{t.id}/games/#{board2.game_uid}"]|
             )
    end

    test "a report arriving while the page is open appears, and enters nothing", %{
      conn: conn,
      link: link,
      tournament: t,
      boards: [board1 | _]
    } do
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      assert has_element?(lv, "#board-report-#{board1.id}.none")

      {:ok, _} = BoardLink.report(link, t, report_for(board1))
      assert has_element?(lv, "#board-report-#{board1.id}.live", "playing")

      {:ok, _} =
        BoardLink.report(
          link,
          t,
          report_for(board1, %{"seq" => 2, "status" => "finished", "result" => "0-1"})
        )

      assert has_element?(lv, "#board-report-#{board1.id}.pending", "0-1")

      # The result select still says nothing was entered, because nothing was.
      assert has_element?(lv, ~s|#result-select-#{board1.id}[data-result=""]|)
      assert Repo.get!(Pairing, board1.id).result == ""
    end

    test "a mismatch does not stand in the way of the next round", %{
      conn: conn,
      link: link,
      tournament: t,
      boards: [board1, board2]
    } do
      {:ok, _} =
        BoardLink.report(
          link,
          t,
          report_for(board1, %{"status" => "finished", "result" => "1-0"})
        )

      {:ok, _} = Tournaments.update_pairing_result(board1, "0-1")
      {:ok, _} = Tournaments.update_pairing_result(board2, "1-0")

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      assert has_element?(lv, "#board-report-#{board1.id}.mismatch")

      # Round 2 is offered for pairing as if the board had said nothing.
      assert PairingsEngine.Pairing.round_complete?(t.id, 1)
      {:ok, next, _html} = live(conn, ~p"/t/#{t.id}/pairings?round=2")
      assert has_element?(next, "#pair-round")
      refute has_element?(next, "#pair-round[disabled]")
    end
  end

  describe "a game" do
    setup %{scope: scope, tournament: t, boards: [board1 | _]} do
      {:ok, link, _secret} = BoardLink.create_link(scope, t)

      {:ok, _} =
        BoardLink.report(
          link,
          t,
          report_for(board1, %{
            "status" => "finished",
            "result" => "1-0",
            "reconstructed" => 2,
            "guessed" => 1,
            "rewritten" => 3,
            "white_ms" => 3_600_000,
            "black_ms" => 59_000,
            "pgn" => "1. e4 e5 2. Nf3 1-0"
          })
        )

      :ok
    end

    test "the moves, both results and the PGN", %{conn: conn, tournament: t, boards: [board1 | _]} do
      {:ok, _} = Tournaments.update_pairing_result(board1, "0-1")
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/games/#{board1.game_uid}")

      assert has_element?(lv, "#board-game-title", "Player 1 - Player 2")
      assert has_element?(lv, "#board-game-arbiter", "0-1")
      assert has_element?(lv, "#board-game-board", "1-0")
      assert has_element?(lv, "#board-game-mismatch")
      assert has_element?(lv, "#board-game-moves", "Nf3")
      assert has_element?(lv, "#board-game-doubt")
      assert has_element?(lv, "#board-game-clocks", "1:00:00")

      pgn = lv |> element("#board-game-pgn") |> render()
      assert pgn =~ "1. e4 e5 2. Nf3 0-1"
      assert pgn =~ "[Result &quot;0-1&quot;]"

      assert has_element?(lv, "#board-game-download")
      assert has_element?(lv, "#board-game-download-box")
    end

    test "a game unpaired while it is open goes back to its round, and says why", %{
      conn: conn,
      tournament: t,
      boards: [board1 | _]
    } do
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/games/#{board1.game_uid}")
      number = Repo.preload(board1, :round).round.number
      :ok = PairingsEngine.Pairing.delete_round(t.id, number)

      {path, flash} = assert_redirect(lv)
      assert path == "/t/#{t.id}/pairings?round=#{number}"
      assert flash["error"] =~ "no longer in this tournament"
    end

    test "a game that is not in the tournament sends you back to the pairings", %{
      conn: conn,
      tournament: t
    } do
      assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/t/#{t.id}/games/nope")
      assert to == "/t/#{t.id}/pairings"
    end

    test "PGN downloads: one game, a round, the tournament, and the box's own", %{
      conn: conn,
      tournament: t,
      boards: [board1 | _]
    } do
      one = get(conn, ~p"/t/#{t.id}/export/pgn?moves=1&game=#{board1.game_uid}")
      body = response(one, 200)
      assert body =~ "1. e4 e5 2. Nf3 *"
      refute body =~ "Player 3"

      round = conn |> get(~p"/t/#{t.id}/export/pgn?moves=1&round=1") |> response(200)
      assert round =~ "1. e4 e5 2. Nf3 *"
      assert round =~ "Player 3"

      whole = conn |> get(~p"/t/#{t.id}/export/pgn?moves=1") |> response(200)
      assert whole == round

      box = conn |> get(~p"/t/#{t.id}/export/pgn?source=box&game=#{board1.game_uid}")
      assert response(box, 200) == "1. e4 e5 2. Nf3 1-0"

      # Without `moves=1` the export is the one it always was.
      plain = conn |> get(~p"/t/#{t.id}/export/pgn") |> response(200)
      refute plain =~ "e4"
    end
  end
end
