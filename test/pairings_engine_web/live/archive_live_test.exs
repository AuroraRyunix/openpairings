defmodule PairingsEngineWeb.ArchiveLiveTest do
  @moduledoc """
  The archive UI: the Tournaments-page panel and actions, and the read-only
  treatment inside an archived tournament.
  """
  # async: false: sequential SQLite writes plus self-broadcast/render ordering.
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Accounts, Repo, Tournaments}
  alias PairingsEngine.Accounts.User
  alias PairingsEngine.Tournaments.{Pairing, Player, Round}

  setup :register_and_log_in_user

  defp create_tournament(scope, attrs \\ %{}) do
    {:ok, tournament} =
      Tournaments.create_tournament(
        scope,
        Map.merge(%{"name" => "Archive UI Test", "type" => "swiss", "rounds_count" => "3"}, attrs)
      )

    tournament
  end

  # Same pattern as PairingsEngineWeb.SharingTest's `collaborator_conn/2` -
  # a fresh, already-accepted collaborator with their own logged-in conn.
  defp collaborator_conn(tournament, scope) do
    other_user =
      Repo.insert!(%User{
        email: "collab#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    other_scope = Accounts.Scope.for_user(other_user)
    {:ok, invite} = Tournaments.add_collaborator(scope, tournament, other_user.email)
    {:ok, _accepted} = Tournaments.accept_invitation(other_scope, invite.invite_token)

    Phoenix.ConnTest.build_conn() |> log_in_user(other_user)
  end

  describe "Tournaments page - archiving" do
    test "an Archive button is offered for an owned tournament", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "Archive"
      assert html =~ tournament.name
    end

    test "clicking Archive moves it out of the main list and into the Archived panel", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)

      {:ok, lv, html} = live(conn, ~p"/")
      refute html =~ "<h2>Archived</h2>"

      html =
        lv
        |> element(~s(button[phx-click="archive_tournament"][phx-value-id="#{tournament.id}"]))
        |> render_click()

      assert html =~ "<h2>Archived</h2>"
      assert html =~ "archived"
      assert Repo.reload!(tournament).archived_at
    end

    test "Unarchive brings it back to the main list", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, _} = Tournaments.archive_tournament(tournament)

      {:ok, lv, html} = live(conn, ~p"/")
      assert html =~ "<h2>Archived</h2>"

      html =
        lv
        |> element(~s(button[phx-click="unarchive_tournament"][phx-value-id="#{tournament.id}"]))
        |> render_click()

      refute html =~ "<h2>Archived</h2>"
      refute Repo.reload!(tournament).archived_at
    end

    test "the Archived panel is absent entirely when nothing is archived", %{
      conn: conn,
      scope: scope
    } do
      create_tournament(scope)

      {:ok, _lv, html} = live(conn, ~p"/")

      refute html =~ "<h2>Archived</h2>"
    end

    test "the archive panel is separate from the recycle bin, and says so", %{
      conn: conn,
      scope: scope
    } do
      archived = create_tournament(scope, %{"name" => "Archived One"})
      binned = create_tournament(scope, %{"name" => "Binned One"})
      {:ok, _} = Tournaments.archive_tournament(archived)
      {:ok, _} = Tournaments.soft_delete_tournament(binned)

      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "<h2>Archived</h2>"
      assert html =~ "<h2>Recycle bin</h2>"
      assert html =~ "nothing here is ever purged automatically"
    end

    test "archiving is audit-logged", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, lv, _html} = live(conn, ~p"/")

      lv
      |> element(~s(button[phx-click="archive_tournament"][phx-value-id="#{tournament.id}"]))
      |> render_click()

      actions =
        tournament.id
        |> PairingsEngine.Audit.list_for_tournament()
        |> Enum.map(& &1.action)

      assert "tournament.archived" in actions
    end
  end

  describe "a collaborator can archive/unarchive a shared tournament too" do
    test "an Archive button is offered on a shared (not owned) tournament", %{scope: scope} do
      tournament = create_tournament(scope)
      collaborator_conn = collaborator_conn(tournament, scope)

      {:ok, _lv, html} = live(collaborator_conn, ~p"/")

      assert html =~ ~s(phx-click="archive_tournament")
      assert html =~ tournament.name
      # Delete stays owner-only even for a row the collaborator can archive.
      refute html =~
               ~s(button class="pe-btn danger-link" phx-click="delete_start" phx-value-id="#{tournament.id}")
    end

    test "a collaborator clicking Archive actually archives it", %{scope: scope} do
      tournament = create_tournament(scope)
      collaborator_conn = collaborator_conn(tournament, scope)

      {:ok, lv, _html} = live(collaborator_conn, ~p"/")

      html =
        lv
        |> element(~s(button[phx-click="archive_tournament"][phx-value-id="#{tournament.id}"]))
        |> render_click()

      assert html =~ "<h2>Archived</h2>"
      assert Repo.reload!(tournament).archived_at
    end

    test "the archived tournament still shows up for the collaborator, marked shared, with Unarchive and Leave (not Delete)",
         %{scope: scope} do
      tournament = create_tournament(scope)
      collaborator_conn = collaborator_conn(tournament, scope)
      {:ok, _} = Tournaments.archive_tournament(tournament)

      {:ok, _lv, html} = live(collaborator_conn, ~p"/")

      assert html =~ "<h2>Archived</h2>"
      assert html =~ "shared"
      assert html =~ ~s(phx-click="unarchive_tournament")
      assert html =~ ~s(phx-click="leave_tournament")
    end

    test "a collaborator can unarchive it", %{scope: scope} do
      tournament = create_tournament(scope)
      collaborator_conn = collaborator_conn(tournament, scope)
      {:ok, _} = Tournaments.archive_tournament(tournament)

      {:ok, lv, _html} = live(collaborator_conn, ~p"/")

      html =
        lv
        |> element(~s(button[phx-click="unarchive_tournament"][phx-value-id="#{tournament.id}"]))
        |> render_click()

      refute html =~ "<h2>Archived</h2>"
      refute Repo.reload!(tournament).archived_at
    end

    test "a stranger with no access at all cannot archive it via a crafted event", %{
      conn: _conn,
      scope: scope
    } do
      tournament = create_tournament(scope)

      stranger =
        Repo.insert!(%User{
          email: "stranger#{System.unique_integer([:positive])}@example.com",
          confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
        })

      stranger_conn = Phoenix.ConnTest.build_conn() |> log_in_user(stranger)

      {:ok, lv, _html} = live(stranger_conn, ~p"/")

      html =
        render_click(lv, "archive_tournament", %{"id" => to_string(tournament.id)})

      assert html =~ "Tournament not found."
      refute Repo.reload!(tournament).archived_at
    end
  end

  describe "inside an archived tournament" do
    test "every page carries the read-only banner", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, _} = Tournaments.archive_tournament(tournament)

      for path <- [
            ~p"/t/#{tournament.id}/players",
            ~p"/t/#{tournament.id}/pairings",
            ~p"/t/#{tournament.id}/standings",
            ~p"/t/#{tournament.id}/settings"
          ] do
        {:ok, _lv, html} = live(conn, path)
        assert html =~ "This tournament is archived", "expected the banner on #{path}"
        assert html =~ "archived-banner"
      end
    end

    test "a live tournament carries no banner", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/players")

      refute html =~ "archived-banner"
    end

    test "the Pairings page hides the pair button", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, _} = Tournaments.create_player(tournament.id, %{"name" => "Alice"})
      {:ok, _} = Tournaments.create_player(tournament.id, %{"name" => "Bob"})

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/pairings")
      assert html =~ ~s(phx-click="pair")

      {:ok, _} = Tournaments.archive_tournament(tournament)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/pairings")
      refute html =~ ~s(phx-click="pair")
    end

    test "the Standings page hides the manual-ranking controls", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, _} = Tournaments.create_player(tournament.id, %{"name" => "Alice"})

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/standings")
      assert html =~ "Enable manual ranking"

      {:ok, _} = Tournaments.archive_tournament(tournament)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/standings")
      refute html =~ "Enable manual ranking"
    end

    test "a settings save is refused rather than silently applied", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, _} = Tournaments.archive_tournament(tournament)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/settings")

      lv
      |> form("form[phx-submit=save]", %{"tournament" => %{"venue" => "Some Hall"}})
      |> render_submit()

      assert Repo.reload!(tournament).venue == ""
    end

    test "a manual-ranking event queued from a stale tab flashes instead of crashing", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      {:ok, _} = Tournaments.create_player(tournament.id, %{"name" => "Alice"})

      # Open the page while still live, so the controls are present...
      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/standings")

      # ...then archive underneath it and fire the event anyway.
      {:ok, _} = Tournaments.archive_tournament(tournament)

      html = render_click(lv, "enable_manual_ranking", %{})

      assert html =~ "archived"
      refute Repo.reload!(tournament).manual_ranking
    end
  end

  describe "the Pairings page's result select is properly disabled while archived (the reported bug)" do
    defp paired_tournament(scope) do
      tournament = create_tournament(scope, %{"rounds_count" => "1"})
      a = Repo.insert!(%Player{tournament_id: tournament.id, name: "Alice"})
      b = Repo.insert!(%Player{tournament_id: tournament.id, name: "Bob"})
      round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "playing"})

      pairing =
        Repo.insert!(%Pairing{
          round_id: round.id,
          board: 1,
          white_player_id: a.id,
          black_player_id: b.id,
          result: ""
        })

      :ok = Tournaments.freeze_round_display_boards!(round.id)
      %{tournament: tournament, pairing: pairing}
    end

    test "the result <select> is disabled once archived", %{conn: conn, scope: scope} do
      %{tournament: tournament} = paired_tournament(scope)
      {:ok, _} = Tournaments.archive_tournament(tournament)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/pairings")

      assert html =~ ~s(disabled)
      assert [selector] = Regex.run(~r/<select[^>]*id="result-select-\d+"[^>]*>/, html)
      assert selector =~ "disabled"
    end

    test "a result submitted anyway (crafted event, bypassing the disabled select) is refused with a visible error, not silently applied",
         %{conn: conn, scope: scope} do
      %{tournament: tournament, pairing: pairing} = paired_tournament(scope)
      {:ok, _} = Tournaments.archive_tournament(tournament)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/pairings")

      html =
        render_change(lv, "result", %{"pairing-id" => to_string(pairing.id), "result" => "1-0"})

      assert html =~ "This tournament is archived"
      assert Repo.reload!(pairing).result == ""
    end

    test "the right-click edit menu refuses to open on an archived round", %{
      conn: conn,
      scope: scope
    } do
      %{tournament: tournament} = paired_tournament(scope)
      {:ok, _} = Tournaments.archive_tournament(tournament)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/pairings")

      html = render_click(lv, "open_menu", %{"x" => "10", "y" => "10", "player-id" => "1"})

      assert html =~ "This tournament is archived"
      refute html =~ "Swap with"
    end

    test "the CSV import button is hidden once archived", %{conn: conn, scope: scope} do
      %{tournament: tournament} = paired_tournament(scope)

      {:ok, _lv, html_before} = live(conn, ~p"/t/#{tournament.id}/pairings")
      assert html_before =~ "Import results (CSV)"

      {:ok, _} = Tournaments.archive_tournament(tournament)

      {:ok, _lv, html_after} = live(conn, ~p"/t/#{tournament.id}/pairings")
      refute html_after =~ "Import results (CSV)"
    end
  end

  describe "writes on an archived tournament are refused WITHOUT crashing the LiveView (players/results-import)" do
    test "editing a player on an archived tournament shows an error instead of crashing", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      player = Repo.insert!(%Player{tournament_id: tournament.id, name: "Alice"})
      {:ok, _} = Tournaments.archive_tournament(tournament)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      render_click(lv, "edit_player", %{"id" => to_string(player.id)})

      html =
        lv
        |> form(~s(form[phx-submit="save_player"]), %{"player" => %{"name" => "Renamed"}})
        |> render_submit()

      assert html =~ "This tournament is archived"
      assert Repo.reload!(player).name == "Alice"
    end

    test "deleting a player on an archived tournament shows an error instead of silently no-oping",
         %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      player = Repo.insert!(%Player{tournament_id: tournament.id, name: "Alice"})
      {:ok, _} = Tournaments.archive_tournament(tournament)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/players")

      html =
        lv
        |> element(~s([phx-click="delete"][phx-value-id="#{player.id}"]))
        |> render_click()

      assert html =~ "This tournament is archived"
      assert Repo.get(Player, player.id)
    end

    test "CSV results import on an archived tournament shows an error instead of crashing", %{
      scope: scope
    } do
      tournament = create_tournament(scope, %{"rounds_count" => "1"})
      a = Repo.insert!(%Player{tournament_id: tournament.id, name: "Alice"})
      b = Repo.insert!(%Player{tournament_id: tournament.id, name: "Bob"})
      round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "playing"})

      Repo.insert!(%Pairing{
        round_id: round.id,
        board: 1,
        white_player_id: a.id,
        black_player_id: b.id,
        result: ""
      })

      assert {:ok, count} =
               PairingsEngine.ResultsImport.apply_import(tournament, 1, [{1, "1-0"}])

      assert count == 1
      {:ok, _} = Tournaments.archive_tournament(tournament)

      assert {:error, [message]} =
               PairingsEngine.ResultsImport.apply_import(tournament, 1, [{1, "0-1"}])

      assert message =~ "archived"
    end
  end

  describe "an archived tournament stays readable" do
    test "its public pages keep serving", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, tournament} = Tournaments.set_public_pages(tournament, true)
      {:ok, tournament} = Tournaments.archive_tournament(tournament)

      {:ok, _lv, html} = live(conn, ~p"/p/#{tournament.public_slug}/standings")

      assert html =~ tournament.name
      # The read-only banner is an arbiter-facing thing; the public page has
      # no concept of editing, so it must not leak it.
      refute html =~ "archived-banner"
    end

    test "its JSON export still downloads", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, _} = Tournaments.archive_tournament(tournament)

      conn = get(conn, ~p"/t/#{tournament.id}/export/json")

      assert conn.status == 200
    end
  end
end
