defmodule PairingsEngineWeb.PairingsLiveUxGapsTest do
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Player, Round, Pairing}
  alias PairingsEngineWeb.PairingsLive

  setup :register_and_log_in_user

  # Two finished rounds of three; the page opens on round 2, the last.
  defp played(scope) do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "UX gaps",
        "type" => "swiss",
        "rounds_count" => "3"
      })

    # Numbered by round 1, as a real pairing would leave them.
    [a, b] =
      for {name, rating, number} <- [{"A", 2000, 1}, {"B", 1800, 2}] do
        Repo.insert!(%Player{
          tournament_id: t.id,
          name: name,
          fide_rating: rating,
          pairing_number: number
        })
      end

    for {n, w, bl} <- [{1, a, b}, {2, b, a}] do
      r = Repo.insert!(%Round{tournament_id: t.id, number: n, status: "finished"})

      Repo.insert!(%Pairing{
        round_id: r.id,
        board: 1,
        white_player_id: w.id,
        black_player_id: bl.id,
        result: "1-0"
      })

      :ok = Tournaments.freeze_round_display_boards!(r.id)
    end

    t
  end

  # One round being played, two boards, and a spare player.
  defp playing(scope) do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "UX gaps playing",
        "type" => "swiss",
        "rounds_count" => "3"
      })

    [a, b, c, d] =
      for name <- ~w(A B C D), do: Repo.insert!(%Player{tournament_id: t.id, name: name})

    round = Repo.insert!(%Round{tournament_id: t.id, number: 1, status: "playing"})

    board1 =
      Repo.insert!(%Pairing{
        round_id: round.id,
        board: 1,
        white_player_id: a.id,
        black_player_id: b.id,
        result: ""
      })

    Repo.insert!(%Pairing{
      round_id: round.id,
      board: 2,
      white_player_id: c.id,
      black_player_id: d.id,
      result: ""
    })

    %{tournament: t, a: a, board1: board1}
  end

  describe "a round unpaired in another tab" do
    test "closes the staged hand edit instead of applying it to nothing", %{
      conn: conn,
      scope: scope
    } do
      %{tournament: t, a: a} = playing(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

      render_click(lv, "stage_vacate", %{"player-id" => to_string(a.id)})
      assert has_element?(lv, "#hand-edit-dialog")

      # Somebody else unpairs; the broadcast reaches this page.
      :ok = PairingsEngine.Pairing.delete_round(t.id, 1)
      _ = render(lv)

      refute has_element?(lv, "#hand-edit-dialog")
      # Applying what is no longer there is a no-op, not a crash.
      render_click(lv, "apply_confirm", %{})
      assert Process.alive?(lv.pid)
    end
  end

  describe "unpairing" do
    test "the confirm says what goes and where the restore point is; the page says it went",
         %{conn: conn, scope: scope} do
      t = played(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

      assert has_element?(
               lv,
               ~s(#unpair-round-2[data-confirm*="All results of round 2 are deleted"])
             )

      assert has_element?(lv, ~s{#unpair-round-2[data-confirm*="(Advanced, History)"]})
      refute has_element?(lv, ~s(#unpair-round-2[data-confirm*="pairing numbers"]))

      html = render_click(lv, "unpair", %{})
      assert html =~ "Round 2 unpaired. A restore point was saved."
      # Back on the round still paired, whose unpair button is now the one.
      assert has_element?(lv, "#unpair-round-1")
      assert has_element?(lv, ~s(#unpair-round-1[data-confirm*="pairing numbers go too"]))
    end

    test "a round that is not the last is refused in words, not in engine English", %{
      conn: conn,
      scope: scope
    } do
      t = played(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

      render_click(lv, "select_round", %{"number" => "1"})
      html = render_click(lv, "unpair", %{})
      assert html =~ "Only the last paired round can be unpaired."
    end

    test "in Dutch", %{conn: conn, scope: scope} do
      t = played(scope)
      conn = Plug.Test.init_test_session(conn, %{"locale" => "nl"})
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

      assert has_element?(
               lv,
               ~s(#unpair-round-2[data-confirm*="Alle resultaten van ronde 2 worden verwijderd"])
             )
    end
  end

  describe "phone codes" do
    test "revoking asks first and says when it is done", %{conn: conn, scope: scope} do
      t = played(scope)
      {:ok, enrollment} = PairingsEngine.Mobile.create_enrollment(t.id)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      lv |> element("#phone-qr-link") |> render_click()

      assert has_element?(
               lv,
               ~s(button[phx-click="revoke_enrollment"][data-confirm*="signed out at once"])
             )

      html = render_click(lv, "revoke_enrollment", %{"id" => to_string(enrollment.id)})
      assert html =~ "Phone code revoked."

      html = render_click(lv, "revoke_enrollment", %{"id" => "999999"})
      assert html =~ "That phone code is already gone."
    end
  end

  describe "hand edits" do
    test "hiding a board somebody still sits at says why it did not happen", %{
      conn: conn,
      scope: scope
    } do
      %{tournament: t, board1: board1} = playing(scope)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

      html = render_click(lv, "toggle_hidden", %{"pairing-id" => to_string(board1.id)})
      assert html =~ "Somebody is still seated on that board"
      refute Repo.get!(Pairing, board1.id).hidden
    end

    test "a refusal reads as a sentence, not an atom" do
      assert PairingsLive.hand_edit_error_text(:not_in_round) =~
               "no longer in this round; the page has been refreshed"

      assert PairingsLive.hand_edit_error_text(:same_player) =~ "same player twice"
      refute PairingsLive.hand_edit_error_text(:something_new) =~ "something_new"
    end
  end
end
