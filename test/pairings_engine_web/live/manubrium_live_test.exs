defmodule PairingsEngineWeb.ManubriumLiveTest do
  @moduledoc """
  Manubrium's LiveView side (docs/manubrium.md): what the phone's result
  page carries for the queue and the incident dialog, the hall view's board
  range, the hold/settle the queue asks for, and the arbiter's incidents -
  their page, the line under the round, and the install hint on the code.

  The queue itself is JavaScript and does not run here; its server half is
  `PairingsEngine.MobileSyncTest`.
  """
  use PairingsEngineWeb.ConnCase

  import Phoenix.LiveViewTest
  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.{Incidents, Mobile, Repo, Tournaments}
  alias PairingsEngine.Mobile.Sync
  alias PairingsEngine.Tournaments.{Pairing, Round}

  defp tournament(scope) do
    {:ok, t} = Tournaments.create_tournament(scope, %{"name" => "Hall T", "type" => "swiss"})
    t
  end

  # Round 1 with `n` boards, all open unless `results` says otherwise.
  defp boards(t, n, results \\ %{}) do
    round = Repo.insert!(%Round{tournament_id: t.id, number: 1, status: "paired"})

    for board <- 1..n do
      {:ok, w} =
        Tournaments.create_player(t.id, %{"name" => "W#{board}", "fide_rating" => "1800"})

      {:ok, b} =
        Tournaments.create_player(t.id, %{"name" => "B#{board}", "fide_rating" => "1700"})

      Repo.insert!(%Pairing{
        round_id: round.id,
        board: board,
        white_player_id: w.id,
        black_player_id: b.id,
        result: Map.get(results, board, "")
      })
    end
  end

  defp phone(conn, t, opts) do
    {:ok, e} = Mobile.create_enrollment(t.id, opts)
    {init_test_session(conn, %{mobile_enrollment_id: e.id}), e}
  end

  defp incident(e, p, type) do
    {:ok, [%{status: :saved}]} =
      Sync.submit(e.id, [
        %{
          "cid" => Ecto.UUID.generate(),
          "enrollment" => e.id,
          "kind" => "incident",
          "round" => 1,
          "pairing" => p.id,
          "board" => p.board,
          "type" => type,
          "note" => "clock face down"
        }
      ])
  end

  describe "the phone's result page" do
    test "is Manubrium, with the queue's count, outbox and hook", %{conn: conn} do
      t = tournament(user_scope_fixture())
      boards(t, 2)
      {conn, e} = phone(conn, t, level: "helper")

      {:ok, lv, html} = live(conn, ~p"/m/results")

      assert html =~ "Manubrium"
      assert has_element?(lv, "#manubrium-count[role='status']")
      assert has_element?(lv, "#manubrium-outbox[phx-update='ignore']")

      assert has_element?(
               lv,
               "main#main-content[phx-hook='Manubrium'][data-enrollment='#{e.id}']"
             )

      assert has_element?(lv, "#mobile-leave[data-mq-leave]")
    end

    test "each board carries what a queued entry is made of", %{conn: conn} do
      t = tournament(user_scope_fixture())
      [p | _] = boards(t, 2)
      {conn, _e} = phone(conn, t, level: "helper")

      {:ok, lv, _html} = live(conn, ~p"/m/results")

      assert has_element?(
               lv,
               "#mobile-board-#{p.id}[data-pairing='#{p.id}'][data-board='1'][data-round='1']" <>
                 "[data-white='#{p.white_player_id}'][data-black='#{p.black_player_id}']"
             )

      assert has_element?(lv, "#mobile-board-#{p.id}-queue[data-mq-badge]")

      assert has_element?(
               lv,
               "#mobile-board-#{p.id} button[data-entry='1-0'][phx-click='set_result']"
             )
    end

    test "a helper calls the arbiter; a deputy logs any incident", %{conn: conn} do
      t = tournament(user_scope_fixture())
      [p | _] = boards(t, 1)

      {helper_conn, _} = phone(conn, t, level: "helper")
      {:ok, lv, _} = live(helper_conn, ~p"/m/results")

      assert has_element?(lv, "#mobile-incident-#{p.id}[data-incident]", "Call arbiter")
      assert has_element?(lv, "#manubrium-incident input[value='arbiter_call']")
      refute has_element?(lv, "#manubrium-incident input[value='clock']")

      {deputy_conn, _} = phone(build_conn(), t, level: "deputy")
      {:ok, lv, _} = live(deputy_conn, ~p"/m/results")

      assert has_element?(lv, "#mobile-incident-#{p.id}", "Incident")

      for kind <- Incidents.kinds() do
        assert has_element?(lv, "#manubrium-incident input[value='#{kind}']")
      end
    end

    test "the board range narrows the list, and is only offered past six boards", %{conn: conn} do
      t = tournament(user_scope_fixture())
      pairings = boards(t, 8)
      {conn, _} = phone(conn, t, level: "deputy")

      {:ok, lv, _} = live(conn, ~p"/m/results")
      assert has_element?(lv, "#hall-filter")

      lv |> form("#hall-filter", %{"filter" => %{"from" => "3", "to" => "4"}}) |> render_change()

      shown = for p <- pairings, has_element?(lv, "#mobile-board-#{p.id}"), do: p.board
      assert shown == [3, 4]

      lv |> form("#hall-filter", %{"filter" => %{"from" => "", "to" => ""}}) |> render_change()
      assert Enum.all?(pairings, &has_element?(lv, "#mobile-board-#{&1.id}"))

      few = tournament(user_scope_fixture())
      boards(few, 3)
      {few_conn, _} = phone(build_conn(), few, level: "deputy")
      {:ok, lv, _} = live(few_conn, ~p"/m/results")
      refute has_element?(lv, "#hall-filter")
    end

    test "a board the queue is sending stays on screen after its result lands", %{conn: conn} do
      t = tournament(user_scope_fixture())
      [p, other] = boards(t, 2)
      {conn, e} = phone(conn, t, level: "helper")
      {:ok, lv, _} = live(conn, ~p"/m/results")

      render_hook(lv, "manubrium_hold", %{"ids" => [to_string(p.id), "999999"]})

      # The queue's write, as /m/sync makes it.
      {:ok, _} =
        Sync.submit(e.id, [
          %{
            "cid" => Ecto.UUID.generate(),
            "enrollment" => e.id,
            "kind" => "result",
            "round" => 1,
            "pairing" => p.id,
            "board" => 1,
            "white" => p.white_player_id,
            "black" => p.black_player_id,
            "result" => "1-0",
            "expected" => ""
          }
        ])

      send(lv.pid, {:tournament_changed, t.id, nil})
      assert has_element?(lv, "#mobile-board-#{p.id}")

      html = render_hook(lv, "manubrium_settle", %{"ids" => [p.id]})
      assert html =~ "Board 1: saved."
      assert has_element?(lv, "#mobile-board-#{p.id}.just-saved")
      assert has_element?(lv, "#mobile-board-#{other.id}")
    end
  end

  describe "the incidents page" do
    setup :register_and_log_in_user

    test "lists what the phones logged, newest first, round by round", %{conn: conn, scope: scope} do
      t = tournament(scope)
      [p1, p2] = boards(t, 2)
      {:ok, deputy} = Mobile.create_enrollment(t.id, level: "deputy", label: "Hall B")
      incident(deputy, p1, "clock")
      incident(deputy, p2, "device")

      {:ok, lv, html} = live(conn, ~p"/t/#{t.id}/incidents")

      assert has_element?(lv, "#incidents tbody tr", "Clock problem")
      assert has_element?(lv, "#incidents tbody tr", "Phone or electronic device")
      assert html =~ "W1"
      assert has_element?(lv, "#incidents td", "Hall B")
      assert has_element?(lv, "#incident-round-1", "(2)")

      lv |> element("#incident-round-1") |> render_click()
      assert_patch(lv, ~p"/t/#{t.id}/incidents?round=1")
      assert has_element?(lv, "#incidents tbody tr", "Clock problem")
    end

    test "shows a new one as it arrives, an arbiter call marked out", %{conn: conn, scope: scope} do
      t = tournament(scope)
      [p | _] = boards(t, 1)
      {:ok, helper} = Mobile.create_enrollment(t.id, level: "helper")

      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/incidents")
      assert has_element?(lv, "#incidents-empty")

      incident(helper, p, "arbiter_call")

      assert has_element?(lv, "#incidents tr.incident-call", "Arbiter call")
      refute has_element?(lv, "#incidents-empty")
    end

    test "is not open to someone else's tournament", %{conn: conn} do
      t = tournament(user_scope_fixture())

      assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/t/#{t.id}/incidents") end
    end

    test "the pairings page links to it, and says when the round has some", %{
      conn: conn,
      scope: scope
    } do
      t = tournament(scope)
      [p | _] = boards(t, 1)

      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/pairings")
      assert has_element?(lv, "#incidents-link[href='/t/#{t.id}/incidents']")
      refute has_element?(lv, "#round-incidents")

      {:ok, deputy} = Mobile.create_enrollment(t.id, level: "deputy")
      incident(deputy, p, "dispute")

      assert has_element?(
               lv,
               "#round-incidents a[href='/t/#{t.id}/incidents?round=1']",
               "1 incident"
             )
    end

    test "the phone code says Manubrium can be installed", %{conn: conn, scope: scope} do
      previous = Application.get_env(:pairings_engine, :local_mode)
      Application.put_env(:pairings_engine, :local_mode, false)

      on_exit(fn ->
        if is_nil(previous),
          do: Application.delete_env(:pairings_engine, :local_mode),
          else: Application.put_env(:pairings_engine, :local_mode, previous)
      end)

      t = tournament(scope)
      boards(t, 1)
      {:ok, lv, _} = live(conn, ~p"/t/#{t.id}/pairings")
      lv |> element("#phone-qr-link") |> render_click()
      lv |> form("#phone-qr-enroll-form", %{}) |> render_submit()

      assert has_element?(lv, "#phone-qr-manubrium", "Manubrium")
    end
  end
end
