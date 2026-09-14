defmodule PairingsEngineWeb.TeamSwissLiveTest do
  @moduledoc """
  The pages team Swiss and the initial colour touch: Settings - Options (the
  initial-colour setting and its lock), Pairings (the colour line and the
  matches), Standings (the team table) and Teams (which notice shows).
  """
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import PairingsEngine.TeamFixtures

  alias PairingsEngine.{Pairing, Repo, Tournaments}

  setup :register_and_log_in_user

  defp teams(n), do: for(i <- 1..n, do: {"T#{i}", [2000 - i * 10, 1990 - i * 10]})

  defp swiss(scope, attrs \\ %{}) do
    {:ok, t} =
      Tournaments.create_tournament(
        scope,
        Map.merge(%{"name" => "Colour LV", "type" => "swiss", "rounds_count" => "5"}, attrs)
      )

    for {name, rating} <- [{"Alice", 2000}, {"Bob", 1900}, {"Carol", 1800}, {"Dave", 1700}] do
      {:ok, _} = Tournaments.create_player(t.id, %{"name" => name, "fide_rating" => "#{rating}"})
    end

    t
  end

  describe "Settings - Options: initial colour" do
    test "offers drawn by lot, White and Black, and saves a choice", %{conn: conn, scope: scope} do
      t = swiss(scope)
      {:ok, lv, html} = live(conn, ~p"/t/#{t.id}/settings/options")

      assert html =~ "Initial colour"
      assert has_element?(lv, "#initial-colour-select option[value='lot'][selected]")
      assert has_element?(lv, "#initial-colour-select option[value='white']")
      assert has_element?(lv, "#initial-colour-select option[value='black']")
      refute has_element?(lv, "#initial-colour-status")

      lv
      |> form("#pairing-settings-form", %{"tournament" => %{"initial_colour" => "black"}})
      |> render_submit()

      assert Repo.reload!(t).initial_colour == "black"
      assert render(lv) =~ "Initial colour: Black, set by the arbiter"
    end

    test "after round 1 it shows the draw and is locked", %{conn: conn, scope: scope} do
      t = swiss(scope)
      {:ok, _} = Pairing.pair_next_round(t)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/settings/options")

      assert has_element?(lv, "#initial-colour-select[disabled]")
      assert has_element?(lv, "#initial-colour-status", "Initial colour: drawn by lot: White")

      # A crafted save cannot change it.
      lv
      |> form("#pairing-settings-form")
      |> render_submit(%{"tournament" => %{"initial_colour" => "black"}})

      assert Repo.reload!(t).initial_colour == "lot"
    end
  end

  describe "Pairings" do
    test "shows the drawn initial colour once round 1 is paired", %{conn: conn, scope: scope} do
      t = swiss(scope)
      {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/pairings")
      refute html =~ "Initial colour:"

      {:ok, _} = Pairing.pair_next_round(t)
      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

      assert has_element?(lv, "#initial-colour", "Initial colour: drawn by lot: White")
    end

    test "a team Swiss lists its matches and the bye", %{conn: conn, scope: scope} do
      {t, _} = team_swiss(teams(3), user_id: scope.user.id)
      {:ok, _} = Pairing.pair_next_round(t)

      {:ok, lv, html} = live(conn, ~p"/t/#{t.id}/pairings")

      assert has_element?(lv, "#team-matches")
      assert html =~ "pairing-allocated bye, scored as a drawn match"
    end
  end

  describe "Standings" do
    test "a team Swiss paired by teams shows the team table", %{conn: conn, scope: scope} do
      {t, _} = team_swiss(teams(4), user_id: scope.user.id)
      {:ok, _} = Pairing.pair_next_round(t)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/standings")
      assert has_element?(lv, "#team-standings")
    end

    test "a team Swiss paired player by player keeps the individual table", %{
      conn: conn,
      scope: scope
    } do
      {t, _} = team_swiss(teams(4), user_id: scope.user.id, team_pairing_mode: "players")
      {:ok, _} = Pairing.pair_next_round(t)

      {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/standings")
      refute has_element?(lv, "#team-standings")
    end
  end

  ## ---------- what the arbiter sees when pairing gives up ----------

  # The pairing runs in a supervised task (`do_pair_team_swiss_async/1`), a
  # DIFFERENT process from the test - so anything a stub needs to know
  # (which reason to refuse with, who to report to) has to travel through
  # `Application.get_env/2`, not the test process's own dictionary.
  defmodule RefusingStub do
    @moduledoc "Always refuses with whatever reason the test configured."
    def pair_round(_teams, _opts),
      do: {:error, Application.fetch_env!(:pairings_engine, :team_swiss_lv_stub_reason)}
  end

  defmodule CrashingStub do
    @moduledoc "Always raises, to force the crash guard."
    def pair_round(_teams, _opts), do: raise("stub engine crash")
  end

  defmodule SlowStub do
    @moduledoc "Blocks until told to proceed, so the progress state can be observed mid-run."
    def pair_round(teams, opts) do
      test_pid = Application.fetch_env!(:pairings_engine, :team_swiss_lv_slow_test_pid)
      send(test_pid, {:slow_stub_started, self()})

      receive do
        :proceed -> Ainalrami.TeamPairing.pair_round(teams, opts)
      end
    end
  end

  defp with_stub(module, fun) do
    previous = Application.get_env(:pairings_engine, :team_pairing_module)
    Application.put_env(:pairings_engine, :team_pairing_module, module)

    try do
      fun.()
    after
      if previous,
        do: Application.put_env(:pairings_engine, :team_pairing_module, previous),
        else: Application.delete_env(:pairings_engine, :team_pairing_module)

      Application.delete_env(:pairings_engine, :team_swiss_lv_stub_reason)
      Application.delete_env(:pairings_engine, :team_swiss_lv_slow_test_pid)
    end
  end

  # The task's reply is a `handle_info` the LiveView process handles on its
  # own schedule - after `render_click/1` has already returned. Polls the
  # LiveView's OWN rendered output (not the database - the crash tests never
  # write one) until it carries `needle`, so every assertion below is
  # waiting on the same round trip the arbiter's browser would.
  defp wait_html(lv, needle, tries \\ 100) do
    html = render(lv)

    cond do
      html =~ needle -> html
      tries > 0 -> Process.sleep(10) && wait_html(lv, needle, tries - 1)
      true -> flunk("gave up waiting for #{inspect(needle)} in:\n#{html}")
    end
  end

  defp wait_html_gone(lv, needle, tries \\ 100) do
    html = render(lv)

    cond do
      not (html =~ needle) -> html
      tries > 0 -> Process.sleep(10) && wait_html_gone(lv, needle, tries - 1)
      true -> flunk("#{inspect(needle)} never disappeared from:\n#{html}")
    end
  end

  defp complete_team_swiss(scope) do
    {t, _} =
      team_swiss(
        teams(4),
        user_id: scope.user.id,
        rounds: 3,
        start_date: "2026-07-15",
        round_dates: ["2026-07-15", "2026-07-16", "2026-07-17"],
        chief_arbiter: "Jane Arbiter",
        federation: "BEL",
        rate_of_play: "90 min + 30 sec/move"
      )

    t
  end

  describe "Pairing round: what the arbiter sees when the search gives up" do
    test "budget_exhausted: nothing paired, a clear message, no crash", %{
      conn: conn,
      scope: scope
    } do
      t = complete_team_swiss(scope)
      Application.put_env(:pairings_engine, :team_swiss_lv_stub_reason, :budget_exhausted)

      with_stub(RefusingStub, fn ->
        {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
        lv |> element("button", "Pair round") |> render_click()

        html = wait_html(lv, "finish the pairing for round 1")
        assert html =~ "nothing changed"
        refute Tournaments.get_round(t.id, 1)
      end)
    end

    test "no_legal_pairing: explains the FIDE-rules refusal", %{conn: conn, scope: scope} do
      t = complete_team_swiss(scope)
      Application.put_env(:pairings_engine, :team_swiss_lv_stub_reason, :no_legal_pairing)

      with_stub(RefusingStub, fn ->
        {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
        lv |> element("button", "Pair round") |> render_click()

        html = wait_html(lv, "Round 1 can")
        assert html =~ "teams meeting twice"
        refute Tournaments.get_round(t.id, 1)
      end)
    end

    test "no_legal_bye: explains the bye-specific refusal", %{conn: conn, scope: scope} do
      t = complete_team_swiss(scope)
      Application.put_env(:pairings_engine, :team_swiss_lv_stub_reason, :no_legal_bye)

      with_stub(RefusingStub, fn ->
        {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
        lv |> element("button", "Pair round") |> render_click()

        html = wait_html(lv, "already had one or won a match by forfeit")
        assert html =~ "Round 1 can"
        refute Tournaments.get_round(t.id, 1)
      end)
    end

    test "an unexpected crash shows a generic message, not a raw atom or a page crash", %{
      conn: conn,
      scope: scope
    } do
      t = complete_team_swiss(scope)

      with_stub(CrashingStub, fn ->
        {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
        lv |> element("button", "Pair round") |> render_click()

        html = wait_html(lv, "Pairing failed unexpectedly")
        assert html =~ "Nothing was changed"
        refute html =~ "RuntimeError"
        refute Tournaments.get_round(t.id, 1)
        # The LiveView itself survived the crash - still there to click again.
        assert has_element?(lv, "button", "Pair round")
      end)
    end

    test "a refusal leaves the button enabled again, no stuck 'Pairing…' state", %{
      conn: conn,
      scope: scope
    } do
      t = complete_team_swiss(scope)
      Application.put_env(:pairings_engine, :team_swiss_lv_stub_reason, :budget_exhausted)

      with_stub(RefusingStub, fn ->
        {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")
        lv |> element("button", "Pair round") |> render_click()
        wait_html(lv, "finish the pairing")

        refute has_element?(lv, "button[disabled]", "Pairing round")
        refute render(lv) =~ "this can take up to a minute"
      end)
    end
  end

  describe "Pairing round: a slow search shows progress and guards against a double click" do
    test "shows a progress state while running, and a second click does not start a second search",
         %{conn: conn, scope: scope} do
      t = complete_team_swiss(scope)
      Application.put_env(:pairings_engine, :team_swiss_lv_slow_test_pid, self())

      with_stub(SlowStub, fn ->
        {:ok, lv, _html} = live(conn, ~p"/t/#{t.id}/pairings")

        html = lv |> element("button", "Pair round") |> render_click()
        assert html =~ "Pairing round 1"
        assert html =~ "this can take up to a minute"
        assert has_element?(lv, "button[disabled]")

        assert_receive {:slow_stub_started, stub_pid}, 1000

        # A second click while the search is still running. The DOM button
        # is `disabled` - `LiveViewTest` refuses to click a disabled element
        # at all, which already proves the belt half of "belt and braces".
        # The braces half - `handle_event("pair", ...)`'s own
        # `pairing_in_progress` guard, for a click that reaches the process
        # before the DOM patch lands - is exercised by sending the raw
        # event directly, the way a race would.
        render_click(lv, "pair", %{})
        refute_receive {:slow_stub_started, _}, 200

        send(stub_pid, :proceed)

        # The task's reply lands as a `handle_info`, which can trail the
        # database write by a beat - wait for the DATABASE round first...
        round = wait_round(t.id, 1)
        # ...then for the LiveView's OWN render to have caught up with it:
        # the progress text is gone once the round exists.
        wait_html_gone(lv, "this can take up to a minute")
        refute has_element?(lv, "button[phx-click='pair'][disabled]")
        assert length(Tournaments.list_matches(round.id)) == 2
      end)
    end
  end

  defp wait_round(tournament_id, number, tries \\ 100) do
    case Tournaments.get_round(tournament_id, number) do
      nil when tries > 0 ->
        Process.sleep(10)
        wait_round(tournament_id, number, tries - 1)

      nil ->
        flunk("round #{number} was never paired")

      round ->
        round
    end
  end

  describe "Teams" do
    test "a team Swiss paired by teams shows no not-by-team notice", %{conn: conn, scope: scope} do
      {t, _} = team_swiss(teams(4), user_id: scope.user.id)
      {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/teams")

      refute html =~ "pairs player by player"
      refute html =~ "Not paired by team"
    end

    test "an old team Swiss says it carries on player by player", %{conn: conn, scope: scope} do
      {t, _} = team_swiss(teams(4), user_id: scope.user.id, team_pairing_mode: "players")
      {:ok, _lv, html} = live(conn, ~p"/t/#{t.id}/teams")

      assert html =~ "This team Swiss pairs player by player"
    end
  end
end
