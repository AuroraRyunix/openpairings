defmodule PairingsEngineWeb.HistoryLiveTest do
  use PairingsEngineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias PairingsEngine.{Audit, Repo, Snapshots, Tournaments}

  setup :register_and_log_in_user

  defp create_tournament(scope, attrs \\ %{}) do
    {:ok, tournament} =
      Tournaments.create_tournament(
        scope,
        Map.merge(%{"name" => "History Test", "type" => "swiss", "rounds_count" => "3"}, attrs)
      )

    tournament
  end

  describe "the timeline" do
    test "renders audit entries as prose, newest first", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      Audit.log(tournament.id, scope, "player.created", %{"player_name" => "Alice"})
      Audit.log(tournament.id, scope, "pairing.round_deleted", %{"round" => 2})

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/history")

      assert html =~ "Registered player Alice"
      assert html =~ "Unpaired round 2"

      # Newest first: the unpair was logged after the registration.
      assert :binary.match(html, "Unpaired round 2") |> elem(0) <
               :binary.match(html, "Registered player Alice") |> elem(0)
    end

    test "shows who did it, falling back to System for an unattributed row", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)

      Audit.log(tournament.id, scope, "player.created", %{"player_name" => "Alice"})
      Audit.log(tournament.id, nil, "player.created", %{"player_name" => "Bob"})

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/history")

      assert html =~ scope.user.email
      assert html =~ "System"
    end

    test "colour-codes each entry by category via a data attribute", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      Audit.log(tournament.id, scope, "player.created", %{"player_name" => "Alice"})
      Audit.log(tournament.id, scope, "pairing.round_deleted", %{"round" => 1})
      Audit.log(tournament.id, scope, "standings.manual_reseeded", %{})

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/history")

      assert html =~ ~s(data-kind="players")
      assert html =~ ~s(data-kind="pairings")
      assert html =~ ~s(data-kind="standings")
    end

    test "an unrecognised action still appears, under the neutral category", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      Audit.log(tournament.id, scope, "something.brand_new", %{})

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/history")

      assert html =~ "something.brand_new"
      assert html =~ ~s(data-kind="tournament")
    end

    test "groups entries under day headings", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      Audit.log(tournament.id, scope, "player.created", %{"player_name" => "Alice"})

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/history")

      assert html =~ "Today"
      assert html =~ "tl-day"
    end

    test "shows an empty state when there is nothing to show", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/history")

      assert html =~ "Nothing here yet"
    end
  end

  describe "field-level diffs" do
    test "a settings change renders before → after per field", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      Audit.log(tournament.id, scope, "tournament.settings_updated", %{
        "changed_fields" => %{
          "points_win" => [1.0, 3.0],
          "venue" => ["", "Town Hall"]
        }
      })

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/history")

      assert html =~ "tl-diff"
      # Field names are humanised, not raw schema names.
      assert html =~ "points win"
      assert html =~ "3.0"
      assert html =~ "Town Hall"
      # A blank "before" reads as a word, not an empty gap.
      assert html =~ "blank"
    end

    test "booleans and lists render readably rather than as raw terms", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)

      Audit.log(tournament.id, scope, "tournament.settings_updated", %{
        "changed_fields" => %{
          "categories_enabled" => [false, true],
          "tiebreaks" => [["BH"], ["BH", "SB"]]
        }
      })

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/history")

      assert html =~ ">on<"
      assert html =~ ">off<"
      assert html =~ "BH, SB"
    end

    test "an action with no changed_fields renders prose only, no diff block", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      Audit.log(tournament.id, scope, "logo.cleared", %{})

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/history")

      assert html =~ "Removed the tournament logo"
      refute html =~ "tl-diff-row"
    end
  end

  describe "restore points appear inline" do
    test "a snapshot shows on the timeline with its summary", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, _} =
        Snapshots.capture(tournament, "pairing.round_paired", scope,
          summary: "Before pairing round 1"
        )

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/history")

      assert html =~ ~s(data-kind="snapshot")
      assert html =~ "Before pairing round 1"
      assert html =~ "restore point"
    end

    test "snapshots and audit rows share one stream, ordered by time", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)

      # Both tables store whole seconds, so events written in the same second
      # can't be ordered by timestamp alone — space these out so the assertion
      # is about real chronology rather than the tiebreak.
      earlier = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:second)

      {:ok, snapshot} =
        Snapshots.capture(tournament, "pairing.round_paired", scope, summary: "Older point")

      Repo.update_all(
        from(s in PairingsEngine.Snapshots.Snapshot, where: s.id == ^snapshot.id),
        set: [inserted_at: earlier]
      )

      Audit.log(tournament.id, scope, "player.created", %{"player_name" => "Newer"})

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/history")

      newer_pos = :binary.match(html, "Registered player Newer") |> elem(0)
      older_pos = :binary.match(html, "Older point") |> elem(0)

      assert newer_pos < older_pos, "newest first: the audit row should render above the snapshot"
    end

    test "at an identical timestamp a snapshot sorts below the action it protects", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)

      # This is the real-world case: capture happens immediately before the
      # action, both land in the same second. A snapshot is taken *before* the
      # thing it guards, so it must read as the earlier of the two.
      {:ok, _} =
        Snapshots.capture(tournament, "pairing.round_deleted", scope,
          summary: "Before unpairing round 1"
        )

      Audit.log(tournament.id, scope, "pairing.round_deleted", %{"round" => 1})

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/history")

      action_pos = :binary.match(html, "Unpaired round 1") |> elem(0)
      snapshot_pos = :binary.match(html, "Before unpairing round 1") |> elem(0)

      assert action_pos < snapshot_pos
    end
  end

  describe "filtering" do
    test "narrows the stream to one category", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      Audit.log(tournament.id, scope, "player.created", %{"player_name" => "Alice"})
      Audit.log(tournament.id, scope, "pairing.round_deleted", %{"round" => 1})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/history")

      html = lv |> element(~s(button[phx-value-kind="players"])) |> render_click()

      assert html =~ "Registered player Alice"
      refute html =~ "Unpaired round 1"
    end

    test "the restore-points filter shows only snapshots", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      Audit.log(tournament.id, scope, "player.created", %{"player_name" => "Alice"})
      {:ok, _} = Snapshots.capture(tournament, "pairing.round_paired", scope, summary: "A point")

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/history")

      html = lv |> element(~s(button[phx-value-kind="snapshot"])) |> render_click()

      assert html =~ "A point"
      refute html =~ "Registered player Alice"
    end
  end

  describe "access and liveness" do
    test "another user's tournament is not reachable", %{conn: conn} do
      other = PairingsEngine.AccountsFixtures.user_fixture()
      other_scope = PairingsEngine.Accounts.Scope.for_user(other)
      theirs = create_tournament(other_scope)

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/t/#{theirs.id}/history")
      end
    end

    test "a new snapshot appears live via PubSub, without a reload", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/history")
      refute html =~ "Appeared live"

      {:ok, _} =
        Snapshots.capture(tournament, "pairing.round_paired", scope, summary: "Appeared live")

      # Any tournament write broadcasts; use one to nudge the page.
      {:ok, _} = Tournaments.update_tournament(tournament, %{"venue" => "Nudge"})

      assert render(lv) =~ "Appeared live"
    end

    test "an archived tournament's history is still readable", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      Audit.log(tournament.id, scope, "player.created", %{"player_name" => "Alice"})
      {:ok, _} = Tournaments.archive_tournament(tournament)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/history")

      assert html =~ "Registered player Alice"
      assert html =~ "This tournament is archived"
    end
  end

  describe "cross-links" do
    test "the three history views link to each other", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      for path <- [
            ~p"/t/#{tournament.id}/history",
            ~p"/t/#{tournament.id}/audit",
            ~p"/t/#{tournament.id}/audit/explain"
          ] do
        {:ok, _lv, html} = live(conn, path)

        assert html =~ ~s(href="/t/#{tournament.id}/history")
        assert html =~ ~s(href="/t/#{tournament.id}/audit")
        assert html =~ ~s(href="/t/#{tournament.id}/audit/explain")
      end
    end

    test "reachable from the Advanced menu", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/players")

      assert html =~ ~s(href="/t/#{tournament.id}/history")
    end
  end

  describe "restoring from the timeline" do
    alias PairingsEngine.Tournaments.{Pairing, Player, Round}

    defp restorable(scope) do
      t = create_tournament(scope, %{"name" => "Restorable"})
      a = Repo.insert!(%Player{tournament_id: t.id, name: "Alice"})
      b = Repo.insert!(%Player{tournament_id: t.id, name: "Bob"})
      r = Repo.insert!(%Round{tournament_id: t.id, number: 1, status: "finished"})

      Repo.insert!(%Pairing{
        round_id: r.id,
        board: 1,
        white_player_id: a.id,
        black_player_id: b.id,
        result: "1-0"
      })

      {:ok, snapshot} = Snapshots.capture(t, "manual", scope, summary: "Known good")
      {t, snapshot}
    end

    test "each restore point offers a Go back button", %{conn: conn, scope: scope} do
      {tournament, _snapshot} = restorable(scope)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/history")

      assert html =~ "Go back to here"
      assert html =~ ~s(phx-click="restore_start")
    end

    test "ordinary audit entries offer no restore button", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      Audit.log(tournament.id, scope, "player.created", %{"player_name" => "Alice"})

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/history")

      refute html =~ "Go back to here"
    end

    test "the confirm modal explains the consequences and requires typing RESTORE", %{
      conn: conn,
      scope: scope
    } do
      {tournament, snapshot} = restorable(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/history")

      html = render_click(lv, "restore_start", %{"id" => to_string(snapshot.id)})

      assert html =~ "Go back to this point"
      assert html =~ "This overwrites live results"
      assert html =~ "Known good"
      # The confirm button starts disabled.
      assert html =~ ~r/<button[^>]*disabled[^>]*>\s*Go back to this point/
    end

    test "a wrong confirmation word does nothing", %{conn: conn, scope: scope} do
      {tournament, snapshot} = restorable(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/history")
      render_click(lv, "restore_start", %{"id" => to_string(snapshot.id)})
      render_change(lv, "restore_confirm_input", %{"confirm" => "restore"})

      # Add something after the snapshot so we can tell whether it was wiped.
      Repo.insert!(%Player{tournament_id: tournament.id, name: "Added Later"})

      render_submit(lv, "restore_confirmed", %{})

      assert tournament.id
             |> Tournaments.list_players()
             |> Enum.any?(&(&1.name == "Added Later"))
    end

    test "typing RESTORE performs the restore and reports it", %{conn: conn, scope: scope} do
      {tournament, snapshot} = restorable(scope)
      Repo.insert!(%Player{tournament_id: tournament.id, name: "Added Later"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/history")
      render_click(lv, "restore_start", %{"id" => to_string(snapshot.id)})
      render_change(lv, "restore_confirm_input", %{"confirm" => "RESTORE"})

      html = render_submit(lv, "restore_confirmed", %{})

      assert html =~ "Restored."

      names = tournament.id |> Tournaments.list_players() |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["Alice", "Bob"]
    end

    test "restoring is audit-logged and appears on the timeline in prose", %{
      conn: conn,
      scope: scope
    } do
      {tournament, snapshot} = restorable(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/history")
      render_click(lv, "restore_start", %{"id" => to_string(snapshot.id)})
      render_change(lv, "restore_confirm_input", %{"confirm" => "RESTORE"})
      html = render_submit(lv, "restore_confirmed", %{})

      assert html =~ "Restored the tournament back to"
      assert html =~ "Known good"

      actions = tournament.id |> Audit.list_for_tournament() |> Enum.map(& &1.action)
      assert "snapshot.restored" in actions
    end

    test "the restore leaves a new pinned restore point to come back to", %{
      conn: conn,
      scope: scope
    } do
      {tournament, snapshot} = restorable(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/history")
      render_click(lv, "restore_start", %{"id" => to_string(snapshot.id)})
      render_change(lv, "restore_confirm_input", %{"confirm" => "RESTORE"})
      render_submit(lv, "restore_confirmed", %{})

      assert [newest | _] = Snapshots.list(tournament.id)
      assert newest.trigger == "snapshot.restored"
      assert newest.pinned
    end

    test "cancelling closes the modal without touching anything", %{conn: conn, scope: scope} do
      {tournament, snapshot} = restorable(scope)
      Repo.insert!(%Player{tournament_id: tournament.id, name: "Added Later"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/history")
      render_click(lv, "restore_start", %{"id" => to_string(snapshot.id)})
      html = render_click(lv, "restore_cancel", %{})

      refute html =~ "This overwrites live results"

      assert tournament.id
             |> Tournaments.list_players()
             |> Enum.any?(&(&1.name == "Added Later"))
    end

    test "an archived tournament offers no restore button at all", %{conn: conn, scope: scope} do
      {tournament, _snapshot} = restorable(scope)
      {:ok, _} = Tournaments.archive_tournament(tournament)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/history")

      # The restore points are still listed and readable — just not actionable.
      assert html =~ "Known good"
      refute html =~ "Go back to here"
    end

    test "a snapshot id from another tournament can't be reached", %{conn: conn, scope: scope} do
      {mine, _} = restorable(scope)
      {_theirs, their_snapshot} = restorable(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{mine.id}/history")

      # restore_start silently ignores an id that isn't this tournament's,
      # so no modal opens and nothing can be confirmed against it.
      html = render_click(lv, "restore_start", %{"id" => to_string(their_snapshot.id)})

      refute html =~ "This overwrites live results"
    end
  end

  describe "the payload is never loaded for the list" do
    test "snapshot rows on the timeline carry no payload", %{scope: scope} do
      tournament = create_tournament(scope)
      {:ok, _} = Snapshots.capture(tournament, "pairing.round_paired", scope, summary: "X")

      # Guards against a future refactor pulling whole tournament copies into
      # the list view — Snapshots.list/2 deliberately nils the payload out.
      assert [row] = Snapshots.list(tournament.id)
      assert row.payload == nil
      assert Repo.reload!(row).payload
    end
  end
end
