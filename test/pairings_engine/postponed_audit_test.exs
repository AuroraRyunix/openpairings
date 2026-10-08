defmodule PairingsEngine.PostponedAuditTest do
  @moduledoc """
  Audit of postponed games and the routes a game takes to a rating body
  (2026-10-01). The rule under audit: no game is ever sent for rating twice.

  The tests named F1-F7 each proved, when the audit was written, a way the
  code let a game (or a whole round) go out a second time, or go out wrong.
  They failed on purpose then, behind a `:postponed_audit` tag the default
  run excluded; each was fixed on branch `postponed-fixes` and the tag
  removed, so they run with everything else and guard the fix. The F4
  test's warning check was changed with its fix: it pinned the old,
  untruthful warning (see the comment there).

  The tests named GUARD stay as regression guards for the most dangerous
  scenarios that were already closed.

  Generated data only: no .swar fixtures, no real players.
  """
  # Not async: the race tests run two callers against one sandbox
  # connection, which needs the shared mode.
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{
    Pairing,
    PostponedGames,
    Repo,
    Snapshots,
    TournamentExport,
    TournamentImport,
    TrfExport,
    Tournaments
  }

  alias PairingsEngine.Tournaments.{Tournament, TrfSentGame}

  import Ecto.Query
  import PairingsEngine.AccountsFixtures, only: [user_scope_fixture: 0]

  ## ---------- fixtures (the same shape as postponed_reports_test.exs) ----------

  defp tournament(attrs \\ []) do
    t =
      Repo.insert!(
        struct(
          Tournament,
          Map.merge(
            %{
              name: "Audit club championship",
              type: "swiss",
              rounds_count: 3,
              tiebreaks: ~w(BH SB),
              postponed_games: true,
              round_dates: ["2026-09-01", "2026-09-08", "2026-09-15"]
            },
            Map.new(attrs)
          )
        )
      )

    players =
      for {name, rating} <- [{"Ann", 2000}, {"Ben", 1900}, {"Cas", 1800}, {"Dan", 1700}],
          into: %{} do
        {:ok, p} =
          Tournaments.create_player(t.id, %{tournament_id: t.id, name: name, fide_rating: rating})

        {name, p}
      end

    {t, players}
  end

  defp pair!(t) do
    {:ok, round} = Pairing.pair_next_round(Repo.reload!(t), [])
    Tournaments.get_round(t.id, round.number)
  end

  defp board_of(round, player),
    do: Enum.find(round.pairings, &(player.id in [&1.white_player_id, &1.black_player_id]))

  defp result!(pairing, result, opts \\ []) do
    {:ok, updated} = Tournaments.update_pairing_result(pairing, result, opts)
    updated
  end

  defp others!(round, except),
    do: for(p <- round.pairings, p.id != except.id, p.black_player_id, do: result!(p, "1-0"))

  defp all_results!(round),
    do: for(p <- round.pairings, p.black_player_id, do: result!(p, "1-0"))

  # Round 1 with Ann's game postponed and the other board played, round 1
  # sent (the postponed game as `?`), and the postponed game played since.
  defp late_game_ready!(played_on \\ ~D[2026-09-20]) do
    {t, players} = tournament()
    round1 = pair!(t)
    postponed = round1 |> board_of(players["Ann"]) |> result!("*W")
    others!(round1, postponed)
    {:ok, _} = PostponedGames.finalise(Repo.reload!(t), [1])

    postponed =
      result!(Repo.reload!(postponed), "1-0",
        acknowledged: [:adjourned_non_draw_result],
        played_on: played_on
      )

    {t, players, postponed}
  end

  defp sent_rows(t, kind),
    do: Repo.all(from s in TrfSentGame, where: s.tournament_id == ^t.id and s.kind == ^kind)

  defp rank(t, player_id),
    do: Enum.find(Tournaments.list_players(t.id), &(&1.id == player_id)).pairing_number

  ## ---------- the race: two "Send" requests at once ----------

  # Pauses the first query on `source` made by the process registered as
  # the target (or by a task it started - Ecto runs preloads in parallel
  # tasks), until it is sent `:go`. Lets a test put a second caller exactly
  # between another caller's reads and its writes, deterministically.
  def pause_after_query(_event, _measurements, metadata, %{test: test, once: once}) do
    target = :persistent_term.get({__MODULE__, :pause_target}, nil)
    callers = [self() | Process.get(:"$callers", [])]

    if target != nil and target in callers and metadata.source == "players" and
         :atomics.compare_exchange(once, 1, 0, 1) == :ok do
      send(test, {:paused, self()})

      receive do
        :go -> :ok
      end
    end

    :ok
  end

  defp with_pause_handler(fun) do
    id = "postponed-audit-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        id,
        [:pairings_engine, :repo, :query],
        &__MODULE__.pause_after_query/4,
        %{test: self(), once: :atomics.new(1, [])}
      )

    try do
      fun.()
    after
      :telemetry.detach(id)
      :persistent_term.erase({__MODULE__, :pause_target})
    end
  end

  describe "F1 - two Send… requests for the same round at once" do
    test "both finalise round 1: the round is sent twice and recorded twice" do
      {t, _players} = tournament()
      round1 = pair!(t)
      boards = all_results!(round1)
      t = Repo.reload!(t)

      {first, second} =
        with_pause_handler(fn ->
          # Request A: stops right after `finalise/2` has read the boards it
          # is about to mark (the players preload follows that read), i.e.
          # after its "already sent?" check and before its transaction.
          a =
            Task.async(fn ->
              :persistent_term.put({__MODULE__, :pause_target}, self())
              PostponedGames.finalise(t, [1])
            end)

          assert_receive {:paused, paused_pid}, 5_000

          # Request B (the second click, a second tab, a co-arbiter) runs to
          # the end in that gap.
          b = PostponedGames.finalise(t, [1])

          send(paused_pid, :go)
          {Task.await(a, 10_000), b}
        end)

      # The controller hands out a file for every `{:ok, _}` - so two
      # "sent" files for the same round leave the building.
      oks = Enum.count([first, second], &match?({:ok, _}, &1))

      assert oks == 1,
             "both requests finalised round 1: #{inspect(first)} / #{inspect(second)}"

      assert length(sent_rows(t, "report")) == length(boards)
    end
  end

  describe "F2 - two sends of the postponed-games file at once" do
    test "both carry the late game, and both are recorded as sent" do
      {t, _players, postponed} = late_game_ready!()

      # `ExportController.send_postponed_trf/4` builds the file, then marks
      # its games - two separate steps. Two requests interleave as below.
      {:ok, _text_a, games_a} = TrfExport.postponed_export(Repo.reload!(t))
      {:ok, _text_b, games_b} = TrfExport.postponed_export(Repo.reload!(t))
      assert [%{pairing: %{id: id}}] = games_a
      assert id == postponed.id

      :ok = PostponedGames.mark_late_games_sent(Repo.reload!(t), games_a)
      second = PostponedGames.mark_late_games_sent(Repo.reload!(t), games_b)

      assert second != :ok,
             "the second mark went through for a game already sent in a postponed-games file"

      assert length(sent_rows(t, "postponed")) == 1
    end
  end

  ## ---------- the copy left behind by a hand-off ----------

  describe "F3 - the locked copy left behind by a hand-off" do
    test "can still finalise (send) a round - the other machine can send it too" do
      {t, _players} = tournament()
      all_results!(pair!(t))

      {:ok, locked} = Tournaments.hand_off(Repo.reload!(t), "Arbiter laptop")
      assert {:error, :handed_off} = Tournaments.ensure_writable(locked)

      assert {:error, _} = PostponedGames.finalise(locked, [1])
    end

    test "can still mark a postponed-games file as sent" do
      {t, _players, _postponed} = late_game_ready!()
      {:ok, locked} = Tournaments.hand_off(Repo.reload!(t), "Arbiter laptop")
      {:ok, _text, games} = TrfExport.postponed_export(locked)

      refute PostponedGames.mark_late_games_sent(locked, games) == :ok
    end
  end

  ## ---------- a restore across a change of who a player is ----------

  describe "F4 - restore after a player's FIDE ID was filled in" do
    defp snapshot!(t) do
      {:ok, snapshot} = Snapshots.capture(Repo.reload!(t), "manual", nil)
      snapshot
    end

    test "makes a late game already sent in the postponed-games file sendable again" do
      {t, players, postponed} = late_game_ready!()
      played = snapshot!(t)

      # The arbiter adds Ann's FIDE ID (common: IDs are looked up later).
      ann = Repo.reload!(players["Ann"])
      {:ok, _} = Tournaments.update_player(ann, %{fide_id: 99_000_001})

      {:ok, _text, games} = TrfExport.postponed_export(Repo.reload!(t))
      :ok = PostponedGames.mark_late_games_sent(Repo.reload!(t), games)
      assert PostponedGames.sendable_late_games(Repo.reload!(t)) == []

      # Rolling back to the snapshot taken after the game was played. Before
      # the fix the warning said the sent game would be "taken away"
      # (`[%{kind: "postponed", restored: nil}]`, which this line asserted)
      # - untrue, it is still there under Ann's old key. The game is now
      # found by its identity, and the warning says what really happens:
      # nothing sent is lost or changed.
      assert Snapshots.sent_conflicts(Repo.reload!(t), played.id) == []

      {:ok, _} =
        Snapshots.restore(Repo.reload!(t), played.id, nil, acknowledged: [:sent_games_changed])

      # The same game (same round, same players, same colours) is offered
      # for a second postponed-games file.
      resendable =
        t |> Repo.reload!() |> PostponedGames.sendable_late_games() |> Enum.map(& &1.round)

      assert resendable == [],
             "game of round 1 (was board #{postponed.board}) is sendable again after the restore"
    end
  end

  ## ---------- a copy of the tournament that forgot what it sent ----------

  describe "F5 - an imported copy of an event that already sent a round" do
    test "a backup taken before sending, imported, sends the same round again" do
      {t, _players} = tournament(fide_tournament_id: "424242")
      all_results!(pair!(t))

      backup = t |> Repo.reload!() |> TournamentExport.export_tournament() |> over_the_wire()
      {:ok, _} = PostponedGames.finalise(Repo.reload!(t), [1])

      {:ok, [copy]} = TournamentImport.import(backup, user_scope_fixture())
      assert copy.fide_tournament_id == "424242"

      assert {:error, {:already_sent, [1]}} = PostponedGames.finalise(copy, [1])
    end

    test "GUARD: a backup taken after sending keeps the round and the late game unsendable" do
      {t, _players, _postponed} = late_game_ready!()
      {:ok, _text, games} = TrfExport.postponed_export(Repo.reload!(t))
      :ok = PostponedGames.mark_late_games_sent(Repo.reload!(t), games)

      backup = t |> Repo.reload!() |> TournamentExport.export_tournament() |> over_the_wire()
      {:ok, [copy]} = TournamentImport.import(backup, user_scope_fixture())

      assert {:error, {:already_sent, [1]}} = PostponedGames.finalise(copy, [1])
      assert {:error, :nothing_to_send} = TrfExport.postponed_export(copy)
    end
  end

  defp over_the_wire(envelope), do: envelope |> Jason.encode!() |> Jason.decode!()

  ## ---------- the rating period of a late game ----------

  describe "F6 - correcting the result of a late game" do
    test "moves the date it was played to today, and with it the rating period" do
      {t, _players, postponed} = late_game_ready!(~D[2026-09-20])
      assert Repo.reload!(postponed).played_on == ~D[2026-09-20]

      # A typo fixed before the postponed-games file goes out: no warning
      # is asked (nothing was sent with a result yet), and the date moves.
      result!(Repo.reload!(postponed), "0-1")

      assert Repo.reload!(postponed).played_on == ~D[2026-09-20]

      assert [%{pairing: %{played_on: ~D[2026-09-20]}}] =
               PostponedGames.sendable_late_games(Repo.reload!(t))
    end
  end

  ## ---------- a copy nobody can tell from the file that was sent ----------

  describe "F7 - Download a copy / All rounds (TRF) after a round was sent" do
    test "is byte-for-byte the file that was sent: nothing says it must not be sent again" do
      {t, _players} = tournament()
      all_results!(pair!(t))

      # What `ExportController.trf_send/2` hands out when round 1 is sent.
      {:ok, sent} = TrfExport.export(Repo.reload!(t), "1")
      {:ok, _} = PostponedGames.finalise(Repo.reload!(t), [1])

      # The "Download a copy" link and the "All rounds (TRF)" link.
      {:ok, copy} = TrfExport.export(Repo.reload!(t), "1")
      {:ok, all} = TrfExport.export(Repo.reload!(t), nil)

      refute copy == sent, "the copy of a sent round is identical to the file that was sent"
      refute all == sent, "the all-rounds download re-carries round 1, unmarked"
    end
  end

  ## ---------- guards: dangerous scenarios that are closed today ----------

  describe "guards" do
    test "GUARD: a round sent once is refused a second time, and the refusal holds after unpair attempts" do
      {t, _players} = tournament()
      all_results!(pair!(t))
      {:ok, 2} = PostponedGames.finalise(Repo.reload!(t), [1])

      assert {:error, {:already_sent, [1]}} = PostponedGames.finalise(Repo.reload!(t), [1])
      assert {:error, {:already_sent, [1]}} = PostponedGames.finalise(Repo.reload!(t), [1, 2])
      assert {:error, :round_sent_in_trf} = Pairing.delete_round(t.id, 1)
      assert length(sent_rows(t, "report")) == 2
    end

    test "GUARD: an open postponed game goes out as ? and never as a result, and not in a late file" do
      {t, players} = tournament()
      round1 = pair!(t)
      postponed = round1 |> board_of(players["Ann"]) |> result!("*W")
      others!(round1, postponed)
      # FIDE mode makes no TRF with a game open (Q169): record it as not
      # played in this event first, as the arbiter now has to.
      PairingsEngine.PostponedHelpers.report_open_games_not_played!(t)

      {:ok, text} = TrfExport.export(Repo.reload!(t), "1")
      {:ok, _} = PostponedGames.finalise(Repo.reload!(t), [1])

      for id <- [postponed.white_player_id, postponed.black_player_id] do
        line = line_of(text, rank(t, id))
        assert String.at(line, 98) == "?"
      end

      assert [%{sent_as: "?"}] =
               Enum.filter(
                 sent_rows(t, "report"),
                 &(&1.white_key =~ "ann" or &1.black_key =~ "ann")
               )

      # Still open: nothing for the postponed-games file.
      assert {:error, :nothing_to_send} = TrfExport.postponed_export(Repo.reload!(t))
    end

    test "GUARD: a game sent as ? is never in a later main report with its real result" do
      {t, _players, postponed} = late_game_ready!()

      for spec <- ["1", nil] do
        {:ok, text} = TrfExport.export(Repo.reload!(t), spec)
        line = line_of(text, rank(t, postponed.white_player_id))
        assert String.at(line, 98) == "?", inspect(spec)
      end
    end

    test "GUARD: the late file carries the game once, and a second file is refused" do
      {t, _players, postponed} = late_game_ready!()
      {:ok, _text, [game]} = TrfExport.postponed_export(Repo.reload!(t))
      assert game.pairing.id == postponed.id
      :ok = PostponedGames.mark_late_games_sent(Repo.reload!(t), [game])

      assert {:error, :nothing_to_send} = TrfExport.postponed_export(Repo.reload!(t))

      assert {:error, :nothing_to_send} =
               TrfExport.postponed_export(Repo.reload!(t), games: [postponed.id])
    end

    test "GUARD: a postponed game decided by forfeit reaches the late file only as an unrated forfeit" do
      {t, players} = tournament()
      round1 = pair!(t)
      postponed = round1 |> board_of(players["Ann"]) |> result!("*W")
      others!(round1, postponed)
      {:ok, _} = PostponedGames.finalise(Repo.reload!(t), [1])

      result!(Repo.reload!(postponed), "1-0FF", acknowledged: [:adjourned_non_draw_result])

      {:ok, text, [_game]} = TrfExport.postponed_export(Repo.reload!(t))
      parsed = Ainalrami.Trf.parse(text)

      assert parsed.players |> Enum.map(&hd(&1.games).result) |> Enum.sort() == ["+", "-"]
    end

    test "GUARD: a game played before its round was sent never reaches the late file" do
      {t, players} = tournament()
      round1 = pair!(t)
      postponed = round1 |> board_of(players["Ann"]) |> result!("*W")
      others!(round1, postponed)
      result!(postponed, "1-0", acknowledged: [:adjourned_non_draw_result])
      {:ok, _} = PostponedGames.finalise(Repo.reload!(t), [1])

      assert PostponedGames.sendable_late_games(Repo.reload!(t)) == []
      assert {:error, :nothing_to_send} = TrfExport.postponed_export(Repo.reload!(t))
    end

    test "GUARD: re-postponing and replaying a sent-as-? game still sends it once" do
      {t, _players, postponed} = late_game_ready!()
      # Back to open, then played again before the late file goes out.
      postponed = result!(Repo.reload!(postponed), "*W")
      result!(postponed, "1/2-1/2", played_on: ~D[2026-09-27])

      {:ok, _text, games} = TrfExport.postponed_export(Repo.reload!(t))
      assert length(games) == 1
      :ok = PostponedGames.mark_late_games_sent(Repo.reload!(t), games)

      result!(Repo.reload!(postponed), "*W", acknowledged: [:finalised_result_changed])

      result!(Repo.reload!(postponed), "1-0",
        acknowledged: [:finalised_result_changed, :adjourned_non_draw_result]
      )

      assert {:error, :nothing_to_send} = TrfExport.postponed_export(Repo.reload!(t))
      assert length(sent_rows(t, "postponed")) == 1
    end
  end

  # The `001` line of `rank`.
  defp line_of(text, rank) do
    text
    |> String.split("\r\n")
    |> Enum.find(fn line ->
      String.starts_with?(line, "001") and
        line |> String.slice(4, 4) |> String.trim() == Integer.to_string(rank)
    end)
  end
end
