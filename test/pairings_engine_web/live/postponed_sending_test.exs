defmodule PairingsEngineWeb.PostponedSendingTest do
  @moduledoc """
  The Export page and download routes after the postponed-games audit of
  2026-10-01: copies named and marked as copies, an imported copy that
  sends nothing until confirmed, the postponed-games file as a tournament
  of its own (its name, FIDE tournament ID and rating period), and the
  older TRF spelling refusing to write an open postponed game as a draw.

  Generated data only: no .swar fixtures, no real players.
  """
  use PairingsEngineWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias PairingsEngine.{Repo, TournamentExport, TournamentImport, Tournaments}
  alias PairingsEngine.Audit.AuditLog
  alias PairingsEngine.Pairing, as: Engine
  alias PairingsEngine.Tournaments.TrfSentGame

  setup :register_and_log_in_user

  # Four players, round 1 paired: two boards.
  defp tournament(scope, attrs \\ %{}) do
    {:ok, t} =
      Tournaments.create_tournament(
        scope,
        Map.merge(
          %{
            "name" => "Sending club championship",
            "type" => "swiss",
            "start_date" => "2026-09-01",
            "rounds_count" => "3",
            "round_dates" => ["2026-09-01", "2026-09-08", "2026-09-15"],
            "tiebreaks" => ["BH", "SB"],
            "postponed_games" => "true"
          },
          attrs
        )
      )

    for {name, rating} <- [{"Alice", 2000}, {"Bob", 1900}, {"Carol", 1800}, {"Dave", 1700}] do
      {:ok, _} = Tournaments.create_player(t.id, %{"name" => name, "fide_rating" => "#{rating}"})
    end

    {:ok, _} = Engine.pair_next_round(t)
    Tournaments.get_tournament!(t.id)
  end

  defp boards(t, round_number), do: Tournaments.get_round(t.id, round_number).pairings

  defp set!(pairing, result, opts \\ []) do
    {:ok, updated} = Tournaments.update_pairing_result(pairing, result, opts)
    updated
  end

  defp disposition(conn), do: conn |> get_resp_header("content-disposition") |> hd()

  # Round 1 sent with both games postponed, both played since on `dates`.
  defp late_games!(conn, t, dates) do
    games = for p <- boards(t, 1), do: set!(p, "*W")
    # FIDE mode sends nothing with a game open (Q169): not played here.
    PairingsEngine.PostponedHelpers.report_open_games_not_played!(t)
    post(conn, ~p"/t/#{t.id}/export/trf", %{"rounds" => "1", "finalise" => "true"})

    for {p, date} <- Enum.zip(games, dates) do
      set!(Repo.reload!(p), "1/2-1/2", played_on: date)
    end
  end

  describe "copies" do
    test "are named and marked as copies; the file sent is not", %{conn: conn, scope: scope} do
      t = tournament(scope)
      for p <- boards(t, 1), do: set!(p, "1-0")

      copy = get(conn, ~p"/t/#{t.id}/export/trf?rounds=1")
      assert disposition(copy) =~ "_r1_COPY-NOT-FOR-RATING.trf"
      assert response(copy, 200) =~ "### COPY - NOT FOR RATING"

      sent = post(conn, ~p"/t/#{t.id}/export/trf", %{"rounds" => "1", "finalise" => "true"})
      assert disposition(sent) =~ "_r1.trf"
      refute disposition(sent) =~ "COPY"
      # The file sent holds only records: no comment line, no ruler.
      refute response(sent, 200) =~ "###"
      refute response(sent, 200) =~ "DDD"

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/export")
      assert has_element?(lv, "#trf-download-copy", "not for rating")
    end

    test "a copy's name is in the page's language", %{conn: conn, scope: scope} do
      t = tournament(scope)
      for p <- boards(t, 1), do: set!(p, "1-0")

      copy = conn |> put_req_header("accept-language", "nl") |> get(~p"/t/#{t.id}/export/trf")

      assert disposition(copy) =~ "_KOPIE-NIET-VOOR-RATING.trf"
    end

    test "the older spelling refuses an open postponed game rather than write a draw", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope)
      [postponed, other] = boards(t, 1)
      set!(postponed, "*W")
      set!(other, "1-0")

      refused = get(conn, ~p"/t/#{t.id}/export/trf?dialect=javafo")
      assert redirected_to(refused) == ~p"/t/#{t.id}/settings/export"
      assert Phoenix.Flash.get(refused.assigns.flash, :error) =~ "postponed game"

      # Once played, it is a result like any other.
      set!(Repo.reload!(postponed), "1/2-1/2")
      assert response(get(conn, ~p"/t/#{t.id}/export/trf?dialect=javafo"), 200) =~ "001"
    end
  end

  describe "two sends of one round" do
    test "only the first gets a file, and the round is recorded once", %{conn: conn, scope: scope} do
      t = tournament(scope)
      for p <- boards(t, 1), do: set!(p, "1-0")

      first = post(conn, ~p"/t/#{t.id}/export/trf", %{"rounds" => "1", "finalise" => "true"})
      second = post(conn, ~p"/t/#{t.id}/export/trf", %{"rounds" => "1", "finalise" => "true"})

      assert response(first, 200) =~ "001"
      assert redirected_to(second) == ~p"/t/#{t.id}/settings/export"
      assert Phoenix.Flash.get(second.assigns.flash, :error) =~ "Not sent, and no file"

      assert Repo.aggregate(from(s in TrfSentGame, where: s.tournament_id == ^t.id), :count) == 2
    end
  end

  describe "an imported copy" do
    test "sends nothing until an arbiter confirms it is the copy that reports", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope, %{"fide_tournament_id" => "424243"})
      for p <- boards(t, 1), do: set!(p, "1-0")

      backup = t |> TournamentExport.export_tournament() |> Jason.encode!() |> Jason.decode!()
      {:ok, [copy]} = TournamentImport.import(backup, scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{copy.id}/settings/export")
      assert has_element?(lv, "#trf-copy-unconfirmed")
      assert has_element?(lv, "#trf-send[disabled]")

      refused = post(conn, ~p"/t/#{copy.id}/export/trf", %{"rounds" => "1", "finalise" => "true"})
      assert Phoenix.Flash.get(refused.assigns.flash, :error) =~ "imported from a file"

      lv |> element("#trf-confirm-copy") |> render_click()
      refute has_element?(lv, "#trf-copy-unconfirmed")
      refute has_element?(lv, "#trf-send[disabled]")

      assert Repo.exists?(
               from a in AuditLog,
                 where: a.tournament_id == ^copy.id and a.action == "trf.copy_confirmed"
             )
    end
  end

  describe "the postponed-games file, a tournament of its own" do
    test "is named, numbered and dated as its own tournament, and sent once", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope)
      late_games!(conn, t, [~D[2026-09-20], ~D[2026-09-27]])

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/export")
      assert has_element?(lv, "#postponed-report-identity", "separate tournament")

      lv
      |> form("#postponed-report-form", %{
        "postponed_report" => %{
          "postponed_report_name" => "Clubkampioenschap uitgestelde partijen",
          "postponed_fide_tournament_id" => "777002"
        }
      })
      |> render_submit()

      assert has_element?(lv, "#postponed-report-summary", "777002")
      assert has_element?(lv, "#postponed-trf-period", "September 2026")

      sent =
        post(conn, ~p"/t/#{t.id}/export/postponed-trf", %{
          "finalise" => "true",
          "period" => "2026-09-01"
        })

      assert disposition(sent) =~ "S_777002_clubkampioenschap-uitgestelde-partijen_2026-09.trf"
      text = response(sent, 200)
      assert text =~ "012 Clubkampioenschap uitgestelde partijen"
      assert text =~ "042 2026/09/20"
      assert text =~ "052 2026/09/27"

      again =
        post(conn, ~p"/t/#{t.id}/export/postponed-trf", %{
          "finalise" => "true",
          "period" => "2026-09-01"
        })

      assert redirected_to(again) == ~p"/t/#{t.id}/settings/export"

      assert [%{action: "trf.postponed_sent"}] =
               Repo.all(
                 from a in AuditLog,
                   where: a.tournament_id == ^t.id and a.action == "trf.postponed_sent"
               )
    end

    test "one file per rating period: the page sends one month at a time", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope)
      late_games!(conn, t, [~D[2026-09-29], ~D[2026-10-02]])

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/export")
      assert has_element?(lv, "#postponed-trf-period", "September 2026")
      assert has_element?(lv, "#trf-late-send-form input[name='period'][value='2026-09-01']")

      lv |> element("#rating-period-2026-10-select") |> render_click()
      assert has_element?(lv, "#postponed-trf-period", "October 2026")
      assert has_element?(lv, "#trf-late-send-form input[name='period'][value='2026-10-01']")

      # Both months in one file: refused, nothing marked.
      mixed = post(conn, ~p"/t/#{t.id}/export/postponed-trf", %{"finalise" => "true"})
      assert Phoenix.Flash.get(mixed.assigns.flash, :error) =~ "more than one rating period"

      refute Repo.exists?(
               from s in TrfSentGame, where: s.tournament_id == ^t.id and s.kind == "postponed"
             )
    end

    test "changing the date a game was played is on record", %{conn: conn, scope: scope} do
      t = tournament(scope)
      late_games!(conn, t, [~D[2026-09-20], ~D[2026-09-27]])
      [game | _] = boards(t, 1)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/export")

      lv
      |> form("#played-on-form-#{game.id}", %{"played_on" => "2026-09-19"})
      |> render_submit(%{"pairing-id" => game.id})

      assert Repo.reload!(game).played_on == ~D[2026-09-19]

      assert [%{details: %{"to" => "2026-09-19"}}] =
               Repo.all(
                 from a in AuditLog,
                   where: a.tournament_id == ^t.id and a.action == "pairing.played_on_set"
               )
    end
  end
end
