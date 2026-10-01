defmodule PairingsEngineWeb.NextRoundPreviewLiveTest do
  @moduledoc """
  The "Preview next round" panel of the Pairings page and its print view.
  Ainalrami only, so no JVM. Not async: the panel's debounce and its runner
  are application settings for the duration of a test.
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias PairingsEngine.{NextRoundPreview, Repo, Tournaments}
  alias PairingsEngine.Pairing, as: Engine

  setup [:register_and_log_in_user]

  setup do
    Application.put_env(:pairings_engine, :next_round_preview_debounce_ms, 0)

    on_exit(fn ->
      Application.delete_env(:pairings_engine, :next_round_preview_debounce_ms)
      Application.delete_env(:pairings_engine, :next_round_preview_runner)
    end)
  end

  # `finished` rounds played to the end, and the next one paired.
  defp tournament(scope, players, finished \\ 0) do
    {:ok, t} =
      Tournaments.create_tournament(scope, %{
        "name" => "Preview",
        "type" => "swiss",
        "pairing_engine" => "ainalrami",
        "start_date" => "2026-07-01",
        "rounds_count" => "5",
        "round_dates" => List.duplicate("2026-07-01", 5),
        "tiebreaks" => ["BH", "SB"],
        "chief_arbiter" => "Jane Arbiter",
        "federation" => "BEL",
        "rate_of_play" => "90 min + 30 sec/move"
      })

    for i <- 1..players do
      {:ok, _} =
        Tournaments.create_player(t.id, %{
          "name" => "Player #{String.pad_leading(to_string(i), 2, "0")}",
          "fide_rating" => to_string(2300 - i * 10)
        })
    end

    for _ <- 1..finished//1 do
      {:ok, round} = Engine.pair_next_round(Tournaments.get_tournament!(t.id))

      for p <- Repo.preload(round, :pairings).pairings, p.black_player_id do
        {:ok, _} =
          Tournaments.update_pairing_result(p, Enum.at(~w(1-0 1/2-1/2 0-1), rem(p.board, 3)))
      end
    end

    {:ok, _round} = Engine.pair_next_round(Tournaments.get_tournament!(t.id))
    t
  end

  # Results on every board of the latest round but `open` of them - the first ones,
  # or the last ones - which it returns first.
  defp leave_open(t, open, where \\ :top) do
    round =
      t.id |> Tournaments.get_round(Engine.paired_rounds_count(t.id)) |> Repo.preload(:pairings)

    games = round.pairings |> Enum.filter(& &1.black_player_id) |> Enum.sort_by(& &1.board)
    games = if where == :top, do: games, else: Enum.reverse(games)

    games
    |> Enum.drop(open)
    |> Enum.each(&({:ok, _} = Tournaments.update_pairing_result(&1, "1-0")))

    games
  end

  test "offered while a few games are open, with the count", %{conn: conn, scope: scope} do
    t = tournament(scope, 10)
    leave_open(t, 2)

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

    assert has_element?(lv, "#next-round-preview-open")
    refute has_element?(lv, "#next-round-preview")
    refute has_element?(lv, "#next-round-preview-too-many")
  end

  test "above the cap it says so instead", %{conn: conn, scope: scope} do
    t = tournament(scope, 16)

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

    refute has_element?(lv, "#next-round-preview-open")
    assert has_element?(lv, "#next-round-preview-too-many", "8 games still open")
  end

  test "with JaVaFo it says the preview needs the built-in engine", %{conn: conn, scope: scope} do
    t = tournament(scope, 10)
    leave_open(t, 2)
    # Paired by Ainalrami above, so no JVM is needed; the engine is locked
    # once a round is paired, so it is switched in the row.
    Repo.update_all(
      from(x in PairingsEngine.Tournaments.Tournament, where: x.id == ^t.id),
      set: [pairing_engine: "javafo"]
    )

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

    assert has_element?(lv, "#next-round-preview-javafo")
    refute has_element?(lv, "#next-round-preview-open")
  end

  test "not offered once every result is in", %{conn: conn, scope: scope} do
    t = tournament(scope, 10)
    leave_open(t, 0)

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

    refute has_element?(lv, "#next-round-preview-open")
    refute has_element?(lv, "#next-round-preview-too-many")
  end

  test "opening it works the preview out in the background and shows the classes",
       %{conn: conn, scope: scope} do
    t = tournament(scope, 10)
    leave_open(t, 2)

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
    lv |> element("#next-round-preview-open") |> render_click()

    assert has_element?(lv, "#next-round-preview")
    assert has_element?(lv, "#next-round-preview-label")
    render_async(lv, 30_000)

    assert has_element?(lv, "#next-round-preview-summary")
    assert has_element?(lv, "#next-round-preview-results")
    assert has_element?(lv, "#next-round-preview-print")
    refute has_element?(lv, "#next-round-preview-progress")
    refute has_element?(lv, "#next-round-preview-error")

    lv |> element("#next-round-preview-close") |> render_click()
    refute has_element?(lv, "#next-round-preview")
    assert has_element?(lv, "#next-round-preview-open")
  end

  test "progress from the background run moves the bar, and closing cancels the run",
       %{conn: conn, scope: scope} do
    t = tournament(scope, 10)
    leave_open(t, 2)
    test = self()

    # Stands in for `NextRoundPreview.run/2`: hands the test its progress
    # callback and waits, so the run is still going while the test reports.
    Application.put_env(:pairings_engine, :next_round_preview_runner, fn tournament, opts ->
      send(test, {:runner, self(), Keyword.fetch!(opts, :progress)})

      receive do
        :finish -> NextRoundPreview.run(tournament)
      end
    end)

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
    lv |> element("#next-round-preview-open") |> render_click()

    assert_receive {:runner, runner, progress}
    assert has_element?(lv, "#next-round-preview-progress")

    progress.(0, 729)
    assert has_element?(lv, "#next-round-preview-count", "Paired 0 of 729 variants")
    assert has_element?(lv, "#next-round-preview-bar[value='0'][max='729']")
    refute has_element?(lv, "#next-round-preview-eta")

    progress.(212, 729)
    assert has_element?(lv, "#next-round-preview-count", "Paired 212 of 729 variants")
    assert has_element?(lv, "#next-round-preview-bar[value='212']")
    assert has_element?(lv, "#next-round-preview-eta", "left")

    ref = Process.monitor(runner)
    lv |> element("#next-round-preview-close") |> render_click()
    assert_receive {:DOWN, ^ref, :process, ^runner, _reason}
    refute has_element?(lv, "#next-round-preview")
  end

  test "a result entered while it is open works it out again", %{conn: conn, scope: scope} do
    t = tournament(scope, 10)
    [first, second | _] = leave_open(t, 2)

    {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
    lv |> element("#next-round-preview-open") |> render_click()
    render_async(lv, 30_000)
    assert has_element?(lv, "#next-round-preview-results", "9 outcomes")

    render_click(lv, "result", %{"pairing-id" => to_string(first.id), "result" => "0-1"})
    render_async(lv, 30_000)
    assert has_element?(lv, "#next-round-preview-results", "3 outcomes")

    # The last result: nothing left to preview - pair the round as usual.
    render_click(lv, "result", %{"pairing-id" => to_string(second.id), "result" => "1-0"})
    render_async(lv, 30_000)
    assert has_element?(lv, "#next-round-preview-done")
    refute has_element?(lv, "#next-round-preview-results")
  end

  describe "the print view" do
    test "prints the fixed boards and the name-card list once worked out",
         %{conn: conn, scope: scope} do
      t = tournament(scope, 24, 2)
      leave_open(t, 1, :bottom)

      assert conn |> get(~p"/t/#{t.id}/print/next-round-preview") |> response(409)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      lv |> element("#next-round-preview-open") |> render_click()
      render_async(lv, 30_000)

      html = conn |> get(~p"/t/#{t.id}/print/next-round-preview") |> html_response(200)
      doc = LazyHTML.from_document(html)

      assert LazyHTML.query(doc, "#nrp-print-warning") |> Enum.count() == 1
      assert LazyHTML.query(doc, "#nrp-print-fixed tbody tr") |> Enum.count() > 0
      assert LazyHTML.query(doc, "#nrp-print-cards tbody tr") |> Enum.count() > 0
    end

    test "refuses a preview the data has moved on from", %{conn: conn, scope: scope} do
      t = tournament(scope, 10)
      [open | _] = leave_open(t, 2)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
      lv |> element("#next-round-preview-open") |> render_click()
      render_async(lv, 30_000)
      lv |> element("#next-round-preview-close") |> render_click()

      {:ok, _} = Tournaments.update_pairing_result(open, "1/2-1/2")

      assert conn |> get(~p"/t/#{t.id}/print/next-round-preview") |> response(409)
    end
  end
end
