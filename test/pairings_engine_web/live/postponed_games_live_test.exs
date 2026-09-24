defmodule PairingsEngineWeb.PostponedGamesLiveTest do
  @moduledoc """
  Postponed games on the arbiter's screens (VCL4THP Q157-169): the Pairings
  page's result select, its confirmations and pair buttons, the Standings
  page's "not final" banner, the printed standings and the phone.
  """
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Audit, Mobile, Repo, Tournaments}
  alias PairingsEngine.Pairing, as: Engine

  setup :register_and_log_in_user

  # Complete setup, four players, round 1 paired: Alice-Carol and Bob-Dave.
  defp tournament(scope) do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "Club championship",
        "type" => "swiss",
        "start_date" => "2026-09-01",
        "rounds_count" => "3",
        "round_dates" => ["2026-09-01", "2026-09-08", "2026-09-15"],
        "tiebreaks" => ["BH", "SB"]
      })

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

  defp change_result(lv, pairing, result) do
    lv
    |> element("#result-form-#{pairing.id}")
    |> render_change(%{"pairing-id" => pairing.id, "result" => result})
  end

  describe "the Pairings page" do
    test "offers postponed, records it, and lists the game until it is played", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope)
      [board | _] = boards(t, 1)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

      assert has_element?(lv, "#result-select-#{board.id} option[value='*']")
      refute has_element?(lv, "#postponed-games")

      change_result(lv, board, "*")

      assert Repo.reload!(board).result == "*"
      assert has_element?(lv, "#postponed-games #postponed-game-#{board.id}")
      assert has_element?(lv, "#postponed-trf-not-final")
    end

    test "a decisive result for a postponed game waits for confirmation (Q163)", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope)
      [board | _] = boards(t, 1)
      set!(board, "*")

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

      change_result(lv, board, "1-0")

      assert has_element?(lv, "#confirm-postponed-#{board.id}")
      assert Repo.reload!(board).result == "*"

      lv |> element("#confirm-postponed-yes-#{board.id}") |> render_click()

      assert Repo.reload!(board).result == "1-0"
      refute has_element?(lv, "#confirm-postponed-#{board.id}")
      refute has_element?(lv, "#postponed-games")

      [entry | _] = Audit.list_for_tournament(t.id)
      assert entry.action == "pairing.result_changed"
      assert entry.details["confirmed"] == "adjourned_non_draw_result"
    end

    test "cancelling the confirmation leaves the game postponed", %{conn: conn, scope: scope} do
      t = tournament(scope)
      [board | _] = boards(t, 1)
      set!(board, "*")

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      change_result(lv, board, "0-1")
      lv |> element("#confirm-postponed-cancel-#{board.id}") |> render_click()

      refute has_element?(lv, "#confirm-postponed-#{board.id}")
      assert Repo.reload!(board).result == "*"
    end

    test "a draw over a postponed game is written straight away", %{conn: conn, scope: scope} do
      t = tournament(scope)
      [board | _] = boards(t, 1)
      set!(board, "*")

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      change_result(lv, board, "1/2-1/2")

      refute has_element?(lv, "#confirm-postponed-#{board.id}")
      assert Repo.reload!(board).result == "1/2-1/2"
    end

    test "missing results can be recorded as postponed to pair the next round (Q159, Q160)", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope)
      [open, reported] = boards(t, 1)
      set!(reported, "1-0")

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      lv |> element(".round-picker button[phx-value-number='2']") |> render_click()

      # The ordinary button stays disabled; recording is its own click, and
      # carries a confirmation.
      assert has_element?(lv, "#pair-round[disabled]")

      assert has_element?(
               lv,
               "#pair-recording-postponed[data-confirm][phx-value-acknowledged='missing_results_recorded_as_adjourned']"
             )

      lv |> element("#pair-recording-postponed") |> render_click()
      render(lv)

      assert Tournaments.get_round(t.id, 2)
      assert Repo.reload!(open).result == "*"
      assert has_element?(lv, "#postponed-game-#{open.id}")

      assert Enum.any?(
               Audit.list_for_tournament(t.id),
               &(&1.action == "pairing.missing_recorded_postponed")
             )
    end

    test "pairing with a postponed game from an older round asks first (Q168)", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope)
      [postponed, other] = boards(t, 1)
      set!(postponed, "*")
      set!(other, "1-0")
      {:ok, _} = Engine.pair_next_round(Tournaments.get_tournament!(t.id))
      for p <- boards(t, 2), p.black_player_id, do: set!(p, "1-0")

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      lv |> element(".round-picker button[phx-value-number='3']") |> render_click()

      assert has_element?(
               lv,
               "#pair-round[data-confirm][phx-value-acknowledged='adjourned_older_round_open']"
             )

      refute has_element?(lv, "#pair-recording-postponed")
    end

    test "a postponed game in the last round is noted beside the pair button", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope)
      [postponed, other] = boards(t, 1)
      set!(postponed, "*")
      set!(other, "1-0")

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      lv |> element(".round-picker button[phx-value-number='2']") |> render_click()

      assert has_element?(lv, "#postponed-counted-as-draw")
      refute has_element?(lv, "#pair-round[disabled]")
      refute has_element?(lv, "#pair-round[data-confirm]")
    end
  end

  describe "the Standings page (Q161, Q169)" do
    test "says not final while a game is postponed, and nothing once it is played", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope)
      [postponed, other] = boards(t, 1)
      set!(postponed, "*")
      set!(other, "1-0")

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/standings")
      assert has_element?(lv, "#postponed-not-final")

      set!(postponed, "1/2-1/2")
      render(lv)

      refute has_element?(lv, "#postponed-not-final")
    end
  end

  describe "printed standings" do
    test "carry the not-final banner while a game is postponed", %{conn: conn, scope: scope} do
      t = tournament(scope)
      [postponed, other] = boards(t, 1)
      set!(postponed, "*")
      set!(other, "1-0")

      banner = fn ->
        conn
        |> get(~p"/t/#{t.id}/print/standings")
        |> html_response(200)
        |> LazyHTML.from_document()
        |> LazyHTML.query("#postponed-not-final")
        |> Enum.count()
      end

      assert banner.() == 1

      set!(postponed, "0-1", acknowledged: [:adjourned_non_draw_result])

      assert banner.() == 0
    end
  end

  describe "the phone" do
    test "a deputy is sent to the Pairings page for a decisive result on a postponed game", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope)
      [postponed | _] = boards(t, 1)
      set!(postponed, "*")

      {:ok, enrollment} = Mobile.create_enrollment(t.id, level: "deputy")
      conn = init_test_session(conn, %{mobile_enrollment_id: enrollment.id})
      {:ok, lv, _html} = live(conn, ~p"/m/results")

      render_click(lv, "set_result", %{"id" => to_string(postponed.id), "result" => "1-0"})

      assert has_element?(lv, "#flash-error", "was postponed")
      assert Repo.reload!(postponed).result == "*"
    end
  end
end
