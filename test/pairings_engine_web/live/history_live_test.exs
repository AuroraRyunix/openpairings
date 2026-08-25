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

  # A restore point to hang changes off, since changes are no longer
  # top-level rows: they are folded under the point they followed. Returns the
  # snapshot so a test can address its disclosure button.
  defp point(scope, tournament, summary \\ "P") do
    {:ok, snapshot} = Snapshots.capture(tournament, "manual", scope, summary: summary)
    snapshot
  end

  # Opens a point's "N changes after this point" disclosure and returns the
  # rendered HTML. Collapsed is the default, so any assertion about a change
  # has to go through this.
  defp open_changes(lv, snapshot) do
    lv
    |> element(~s(button[phx-click="toggle_changes"][phx-value-id="snapshot-#{snapshot.id}"]))
    |> render_click()
  end

  defp reload(tournament), do: Repo.reload!(tournament)

  describe "changes folded under a restore point" do
    # Audit rows used to be timeline rows in their own right, peers of the
    # restore points. They are now folded under the point they followed, for
    # two reasons that both showed up in use: a hand-saved point wrote an
    # audit row AND a snapshot so it appeared twice, and audit rows carry no
    # branch information, so after switching to a branch a result change still
    # rendered on the trunk - which is not where the tournament was.
    test "they are hidden until the point is opened", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      snapshot = point(scope, tournament)
      Audit.log(tournament.id, scope, "player.created", %{"player_name" => "Alice"})

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/history")

      assert html =~ "1 change after this point"
      refute html =~ "Registered player Alice"

      assert open_changes(lv, snapshot) =~ "Registered player Alice"
    end

    test "renders them as prose, newest first", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      snapshot = point(scope, tournament)

      Audit.log(tournament.id, scope, "player.created", %{"player_name" => "Alice"})
      Audit.log(tournament.id, scope, "pairing.round_deleted", %{"round" => 2})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/history")
      html = open_changes(lv, snapshot)

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
      snapshot = point(scope, tournament)

      Audit.log(tournament.id, scope, "player.created", %{"player_name" => "Alice"})
      Audit.log(tournament.id, nil, "player.created", %{"player_name" => "Bob"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/history")
      html = open_changes(lv, snapshot)

      assert html =~ scope.user.email
      assert html =~ "System"
    end

    test "colour-codes each change by category via a data attribute", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      snapshot = point(scope, tournament)

      Audit.log(tournament.id, scope, "player.created", %{"player_name" => "Alice"})
      Audit.log(tournament.id, scope, "pairing.round_deleted", %{"round" => 1})
      Audit.log(tournament.id, scope, "standings.manual_reseeded", %{})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/history")
      html = open_changes(lv, snapshot)

      assert html =~ ~s(data-kind="players")
      assert html =~ ~s(data-kind="pairings")
      assert html =~ ~s(data-kind="standings")
    end

    test "an unrecognised action still appears, under the neutral category", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      snapshot = point(scope, tournament)
      Audit.log(tournament.id, scope, "something.brand_new", %{})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/history")
      html = open_changes(lv, snapshot)

      assert html =~ "something.brand_new"
      assert html =~ ~s(data-kind="tournament")
    end

    test "changes older than every restore point are counted, not listed", %{
      conn: conn,
      scope: scope
    } do
      # They have no point to hang off, and this page is about the points.
      tournament = create_tournament(scope)
      Audit.log(tournament.id, scope, "player.created", %{"player_name" => "Alice"})

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/history")

      refute html =~ "Registered player Alice"
      assert html =~ "1 change predates the oldest restore point"
      assert html =~ ~p"/t/#{tournament.id}/audit"
    end

    test "a tournament with nothing at all says so", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/history")

      assert html =~ "No restore points yet"
    end

    test "there is no kind filter here - that is the audit trail's job", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      point(scope, tournament)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/history")

      refute html =~ ~s(phx-click="filter")
    end
  end

  describe "field-level diffs" do
    test "a settings change renders before → after per field", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      snapshot = point(scope, tournament)

      Audit.log(tournament.id, scope, "tournament.settings_updated", %{
        "changed_fields" => %{
          "points_win" => [1.0, 3.0],
          "venue" => ["", "Town Hall"]
        }
      })

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/history")
      html = open_changes(lv, snapshot)

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
      snapshot = point(scope, tournament)

      Audit.log(tournament.id, scope, "tournament.settings_updated", %{
        "changed_fields" => %{
          "categories_enabled" => [false, true],
          "tiebreaks" => [["BH"], ["BH", "SB"]]
        }
      })

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/history")
      html = open_changes(lv, snapshot)

      assert html =~ ">on<"
      assert html =~ ">off<"
      assert html =~ "BH, SB"
    end

    test "an action with no changed_fields renders prose only, no diff block", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      snapshot = point(scope, tournament)
      Audit.log(tournament.id, scope, "logo.cleared", %{})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/history")
      html = open_changes(lv, snapshot)

      assert html =~ "Removed the tournament logo"
      refute html =~ "tl-diff-row"
    end
  end

  describe "restore points are the timeline" do
    test "a point shows with its summary and its own stamp", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, _} =
        Snapshots.capture(tournament, "pairing.round_paired", scope,
          summary: "Before pairing round 1"
        )

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/history")

      assert html =~ "Before pairing round 1"
      assert html =~ "hist-row"
      # Day headings are gone -- one collapsed branch can stand in for points
      # spanning several days, which headings could not survive -- so the date
      # lives on the row itself.
      assert html =~ "Today"
    end

    test "points read newest first", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      # Both tables store whole seconds, so points written in the same second
      # can't be ordered by timestamp alone - space these out so the assertion
      # is about real chronology rather than the tiebreak.
      earlier = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:second)

      {:ok, snapshot} =
        Snapshots.capture(tournament, "pairing.round_paired", scope, summary: "Older point")

      Repo.update_all(
        from(s in PairingsEngine.Snapshots.Snapshot, where: s.id == ^snapshot.id),
        set: [inserted_at: earlier]
      )

      {:ok, _} = Snapshots.capture(reload(tournament), "manual", scope, summary: "Newer point")

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/history")

      assert :binary.match(html, "Newer point") |> elem(0) <
               :binary.match(html, "Older point") |> elem(0)
    end

    test "the change a point protects is folded under it, not above it", %{
      conn: conn,
      scope: scope
    } do
      # The real-world shape: capture happens immediately before the action it
      # guards, both landing in the same second. Ordering them against each
      # other used to need a tiebreak; now the action is simply one of the
      # point's own changes, which is what it is.
      tournament = create_tournament(scope)

      {:ok, snapshot} =
        Snapshots.capture(tournament, "pairing.round_deleted", scope,
          summary: "Before unpairing round 1"
        )

      Audit.log(tournament.id, scope, "pairing.round_deleted", %{"round" => 1})

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/history")

      assert html =~ "Before unpairing round 1"
      refute html =~ "Unpaired round 1"

      assert open_changes(lv, snapshot) =~ "Unpaired round 1"
    end
  end

  describe "saving a restore point by hand" do
    test "the button is offered, and the empty state points at it", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/history")

      assert html =~ "Save restore point"
      assert html =~ ~s(phx-submit="snapshot_save")
      # The reported symptom was silence: a tournament nobody has paired has
      # no snapshots, so every restore button is hidden and the page looks
      # read-only. Say so instead.
      assert html =~ "No restore points yet"
    end

    test "saving one puts it on the timeline, labelled and marked as manual", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/history")
      html = render_submit(lv, "snapshot_save", %{"label" => "End of day 1"})

      assert html =~ "Restore point saved"
      assert html =~ "End of day 1"
      assert html =~ "hist-row"
      # Distinct from an automatic one.
      assert html =~ "saved by hand"
      # And the empty-state prompt is gone.
      refute html =~ "No restore points yet"

      assert [snapshot] = Snapshots.list(tournament.id)
      assert snapshot.trigger == "snapshot.manual"
      assert snapshot.summary == "End of day 1"
      refute snapshot.pinned
    end

    test "an unlabelled one still reads sensibly", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/history")
      html = render_submit(lv, "snapshot_save", %{"label" => "   "})

      assert html =~ "Manual restore point"
      assert [snapshot] = Snapshots.list(tournament.id)
      assert snapshot.summary == "Manual restore point"
    end

    test "an over-long label is trimmed rather than stored whole", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/history")
      render_submit(lv, "snapshot_save", %{"label" => String.duplicate("x", 400)})

      assert [snapshot] = Snapshots.list(tournament.id)
      assert String.length(snapshot.summary) == 120
    end

    test "it is written to the audit trail and reads as prose", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/history")
      html = render_submit(lv, "snapshot_save", %{"label" => "Before the appeal"})

      rows = Audit.list_for_tournament(tournament.id)
      assert row = Enum.find(rows, &(&1.action == "snapshot.manual"))
      assert row.user_id == scope.user.id
      assert row.details["label"] == "Before the appeal"
      assert row.details["snapshot_id"]

      # ...but it is NOT echoed onto this page. The point itself is the
      # event here; rendering both put the same action on screen twice.
      refute html =~ "Saved a restore point"
    end

    test "the tournament follows to the new point, so it isn't offered as a jump", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/history")
      html = render_submit(lv, "snapshot_save", %{"label" => "Now"})

      # Capturing advances HEAD, so the point just saved IS where the
      # tournament is - nothing to go back to yet.
      assert html =~ "the tournament is here"
      refute html =~ "Go back to here"

      assert [snapshot] = Snapshots.list(tournament.id)
      assert Repo.reload!(tournament).head_snapshot_id == snapshot.id
    end

    test "a hand-saved point is restorable once there is a later one", %{
      conn: conn,
      scope: scope
    } do
      alias PairingsEngine.Tournaments.Player

      tournament = create_tournament(scope, %{"name" => "Hand run"})
      Repo.insert!(%Player{tournament_id: tournament.id, name: "Alice"})

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/history")
      render_submit(lv, "snapshot_save", %{"label" => "Roster checked"})

      # Carry on by hand, then mark that too - now the first one is behind
      # HEAD and can actually be jumped back to.
      Repo.insert!(%Player{tournament_id: tournament.id, name: "Typo McTypo"})
      html = render_submit(lv, "snapshot_save", %{"label" => "After the typo"})

      assert html =~ "Go back to here"

      [_newer, older] = Snapshots.list(tournament.id)
      assert older.summary == "Roster checked"

      render_click(lv, "restore_start", %{"id" => to_string(older.id)})
      render_change(lv, "restore_confirm_input", %{"confirm" => "RESTORE"})
      html = render_submit(lv, "restore_confirmed", %{})

      assert html =~ "Restored."

      names = tournament.id |> Tournaments.list_players() |> Enum.map(& &1.name)
      assert names == ["Alice"]
    end

    test "an archived tournament refuses, and isn't offered the button", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope)
      {:ok, _} = Tournaments.archive_tournament(tournament)

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/history")
      refute html =~ "Save restore point"

      # The event is still client-supplied, so the handler has to refuse too.
      html = render_submit(lv, "snapshot_save", %{"label" => "Sneaky"})

      assert html =~ "This tournament is archived"
      assert Snapshots.count(tournament.id) == 0
      assert Audit.list_for_tournament(tournament.id) == []
    end

    test "a hand-saved point stands on the timeline like any other", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/history")
      html = render_submit(lv, "snapshot_save", %{"label" => "Kept by hand"})

      assert html =~ "Kept by hand"
      assert html =~ "saved by hand"
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
      snapshot = point(scope, tournament, "Final state")
      Audit.log(tournament.id, scope, "player.created", %{"player_name" => "Alice"})
      {:ok, _} = Tournaments.archive_tournament(tournament)

      {:ok, lv, html} = live(conn, ~p"/t/#{tournament.id}/history")

      assert html =~ "Final state"
      assert html =~ "This tournament is archived"

      # Readable, including the folded detail - archiving stops writes, not
      # reads, and the disclosure is a read.
      assert open_changes(lv, snapshot) =~ "Registered player Alice"
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

      # A second capture so the first is behind HEAD and therefore something
      # you can actually go *back* to - capturing advances HEAD, so a lone
      # snapshot is where the tournament already is.
      {:ok, _later} = Snapshots.capture(Repo.reload!(t), "manual", scope, summary: "Later")

      {Repo.reload!(t), snapshot}
    end

    test "a restore point behind HEAD offers a Go back button", %{conn: conn, scope: scope} do
      {tournament, _snapshot} = restorable(scope)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/history")

      assert html =~ "Go back to here"
      assert html =~ ~s(phx-click="restore_start")
    end

    test "the point the tournament is already at is marked, and offers no button", %{
      conn: conn,
      scope: scope
    } do
      tournament = create_tournament(scope, %{"name" => "At Head"})
      {:ok, _} = Snapshots.capture(tournament, "manual", scope, summary: "Only point")

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/history")

      assert html =~ "the tournament is here"
      # Nothing to go back to - you're already there.
      refute html =~ "Go back to here"
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

      # The restore's own audit row is a change under the new point, not a
      # row beside it, so it takes opening that point to read.
      assert html =~ "Known good"
      refute html =~ "Restored the tournament back to"

      newest = tournament.id |> Snapshots.list() |> List.first()

      assert lv
             |> element(
               ~s(button[phx-click="toggle_changes"][phx-value-id="snapshot-#{newest.id}"])
             )
             |> render_click() =~ "Restored the tournament back to"

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

      # The restore points are still listed and readable - just not actionable.
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

  describe "the branch view" do
    alias PairingsEngine.Tournaments.Player

    # Builds: base -> abandoned, and base -> (restored) -> current.
    defp branched(scope) do
      t = create_tournament(scope, %{"name" => "Branched"})
      Repo.insert!(%Player{tournament_id: t.id, name: "Common"})

      {:ok, base} = Snapshots.capture(t, "manual", scope, summary: "Base point")

      Repo.insert!(%Player{tournament_id: t.id, name: "Abandoned Line"})

      {:ok, abandoned} =
        Snapshots.capture(Repo.reload!(t), "manual", scope, summary: "Left behind")

      {:ok, _} = Snapshots.restore(Repo.reload!(t), base.id, scope)

      {Repo.reload!(t), base, abandoned}
    end

    test "an unbranched history says nothing about branching", %{conn: conn, scope: scope} do
      tournament = create_tournament(scope)
      {:ok, _} = Snapshots.capture(tournament, "manual", scope, summary: "One")

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/history")

      refute html =~ "This history has"
      refute html =~ "off-trunk"
    end

    test "a branched history explains itself and marks the off-trunk line", %{
      conn: conn,
      scope: scope
    } do
      {tournament, _base, _abandoned} = branched(scope)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/history")

      assert html =~ "This history has"
      assert html =~ "branched"
      # The abandoned line is rendered aside from the trunk.
      assert html =~ "off-trunk"
    end

    test "the abandoned line offers a switch, not a go-back", %{conn: conn, scope: scope} do
      {tournament, _base, _abandoned} = branched(scope)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/history")

      assert html =~ "Switch to this branch"
    end

    test "lanes are exposed for the rail to position entries", %{conn: conn, scope: scope} do
      {tournament, _base, _abandoned} = branched(scope)

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/history")

      # Trunk entries at lane 0, the abandoned one further out.
      assert html =~ "--hist-lane: 0"
      assert html =~ ~r/--hist-lane: [1-9]/
      # An off-trunk row is marked so it can be de-emphasised, and offers the
      # control that folds its whole branch away.
      assert html =~ "off-trunk"
      assert html =~ ~s(phx-click="toggle_branch")
    end

    test "the branch point itself is labelled", %{conn: conn, scope: scope} do
      {tournament, _base, _abandoned} = branched(scope)

      # Carrying on after the restore is what actually forks the tree.
      Repo.insert!(%Player{tournament_id: tournament.id, name: "New Line"})
      {:ok, _} = Snapshots.capture(Repo.reload!(tournament), "manual", scope, summary: "New line")

      {:ok, _lv, html} = live(conn, ~p"/t/#{tournament.id}/history")

      assert html =~ "branch point"
    end

    test "switching to the abandoned branch brings its data back", %{conn: conn, scope: scope} do
      {tournament, _base, abandoned} = branched(scope)

      refute tournament.id
             |> Tournaments.list_players()
             |> Enum.any?(&(&1.name == "Abandoned Line"))

      {:ok, lv, _html} = live(conn, ~p"/t/#{tournament.id}/history")
      render_click(lv, "restore_start", %{"id" => to_string(abandoned.id)})
      render_change(lv, "restore_confirm_input", %{"confirm" => "RESTORE"})
      render_submit(lv, "restore_confirmed", %{})

      assert tournament.id
             |> Tournaments.list_players()
             |> Enum.any?(&(&1.name == "Abandoned Line"))

      # And HEAD followed.
      assert Repo.reload!(tournament).head_snapshot_id == abandoned.id
    end
  end

  describe "the payload is never loaded for the list" do
    test "snapshot rows on the timeline carry no payload", %{scope: scope} do
      tournament = create_tournament(scope)
      {:ok, _} = Snapshots.capture(tournament, "pairing.round_paired", scope, summary: "X")

      # Guards against a future refactor pulling whole tournament copies into
      # the list view - Snapshots.list/2 deliberately nils the payload out.
      assert [row] = Snapshots.list(tournament.id)
      assert row.payload == nil
      assert Repo.reload!(row).payload
    end
  end
end
