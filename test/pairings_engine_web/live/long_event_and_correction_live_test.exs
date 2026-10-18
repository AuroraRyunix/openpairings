defmodule PairingsEngineWeb.LongEventAndCorrectionLiveTest do
  @moduledoc """
  The pages' side of VCL4THP Q210-Q216 (a tournament lasting more than 30
  days: the flag and its suggestion, C.07 Article 10's advice, the round
  whose ratings the tie-breaks use, a player's later ratings) and Q112-Q115
  (a Correction PIBE: a Level-3 confirmation, a restore point, a log row).
  """
  # async: false: sequential SQLite writes, like the other LiveView tests here.
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Pairing, as: Engine

  setup :register_and_log_in_user

  defp tournament(scope, attrs \\ %{}) do
    {:ok, t} =
      Tournaments.create_tournament(
        scope,
        Map.merge(
          %{
            "name" => "Winter league",
            "type" => "swiss",
            "rounds_count" => "4",
            "round_dates" => ~w(2026-09-01 2026-09-29 2026-10-27 2026-11-24),
            "tiebreaks" => ["BH", "SB"]
          },
          attrs
        )
      )

    for {name, rating} <- [{"Alice", 2000}, {"Bob", 1900}, {"Carol", 1800}, {"Dave", 1700}] do
      {:ok, _} = Tournaments.create_player(t.id, %{"name" => name, "fide_rating" => "#{rating}"})
    end

    Tournaments.get_tournament!(t.id)
  end

  describe "a tournament lasting more than 30 days" do
    test "is suggested when the dates span more than 30 days, and saved", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings")

      assert has_element?(lv, "#long-event-suggestion")
      refute has_element?(lv, "#tiebreak-rating-round")

      lv
      |> form("#tournament-settings-form", %{"tournament" => %{"long_event" => "true"}})
      |> render_submit()

      assert Tournaments.get_tournament!(t.id).long_event
      refute has_element?(lv, "#long-event-suggestion")

      lv
      |> form("#tournament-settings-form", %{"tournament" => %{"tiebreak_rating_round" => "3"}})
      |> render_submit()

      assert Tournaments.get_tournament!(t.id).tiebreak_rating_round == 3
    end

    test "per-round tie-break ratings are a setting, and the standings say which rating counts (Q214)",
         %{conn: conn, scope: scope} do
      t = tournament(scope, %{"long_event" => "true", "tiebreaks" => ["ARO", "BH"]})
      refute t.tiebreak_rating_per_round

      {:ok, standings, _html} = live(conn, ~p"/t/#{t.id}/standings")
      assert has_element?(standings, "#tiebreak-rating-basis", "first rating")

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings")
      assert has_element?(lv, "#tiebreak-rating-per-round")

      lv
      |> form("#tournament-settings-form", %{
        "tournament" => %{"tiebreak_rating_per_round" => "true"}
      })
      |> render_submit()

      assert Tournaments.get_tournament!(t.id).tiebreak_rating_per_round

      {:ok, standings, _html} = live(conn, ~p"/t/#{t.id}/standings")
      assert has_element?(standings, "#tiebreak-rating-basis", "round the game was played")
    end

    test "the reporting choice shows only with the tick, saves, and travels in the JSON", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope)
      assert t.long_event_reporting == "monthly"

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings")
      refute has_element?(lv, "#long-event-reporting")

      lv
      |> form("#tournament-settings-form", %{"tournament" => %{"long_event" => "true"}})
      |> render_submit()

      assert has_element?(lv, "#long-event-reporting")
      assert has_element?(lv, "#long-event-reporting-explain")

      lv
      |> form("#tournament-settings-form", %{"tournament" => %{"long_event_reporting" => "end"}})
      |> render_submit()

      saved = Tournaments.get_tournament!(t.id)
      assert saved.long_event_reporting == "end"
      assert PairingsEngine.Tournaments.Tournament.one_report_at_end?(saved)

      envelope = PairingsEngine.TournamentExport.export_tournament(saved)
      [data] = envelope["tournaments"]
      assert data["tournament"]["long_event_reporting"] == "end"

      {:ok, [copy]} =
        PairingsEngine.TournamentImport.import(
          envelope |> Jason.encode!() |> Jason.decode!(),
          scope
        )

      assert copy.long_event_reporting == "end"
    end

    test "Send says so when a report-at-the-end file holds fewer rounds than the event", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope, %{"long_event" => "true", "long_event_reporting" => "end"})
      {:ok, _} = Engine.pair_next_round(t)

      for p <- Tournaments.get_round(t.id, 1).pairings, p.black_player_id do
        {:ok, _} = Tournaments.update_pairing_result(p, "1-0")
      end

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/export")

      assert has_element?(lv, "#trf-send-one-report-warning")
      assert has_element?(lv, ~s(#trf-send[data-confirm*="expects a file with 4 rounds"]))
      refute has_element?(lv, "#trf-download-copy[data-confirm]")
      refute has_element?(lv, "#trf-send-monthly-note")
    end

    test "no such warning when the file holds every round", %{conn: conn, scope: scope} do
      t =
        tournament(scope, %{
          "long_event" => "true",
          "long_event_reporting" => "end",
          "rounds_count" => "1",
          "round_dates" => ["2026-09-01"]
        })

      {:ok, _} = Engine.pair_next_round(t)

      for p <- Tournaments.get_round(t.id, 1).pairings, p.black_player_id do
        {:ok, _} = Tournaments.update_pairing_result(p, "1-0")
      end

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/export")

      assert has_element?(lv, "#trf-send[data-confirm]")
      refute has_element?(lv, "#trf-send-one-report-warning")
      refute has_element?(lv, ~s(#trf-send[data-confirm*="expects a file"]))
    end

    test "monthly: a note beside Send, and no warning", %{conn: conn, scope: scope} do
      t = tournament(scope, %{"long_event" => "true"})
      {:ok, _} = Engine.pair_next_round(t)

      for p <- Tournaments.get_round(t.id, 1).pairings, p.black_player_id do
        {:ok, _} = Tournaments.update_pairing_result(p, "1-0")
      end

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/export")

      assert has_element?(lv, "#trf-send-monthly-note")
      refute has_element?(lv, "#trf-send-one-report-warning")
      refute has_element?(lv, ~s(#trf-send[data-confirm*="expects a file"]))
    end

    test "postponed games of a report-at-the-end event go in the final report", %{
      conn: conn,
      scope: scope
    } do
      t =
        tournament(scope, %{
          "long_event" => "true",
          "long_event_reporting" => "end",
          "postponed_games" => "true"
        })

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/export")
      assert has_element?(lv, "#postponed-one-report-note")

      {:ok, _} = Tournaments.update_tournament(t, %{"long_event_reporting" => "monthly"})
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/export")
      refute has_element?(lv, "#postponed-one-report-note")
    end

    test "advises against rating-based tie-breaks (C.07 Article 10)", %{conn: conn, scope: scope} do
      t = tournament(scope, %{"long_event" => "true"})
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings")
      refute has_element?(lv, "#long-event-rating-tiebreaks")

      lv |> element(~s(select[name="code"])) |> render_change(%{"code" => "ARO"})
      assert has_element?(lv, "#long-event-rating-tiebreaks")
    end

    test "a player's later ratings are entered on the player dialog", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope, %{"long_event" => "true"})
      carol = Enum.find(Tournaments.list_players(t.id), &(&1.name == "Carol"))

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/players")
      render_click(lv, "edit_player", %{"id" => to_string(carol.id)})
      assert has_element?(lv, "#player-period-ratings")

      lv
      |> form("#player-edit-form", player: %{"period_ratings_text" => "3:1850"})
      |> render_submit()

      assert Tournaments.get_player!(t.id, carol.id).period_ratings == [
               %{"from_round" => 3, "fide_rating" => 1850}
             ]
    end

    test "no later-ratings field while the flag is off", %{conn: conn, scope: scope} do
      t = tournament(scope)
      carol = Enum.find(Tournaments.list_players(t.id), &(&1.name == "Carol"))

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/players")
      render_click(lv, "edit_player", %{"id" => to_string(carol.id)})
      refute has_element?(lv, "#player-period-ratings")
    end
  end

  describe "a result corrected after a later round was paired" do
    setup %{scope: scope} do
      t = tournament(scope)
      {:ok, _} = Engine.pair_next_round(t)

      for p <- Tournaments.get_round(t.id, 1).pairings, p.black_player_id do
        {:ok, _} = Tournaments.update_pairing_result(p, "1-0")
      end

      {:ok, _} = Engine.pair_next_round(Tournaments.get_tournament!(t.id))
      [board | _] = Tournaments.get_round(t.id, 1).pairings
      %{t: t, board: board}
    end

    test "asks first, then takes a restore point and logs the PIBE", %{
      conn: conn,
      t: t,
      board: board
    } do
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      render_click(lv, "select_round", %{"number" => "1"})

      lv
      |> element("#result-form-#{board.id}")
      |> render_change(%{"pairing-id" => board.id, "result" => "0-1"})

      # Level 3: nothing written until confirmed.
      assert has_element?(lv, "#confirm-correction-#{board.id}")
      assert Repo.reload!(board).result == "1-0"

      lv |> element("#confirm-postponed-yes-#{board.id}") |> render_click()

      assert Repo.reload!(board).result == "0-1"
      assert Repo.reload!(board).corrected_from == "1-0"

      [details] =
        Repo.all(
          from a in PairingsEngine.Audit.AuditLog,
            where: a.tournament_id == ^t.id and a.action == "pibe.correction",
            select: a.details
        )

      assert details["line"] =~ ~r/^Correction @ Round 1: \d+-\d+: 1-0 => 0-1$/

      assert Repo.exists?(
               from s in PairingsEngine.Snapshots.Snapshot,
                 where: s.tournament_id == ^t.id and s.trigger == "pibe.correction"
             )
    end

    test "cancelling writes nothing", %{conn: conn, t: t, board: board} do
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      render_click(lv, "select_round", %{"number" => "1"})

      lv
      |> element("#result-form-#{board.id}")
      |> render_change(%{"pairing-id" => board.id, "result" => "0-1"})

      lv |> element("#confirm-postponed-cancel-#{board.id}") |> render_click()
      assert Repo.reload!(board).result == "1-0"
      assert Repo.reload!(board).corrected_from == nil
    end
  end
end
