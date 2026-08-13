defmodule PairingsEngine.TournamentsTest do
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Tournament, Player, Round, Pairing, ForbiddenPairing}
  alias PairingsEngine.Accounts.{Scope, User}

  # A lightweight stand-in for `PairingsEngine.AccountsFixtures.user_scope_fixture/0`
  # — these tests only need a persisted owner to satisfy the tournament's
  # `user_id` foreign key, not a full register/confirm/magic-link session.
  # Going through the real fixture here (several sequential writes per
  # call) under async/parallel execution was enough to starve SQLite's
  # single writer and intermittently fail with "database busy".
  defp user_scope do
    user =
      Repo.insert!(%User{
        email: "user#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    Scope.for_user(user)
  end

  describe "delete_tournament/1" do
    test "removes the tournament and cascades to its players, rounds, pairings and byes" do
      tournament = Repo.insert!(%Tournament{name: "Delete Me", type: "swiss", rounds_count: 3})

      white = Repo.insert!(%Player{tournament_id: tournament.id, name: "White"})
      black = Repo.insert!(%Player{tournament_id: tournament.id, name: "Black"})

      round =
        Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "finished"})

      pairing =
        Repo.insert!(%Pairing{
          round_id: round.id,
          board: 1,
          white_player_id: white.id,
          black_player_id: black.id,
          result: "1-0"
        })

      Repo.query!(
        "INSERT INTO byes (tournament_id, player_id, round, type) VALUES (?, ?, ?, ?)",
        [tournament.id, black.id, 2, "requested-half"]
      )

      assert {:ok, _} = Tournaments.delete_tournament(tournament)

      refute Repo.get(Tournament, tournament.id)
      refute Repo.get(Player, white.id)
      refute Repo.get(Player, black.id)
      refute Repo.get(Round, round.id)
      refute Repo.get(Pairing, pairing.id)

      assert Repo.all(from b in "byes", where: b.tournament_id == ^tournament.id, select: b.id) ==
               []
    end
  end

  describe "recycle bin (soft delete, 3-month retention)" do
    test "soft_delete_tournament/1 sets deleted_at and removes it from list_tournaments/1" do
      owner = user_scope()

      {:ok, tournament} =
        Tournaments.create_tournament(owner, %{"name" => "T", "type" => "swiss"})

      assert {:ok, deleted} = Tournaments.soft_delete_tournament(tournament)
      assert %DateTime{} = deleted.deleted_at

      refute Enum.any?(Tournaments.list_tournaments(owner), fn {t, _count, _owner?} ->
               t.id == tournament.id
             end)
    end

    test "a binned tournament is not viewable through the normal fetch paths, but shows up in list_deleted_tournaments/1" do
      owner = user_scope()

      {:ok, tournament} =
        Tournaments.create_tournament(owner, %{"name" => "T", "type" => "swiss"})

      {:ok, _} = Tournaments.soft_delete_tournament(tournament)

      assert_raise Ecto.NoResultsError, fn ->
        Tournaments.get_user_tournament!(owner, tournament.id)
      end

      assert Tournaments.get_user_tournament(owner, tournament.id) == nil

      assert_raise Ecto.NoResultsError, fn ->
        Tournaments.get_authorized_tournament!(owner, tournament.id)
      end

      assert Tournaments.get_authorized_tournament(owner, tournament.id) == nil
      assert_raise Ecto.NoResultsError, fn -> Tournaments.get_tournament!(tournament.id) end

      assert [binned] = Tournaments.list_deleted_tournaments(owner)
      assert binned.id == tournament.id
    end

    test "restore_tournament/1 clears deleted_at and brings it back into list_tournaments/1" do
      owner = user_scope()

      {:ok, tournament} =
        Tournaments.create_tournament(owner, %{"name" => "T", "type" => "swiss"})

      {:ok, binned} = Tournaments.soft_delete_tournament(tournament)

      assert {:ok, restored} = Tournaments.restore_tournament(binned)
      assert restored.deleted_at == nil

      assert Enum.any?(Tournaments.list_tournaments(owner), fn {t, _count, _owner?} ->
               t.id == tournament.id
             end)

      assert Tournaments.list_deleted_tournaments(owner) == []
    end

    test "purge_tournament/1 hard-deletes the row" do
      owner = user_scope()

      {:ok, tournament} =
        Tournaments.create_tournament(owner, %{"name" => "T", "type" => "swiss"})

      {:ok, binned} = Tournaments.soft_delete_tournament(tournament)

      assert {:ok, _} = Tournaments.purge_tournament(binned)
      refute Repo.get(Tournament, tournament.id)
    end

    test "purge_expired_tournaments/0 purges rows binned over 90 days ago but keeps recent ones" do
      owner = user_scope()
      {:ok, old} = Tournaments.create_tournament(owner, %{"name" => "Old", "type" => "swiss"})

      {:ok, recent} =
        Tournaments.create_tournament(owner, %{"name" => "Recent", "type" => "swiss"})

      old
      |> Ecto.Changeset.change(
        deleted_at: DateTime.utc_now() |> DateTime.add(-100, :day) |> DateTime.truncate(:second)
      )
      |> Repo.update!()

      recent
      |> Ecto.Changeset.change(
        deleted_at: DateTime.utc_now() |> DateTime.add(-10, :day) |> DateTime.truncate(:second)
      )
      |> Repo.update!()

      assert Tournaments.purge_expired_tournaments() == 1

      refute Repo.get(Tournament, old.id)
      assert Repo.get(Tournament, recent.id)
    end
  end

  describe "update_pairing_result/2" do
    setup do
      tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 1})
      white = Repo.insert!(%Player{tournament_id: tournament.id, name: "White"})
      black = Repo.insert!(%Player{tournament_id: tournament.id, name: "Black"})
      round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "playing"})

      pairing =
        Repo.insert!(%Pairing{
          round_id: round.id,
          board: 1,
          white_player_id: white.id,
          black_player_id: black.id,
          result: ""
        })

      %{pairing: pairing}
    end

    test "accepts every canonical result, including the explicit forfeit and played-0-0 codes",
         %{pairing: pairing} do
      for result <- [
            "1-0",
            "0-1",
            "1/2-1/2",
            "1/2-0",
            "0-1/2",
            "1-0FF",
            "0-1FF",
            "0-0FF",
            "0-0",
            "bye",
            ""
          ] do
        assert {:ok, updated} = Tournaments.update_pairing_result(pairing, result)
        assert updated.result == result
      end
    end

    test "rejects a result string that isn't in the recognized set", %{pairing: pairing} do
      assert {:error, changeset} = Tournaments.update_pairing_result(pairing, "3-0")
      assert %{result: ["is invalid"]} = errors_on(changeset)
    end

    test "1-0FF and 0-1FF are distinct from a double forfeit 0-0FF", %{pairing: pairing} do
      assert {:ok, white_forfeit_win} = Tournaments.update_pairing_result(pairing, "1-0FF")
      assert white_forfeit_win.result == "1-0FF"

      assert {:ok, double_forfeit} = Tournaments.update_pairing_result(pairing, "0-0FF")
      assert double_forfeit.result == "0-0FF"

      # A played 0-0 (both lose, game actually contested) is a different,
      # separately-valid result from the double forfeit above.
      assert {:ok, played_zero_zero} = Tournaments.update_pairing_result(pairing, "0-0")
      assert played_zero_zero.result == "0-0"
    end
  end

  describe "swap_players_in_round/3" do
    setup do
      tournament = Repo.insert!(%Tournament{name: "Swap T", type: "swiss", rounds_count: 3})
      a = Repo.insert!(%Player{tournament_id: tournament.id, name: "A"})
      b = Repo.insert!(%Player{tournament_id: tournament.id, name: "B"})
      c = Repo.insert!(%Player{tournament_id: tournament.id, name: "C"})
      d = Repo.insert!(%Player{tournament_id: tournament.id, name: "D"})
      round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "playing"})

      board1 =
        Repo.insert!(%Pairing{
          round_id: round.id,
          board: 1,
          white_player_id: a.id,
          black_player_id: b.id,
          result: ""
        })

      board2 =
        Repo.insert!(%Pairing{
          round_id: round.id,
          board: 2,
          white_player_id: c.id,
          black_player_id: d.id,
          result: ""
        })

      round = Tournaments.get_round(tournament.id, 1)
      %{round: round, a: a, b: b, c: c, d: d, board1: board1, board2: board2}
    end

    test "swapping two players from different boards trades their seats, not their opponents",
         %{round: round, a: a, b: b, c: c, d: d} do
      # 1. A-B, 2. C-D -> swap(A, D) -> 1. D-B, 2. C-A (verbatim example the
      # feature was speced against).
      assert {:ok, _} = Tournaments.swap_players_in_round(round, a.id, d.id)

      round = Tournaments.get_round(round.tournament_id, round.number)
      board1 = Enum.find(round.pairings, &(&1.board == 1))
      board2 = Enum.find(round.pairings, &(&1.board == 2))

      assert board1.white_player_id == d.id
      assert board1.black_player_id == b.id
      assert board2.white_player_id == c.id
      assert board2.black_player_id == a.id
    end

    test "swapping a player with their own opponent only flips that board's colours",
         %{round: round, a: a, b: b} do
      assert {:ok, _} = Tournaments.swap_players_in_round(round, a.id, b.id)

      round = Tournaments.get_round(round.tournament_id, round.number)
      board1 = Enum.find(round.pairings, &(&1.board == 1))

      assert board1.white_player_id == b.id
      assert board1.black_player_id == a.id
    end

    test "swapping into a bye reassigns the bye, and the swapped-out player keeps its result",
         %{round: round, a: a, b: b, board1: board1} do
      {:ok, _} = Tournaments.update_pairing_result(board1, "1-0")

      round2 =
        Repo.insert!(%Round{tournament_id: round.tournament_id, number: 2, status: "playing"})

      e = Repo.insert!(%Player{tournament_id: round.tournament_id, name: "E"})

      # A also has a normal board in round 2 (the round the swap actually
      # happens in) — swap works within one round's own pairings, so both
      # players being swapped have to be seated in THAT round.
      Repo.insert!(%Pairing{
        round_id: round2.id,
        board: 1,
        white_player_id: a.id,
        black_player_id: b.id,
        result: ""
      })

      Repo.insert!(%Pairing{
        round_id: round2.id,
        board: 2,
        white_player_id: e.id,
        black_player_id: nil,
        result: "bye"
      })

      round2 = Tournaments.get_round(round.tournament_id, 2)
      assert {:ok, _} = Tournaments.swap_players_in_round(round2, a.id, e.id)

      round2 = Tournaments.get_round(round.tournament_id, 2)
      board1_r2 = Enum.find(round2.pairings, &(&1.board == 1))
      bye_board = Enum.find(round2.pairings, &(&1.board == 2))

      # A now has the bye, and the bye marker itself is untouched — it's a
      # scoring rule for the empty seat, not a claim about who fills it.
      assert bye_board.white_player_id == a.id
      assert bye_board.black_player_id == nil
      assert bye_board.result == "bye"

      # E has taken over A's old seat in round 2's board 1.
      assert board1_r2.white_player_id == e.id
      assert board1_r2.black_player_id == b.id
      assert board1_r2.result == ""

      # Round 1's own board 1 (A vs B, "1-0") is a completely different
      # round and is untouched by any of this.
      board1_r1 =
        Enum.find(Tournaments.get_round(round.tournament_id, 1).pairings, &(&1.board == 1))

      assert board1_r1.white_player_id == a.id
      assert board1_r1.result == "1-0"
    end

    test "a stale non-bye result is cleared by a swap that touches its board",
         %{round: round, a: a, d: d, board1: board1} do
      {:ok, _} = Tournaments.update_pairing_result(board1, "1-0")
      round = Tournaments.get_round(round.tournament_id, round.number)

      assert {:ok, _} = Tournaments.swap_players_in_round(round, a.id, d.id)

      round = Tournaments.get_round(round.tournament_id, round.number)
      board1_after = Enum.find(round.pairings, &(&1.board == 1))
      assert board1_after.result == ""
    end

    test "rejects swapping a player with themselves", %{round: round, a: a} do
      assert {:error, :same_player} = Tournaments.swap_players_in_round(round, a.id, a.id)
    end

    test "rejects a player who isn't in this round", %{round: round, a: a} do
      assert {:error, :not_in_round} = Tournaments.swap_players_in_round(round, a.id, -1)
    end
  end

  describe "vacancies (mark absent on the board, refill from the pool)" do
    # A player who was never seated this round can't be `vacate_seat`ed
    # into the pool — they're already in it. This is how they get a
    # `"byes"` type without going through a seat.
    defp put_bye_row(tournament, player, type) do
      Repo.insert_all("byes", [
        %{tournament_id: tournament.id, player_id: player.id, round: 1, type: type}
      ])
    end

    setup do
      tournament = Repo.insert!(%Tournament{name: "Vac T", type: "swiss", rounds_count: 3})
      a = Repo.insert!(%Player{tournament_id: tournament.id, name: "A"})
      b = Repo.insert!(%Player{tournament_id: tournament.id, name: "B"})
      c = Repo.insert!(%Player{tournament_id: tournament.id, name: "C"})
      spare = Repo.insert!(%Player{tournament_id: tournament.id, name: "Spare"})
      round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "playing"})

      Repo.insert!(%Pairing{
        round_id: round.id,
        board: 1,
        white_player_id: a.id,
        black_player_id: b.id,
        result: "1-0"
      })

      %{
        tournament: tournament,
        round: Tournaments.get_round(tournament.id, 1),
        a: a,
        b: b,
        c: c,
        spare: spare
      }
    end

    test "list_round_pool returns everyone not seated, tagged with their bye type",
         %{tournament: t, c: c, spare: spare} do
      pool = Tournaments.list_round_pool(t.id, 1)
      assert Enum.map(pool, & &1.player.id) |> Enum.sort() == Enum.sort([c.id, spare.id])
      # Neither has a byes row yet, so neither carries a type.
      assert Enum.all?(pool, &(&1.type == nil))
    end

    test "an absent player IS offered as a swap candidate, and is flagged as such",
         %{tournament: t, c: c} do
      {:ok, _} = Tournaments.update_player(c, %{"absent" => "true"})

      pool = Tournaments.list_round_pool(t.id, 1)
      entry = Enum.find(pool, &(&1.player.id == c.id))

      # The pool exists so an absentee who turned up after all can be put
      # back in. Filtering them out (which the pairing engine's own
      # `active_players/1` does, and this function used to borrow) hid
      # exactly the players worth swapping with.
      assert entry, "an absent player must still be offered as a substitute"
      assert entry.absent?
    end

    test "a forfeited or non-active player is NOT offered as a swap candidate",
         %{tournament: t, spare: spare} do
      {:ok, _} = Tournaments.update_player(spare, %{"forfeit" => "true"})
      withdrawn = Repo.insert!(%Player{tournament_id: t.id, name: "Gone", status: "withdrawn"})

      pool = Tournaments.list_round_pool(t.id, 1)

      # These are withdrawals from the event, not "sitting this one out".
      # Reversing one is a deliberate edit on the Players page.
      refute Enum.any?(pool, &(&1.player.id in [spare.id, withdrawn.id]))
    end

    test "vacating a seat empties it, keeps the board and opponent, and clears the result",
         %{round: round, a: a, b: b} do
      assert {:ok, _} = Tournaments.vacate_seat(round, a.id)

      round = Tournaments.get_round(round.tournament_id, 1)
      board1 = hd(round.pairings)

      assert board1.board == 1
      assert board1.white_player_id == nil
      assert board1.black_player_id == b.id
      assert board1.result == ""
    end

    test "a vacated player joins the pool as absent and blocks the round from completing",
         %{tournament: t, round: round, a: a} do
      assert PairingsEngine.Pairing.round_complete?(t.id, 1) == true

      {:ok, _} = Tournaments.vacate_seat(round, a.id)

      pool = Tournaments.list_round_pool(t.id, 1)
      assert %{type: "absent"} = Enum.find(pool, &(&1.player.id == a.id))

      # The blank result on the vacant board is what stops the next round
      # being paired until the arbiter resolves the vacancy.
      refute PairingsEngine.Pairing.round_complete?(t.id, 1)
    end

    test "filling a vacant seat seats the replacement and drops their bye row",
         %{tournament: t, round: round, a: a, c: c} do
      {:ok, _} = Tournaments.vacate_seat(round, a.id)
      put_bye_row(t, c, "requested-half")

      round = Tournaments.get_round(t.id, 1)
      vacant = hd(round.pairings)

      assert {:ok, _} = Tournaments.fill_seat(round, vacant, c.id)

      round = Tournaments.get_round(t.id, 1)
      board1 = hd(round.pairings)
      assert board1.white_player_id == c.id

      pool_ids = Tournaments.list_round_pool(t.id, 1) |> Enum.map(& &1.player.id)
      refute c.id in pool_ids
      assert a.id in pool_ids
    end

    test "filling a board that has no vacant side is refused", %{round: round, c: c} do
      assert {:error, :seat_taken} = Tournaments.fill_seat(round, hd(round.pairings), c.id)
    end

    test "awarding a bye resolves the vacancy into the shape Standings already scores",
         %{tournament: t, round: round, a: a, b: b} do
      {:ok, _} = Tournaments.vacate_seat(round, a.id)
      round = Tournaments.get_round(t.id, 1)

      assert {:ok, _} = Tournaments.award_bye_for_vacancy(round, hd(round.pairings))

      round = Tournaments.get_round(t.id, 1)
      board1 = hd(round.pairings)
      # A bye is white-seat + nil black + "bye" — B moves across from black.
      assert board1.white_player_id == b.id
      assert board1.black_player_id == nil
      assert board1.result == "bye"
      assert PairingsEngine.Pairing.round_complete?(t.id, 1)
    end

    test "awarding a bye on a full board is refused", %{round: round} do
      assert {:error, :not_a_vacancy} =
               Tournaments.award_bye_for_vacancy(round, hd(round.pairings))
    end

    test "two pool players can be paired onto a new board with a chosen number",
         %{tournament: t, round: round, c: c, spare: spare} do
      assert Tournaments.next_free_board(round) == 2

      assert {:ok, _} = Tournaments.pair_from_pool(round, c.id, spare.id, 7)

      round = Tournaments.get_round(t.id, 1)
      new_board = Enum.find(round.pairings, &(&1.board == 7))
      assert new_board.white_player_id == c.id
      assert new_board.black_player_id == spare.id
      assert new_board.result == ""

      assert Tournaments.list_round_pool(t.id, 1) == []
    end

    test "swapping a seated player with a pool player hands over the seat and the absence",
         %{tournament: t, a: a, c: c} do
      put_bye_row(t, c, "requested-half")
      round = Tournaments.get_round(t.id, 1)

      assert {:ok, _} = Tournaments.swap_seated_with_pool_player(round, a.id, c.id)

      round = Tournaments.get_round(t.id, 1)
      board1 = hd(round.pairings)
      assert board1.white_player_id == c.id
      # A's "1-0" described a game A played; it no longer does.
      assert board1.result == ""

      pool = Tournaments.list_round_pool(t.id, 1)
      # A inherits the exact bye type C was carrying, so the round's
      # absentee accounting is unchanged by the substitution.
      assert %{type: "requested-half"} = Enum.find(pool, &(&1.player.id == a.id))
      refute Enum.any?(pool, &(&1.player.id == c.id))
    end
  end

  describe "refresh_status!/1" do
    test "a tournament with no paired rounds stays \"setup\"" do
      tournament =
        Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 2, status: "setup"})

      assert Tournaments.refresh_status!(tournament).status == "setup"
    end

    test "at least one paired round, not fully scored/paired -> \"running\"" do
      tournament =
        Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 2, status: "setup"})

      white = Repo.insert!(%Player{tournament_id: tournament.id, name: "White"})
      black = Repo.insert!(%Player{tournament_id: tournament.id, name: "Black"})
      round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "playing"})

      Repo.insert!(%Pairing{
        round_id: round.id,
        board: 1,
        white_player_id: white.id,
        black_player_id: black.id,
        result: ""
      })

      updated = Tournaments.refresh_status!(tournament)
      assert updated.status == "running"
    end

    test "rounds_count rounds paired and every pairing scored -> \"finished\"" do
      tournament =
        Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 1, status: "setup"})

      white = Repo.insert!(%Player{tournament_id: tournament.id, name: "White"})
      black = Repo.insert!(%Player{tournament_id: tournament.id, name: "Black"})
      round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "playing"})

      Repo.insert!(%Pairing{
        round_id: round.id,
        board: 1,
        white_player_id: white.id,
        black_player_id: black.id,
        result: "1-0"
      })

      updated = Tournaments.refresh_status!(tournament)
      assert updated.status == "finished"
    end

    # A "bye" pairing's result is the literal string "bye" — already
    # non-blank — so a round made up entirely of a pairing-allocated bye
    # still counts as fully scored.
    test "a pairing-allocated bye (result \"bye\") counts as scored, not missing" do
      tournament =
        Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 1, status: "setup"})

      white = Repo.insert!(%Player{tournament_id: tournament.id, name: "White"})
      round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "playing"})

      Repo.insert!(%Pairing{
        round_id: round.id,
        board: 1,
        white_player_id: white.id,
        black_player_id: nil,
        result: "bye"
      })

      updated = Tournaments.refresh_status!(tournament)
      assert updated.status == "finished"
    end

    test "accepts a tournament id as well as a struct, and is a no-op (no error) for a deleted id" do
      tournament =
        Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 2, status: "setup"})

      assert Tournaments.refresh_status!(tournament.id).status == "setup"
      assert Tournaments.refresh_status!(-1) == nil
    end

    test "only broadcasts :tournament when the status actually changes" do
      tournament =
        Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 2, status: "setup"})

      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))

      Tournaments.refresh_status!(tournament)
      tid = tournament.id
      refute_receive {:tournament_changed, ^tid, :tournament}

      white = Repo.insert!(%Player{tournament_id: tournament.id, name: "White"})
      black = Repo.insert!(%Player{tournament_id: tournament.id, name: "Black"})
      round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "playing"})

      Repo.insert!(%Pairing{
        round_id: round.id,
        board: 1,
        white_player_id: white.id,
        black_player_id: black.id,
        result: ""
      })

      Tournaments.refresh_status!(tournament)
      assert_receive {:tournament_changed, ^tid, :tournament}
    end
  end

  describe "PubSub broadcasts" do
    setup do
      %{scope: user_scope()}
    end

    test "create_tournament/2 broadcasts on the owning user's tournament-list topic", %{
      scope: scope
    } do
      Phoenix.PubSub.subscribe(
        PairingsEngine.PubSub,
        Tournaments.user_tournaments_topic(scope.user.id)
      )

      assert {:ok, _tournament} =
               Tournaments.create_tournament(scope, %{"name" => "T", "type" => "swiss"})

      user_id = scope.user.id
      assert_receive {:tournaments_changed, ^user_id}
    end

    test "update_tournament/2 broadcasts :settings on the tournament topic and on the user's list",
         %{
           scope: scope
         } do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{"name" => "T", "type" => "swiss"})

      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))

      Phoenix.PubSub.subscribe(
        PairingsEngine.PubSub,
        Tournaments.user_tournaments_topic(scope.user.id)
      )

      assert {:ok, _updated} = Tournaments.update_tournament(tournament, %{"name" => "T2"})

      tid = tournament.id
      user_id = scope.user.id
      assert_receive {:tournament_changed, ^tid, :settings}
      assert_receive {:tournaments_changed, ^user_id}
    end

    test "update_tournament/2 does not broadcast on an invalid changeset", %{scope: scope} do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{"name" => "T", "type" => "swiss"})

      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))

      assert {:error, _changeset} = Tournaments.update_tournament(tournament, %{"name" => ""})
      refute_receive {:tournament_changed, _, _}
    end

    test "delete_tournament/1 broadcasts on both the tournament topic and the user's list", %{
      scope: scope
    } do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{"name" => "T", "type" => "swiss"})

      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))

      Phoenix.PubSub.subscribe(
        PairingsEngine.PubSub,
        Tournaments.user_tournaments_topic(scope.user.id)
      )

      assert {:ok, _} = Tournaments.delete_tournament(tournament)

      tid = tournament.id
      user_id = scope.user.id
      assert_receive {:tournament_changed, ^tid, :tournament}
      assert_receive {:tournaments_changed, ^user_id}
    end

    test "create_player/2, update_player/2 and delete_player/1 each broadcast :players", %{
      scope: scope
    } do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{"name" => "T", "type" => "swiss"})

      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
      tid = tournament.id

      assert {:ok, player} = Tournaments.create_player(tournament.id, %{"name" => "Alice"})
      assert_receive {:tournament_changed, ^tid, :players}

      assert {:ok, player} = Tournaments.update_player(player, %{"name" => "Alice B"})
      assert_receive {:tournament_changed, ^tid, :players}

      assert {:ok, _} = Tournaments.delete_player(player)
      assert_receive {:tournament_changed, ^tid, :players}
    end

    test "create_player/2 does not broadcast on a duplicate FIDE id or an invalid changeset", %{
      scope: scope
    } do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{"name" => "T", "type" => "swiss"})

      {:ok, _} =
        Tournaments.create_player(tournament.id, %{"name" => "Alice", "fide_id" => "123"})

      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))

      assert {:error, :duplicate_fide_id} =
               Tournaments.create_player(tournament.id, %{"name" => "Bob", "fide_id" => "123"})

      assert {:error, _changeset} = Tournaments.create_player(tournament.id, %{"name" => ""})

      refute_receive {:tournament_changed, _, _}
    end

    test "update_pairing_result/2 broadcasts :results on the pairing's tournament topic", %{
      scope: scope
    } do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{"name" => "T", "type" => "swiss"})

      {:ok, white} = Tournaments.create_player(tournament.id, %{"name" => "White"})
      {:ok, black} = Tournaments.create_player(tournament.id, %{"name" => "Black"})

      round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "playing"})

      pairing =
        Repo.insert!(%Pairing{
          round_id: round.id,
          board: 1,
          white_player_id: white.id,
          black_player_id: black.id,
          result: ""
        })

      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))

      assert {:ok, _} = Tournaments.update_pairing_result(pairing, "1-0")

      tid = tournament.id
      assert_receive {:tournament_changed, ^tid, :results}
    end

    test "with_broadcast_suppressed/1 prevents nested writes from broadcasting", %{scope: scope} do
      {:ok, tournament} =
        Tournaments.create_tournament(scope, %{"name" => "T", "type" => "swiss"})

      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))

      Tournaments.with_broadcast_suppressed(fn ->
        Tournaments.create_player(tournament.id, %{"name" => "Alice"})
      end)

      refute_receive {:tournament_changed, _, _}

      # Suppression only applies inside the function — writes afterwards
      # broadcast normally again.
      assert {:ok, _} = Tournaments.create_player(tournament.id, %{"name" => "Bob"})
      tid = tournament.id
      assert_receive {:tournament_changed, ^tid, :players}
    end
  end

  describe "find_tournament_by_swar_guid/2" do
    test "finds a tournament with a matching swar_guid owned by scope's user" do
      scope = user_scope()

      tournament =
        Repo.insert!(%Tournament{
          name: "T",
          type: "swiss",
          rounds_count: 3,
          user_id: scope.user.id,
          swar_guid: "abc-123"
        })

      found = Tournaments.find_tournament_by_swar_guid(scope, "abc-123")
      assert found.id == tournament.id
    end

    test "never matches another user's tournament, even with the same guid" do
      owner_scope = user_scope()
      other_scope = user_scope()

      Repo.insert!(%Tournament{
        name: "T",
        type: "swiss",
        rounds_count: 3,
        user_id: owner_scope.user.id,
        swar_guid: "shared-guid"
      })

      assert Tournaments.find_tournament_by_swar_guid(other_scope, "shared-guid") == nil
    end

    test "ignores a soft-deleted tournament" do
      scope = user_scope()

      tournament =
        Repo.insert!(%Tournament{
          name: "T",
          type: "swiss",
          rounds_count: 3,
          user_id: scope.user.id,
          swar_guid: "deleted-guid"
        })

      {:ok, _} = Tournaments.soft_delete_tournament(tournament)

      assert Tournaments.find_tournament_by_swar_guid(scope, "deleted-guid") == nil
    end

    test "nil or blank guid never matches anything" do
      scope = user_scope()

      Repo.insert!(%Tournament{
        name: "T",
        type: "swiss",
        rounds_count: 3,
        user_id: scope.user.id,
        swar_guid: nil
      })

      assert Tournaments.find_tournament_by_swar_guid(scope, nil) == nil
      assert Tournaments.find_tournament_by_swar_guid(scope, "") == nil
    end
  end

  describe "fide_id uniqueness within a tournament (players_tournament_id_fide_id_index)" do
    test "update_player/2 rejects editing a player's fide_id to collide with another player in the same tournament" do
      tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 3})

      {:ok, _alice} =
        Tournaments.create_player(tournament.id, %{"name" => "Alice", "fide_id" => "111"})

      {:ok, bob} =
        Tournaments.create_player(tournament.id, %{"name" => "Bob", "fide_id" => "222"})

      assert {:error, changeset} = Tournaments.update_player(bob, %{"fide_id" => "111"})
      assert %{fide_id: [_msg]} = errors_on(changeset)
      assert Repo.reload!(bob).fide_id == 222
    end

    test "the same fide_id is allowed across different tournaments" do
      t1 = Repo.insert!(%Tournament{name: "T1", type: "swiss", rounds_count: 3})
      t2 = Repo.insert!(%Tournament{name: "T2", type: "swiss", rounds_count: 3})

      assert {:ok, _} = Tournaments.create_player(t1.id, %{"name" => "Alice", "fide_id" => "333"})

      assert {:ok, _} =
               Tournaments.create_player(t2.id, %{"name" => "Alice2", "fide_id" => "333"})
    end

    test "players with no fide_id are never constrained against each other (partial index)" do
      tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 3})

      assert {:ok, _} = Tournaments.create_player(tournament.id, %{"name" => "Alice"})
      assert {:ok, _} = Tournaments.create_player(tournament.id, %{"name" => "Bob"})
    end
  end

  describe "pairing_number freeze after round 4 (FIDE C.04.2.B.3)" do
    test "editing pairing_number is allowed before round 4 has been paired" do
      tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 3})
      {:ok, alice} = Tournaments.create_player(tournament.id, %{"name" => "Alice"})
      alice = %{alice | pairing_number: 5}

      assert {:ok, updated} = Tournaments.update_player(alice, %{"pairing_number" => "9"})
      assert updated.pairing_number == 9
    end

    test "assigning a first pairing_number to a player who never had one is always allowed" do
      tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 3})
      {:ok, alice} = Tournaments.create_player(tournament.id, %{"name" => "Alice"})
      assert alice.pairing_number == nil

      assert {:ok, updated} = Tournaments.update_player(alice, %{"pairing_number" => "1"})
      assert updated.pairing_number == 1
    end

    @tag :javafo
    test "editing an existing pairing_number is rejected once round 4 has been paired" do
      {:ok, tournament} =
        Tournaments.create_tournament(user_scope(), %{
          "name" => "Freeze Test",
          "type" => "swiss",
          "rounds_count" => "5"
        })

      for n <- 1..6 do
        {:ok, _} =
          Tournaments.create_player(tournament.id, %{
            "name" => "P#{n}",
            "fide_rating" => "#{1000 + n}"
          })
      end

      for _ <- 1..4 do
        assert {:ok, round} = PairingsEngine.Pairing.pair_next_round(tournament)
        round = Tournaments.get_round(tournament.id, round.number)

        for p <- round.pairings, p.result != "bye" do
          {:ok, _} = Tournaments.update_pairing_result(p, "1-0")
        end
      end

      alice = Enum.find(Tournaments.list_players(tournament.id), &(&1.name == "P1"))
      assert alice.pairing_number != nil

      assert {:error, changeset} =
               Tournaments.update_player(alice, %{"pairing_number" => "999"})

      assert %{pairing_number: [_msg]} = errors_on(changeset)
      assert Repo.reload!(alice).pairing_number == alice.pairing_number
    end

    @tag :javafo
    test "resubmitting the same pairing_number after round 4 is a no-op, not an error" do
      {:ok, tournament} =
        Tournaments.create_tournament(user_scope(), %{
          "name" => "Freeze Test 2",
          "type" => "swiss",
          "rounds_count" => "5"
        })

      for n <- 1..6 do
        {:ok, _} =
          Tournaments.create_player(tournament.id, %{
            "name" => "P#{n}",
            "fide_rating" => "#{1000 + n}"
          })
      end

      for _ <- 1..4 do
        assert {:ok, round} = PairingsEngine.Pairing.pair_next_round(tournament)
        round = Tournaments.get_round(tournament.id, round.number)

        for p <- round.pairings, p.result != "bye" do
          {:ok, _} = Tournaments.update_pairing_result(p, "1-0")
        end
      end

      alice = Enum.find(Tournaments.list_players(tournament.id), &(&1.name == "P1"))

      assert {:ok, updated} =
               Tournaments.update_player(alice, %{
                 "pairing_number" => Integer.to_string(alice.pairing_number),
                 "club" => "Some Club"
               })

      assert updated.pairing_number == alice.pairing_number
      assert updated.club == "Some Club"
    end
  end

  describe "collaborators (tournament sharing by email — invite, must be accepted)" do
    import Swoosh.TestAssertions

    test "add_collaborator/3 creates a pending invite, links user_id as a courtesy when the email belongs to an existing user, and emails an invitation" do
      owner = user_scope()
      collaborator_scope = user_scope()

      {:ok, tournament} =
        Tournaments.create_tournament(owner, %{"name" => "T", "type" => "swiss"})

      assert {:ok, collaborator} =
               Tournaments.add_collaborator(owner, tournament, collaborator_scope.user.email)

      assert collaborator.tournament_id == tournament.id
      assert collaborator.user_id == collaborator_scope.user.id
      assert collaborator.email == String.downcase(collaborator_scope.user.email)
      assert collaborator.status == "pending"
      assert is_binary(collaborator.invite_token)
      assert collaborator.mail_status == :sent

      assert_email_sent(fn email ->
        email.to == [{"", collaborator.email}] and email.text_body =~ collaborator.invite_token
      end)
    end

    test "add_collaborator/3 leaves user_id nil (pending) when no user has that email yet" do
      owner = user_scope()

      {:ok, tournament} =
        Tournaments.create_tournament(owner, %{"name" => "T", "type" => "swiss"})

      assert {:ok, collaborator} =
               Tournaments.add_collaborator(owner, tournament, "Not-Yet-Registered@Example.com")

      assert collaborator.user_id == nil
      assert collaborator.email == "not-yet-registered@example.com"
      assert collaborator.status == "pending"
    end

    test "add_collaborator/3 rejects the owner's own email" do
      owner = user_scope()

      {:ok, tournament} =
        Tournaments.create_tournament(owner, %{"name" => "T", "type" => "swiss"})

      assert {:error, :cannot_add_owner} =
               Tournaments.add_collaborator(owner, tournament, owner.user.email)
    end

    test "add_collaborator/3 rejects a blank email and a duplicate email gracefully" do
      owner = user_scope()

      {:ok, tournament} =
        Tournaments.create_tournament(owner, %{"name" => "T", "type" => "swiss"})

      assert {:error, :blank_email} = Tournaments.add_collaborator(owner, tournament, "  ")
      assert {:ok, _} = Tournaments.add_collaborator(owner, tournament, "friend@example.com")

      assert {:error, :already_added} =
               Tournaments.add_collaborator(owner, tournament, "Friend@Example.com")
    end

    test "add_collaborator/3 is owner-only" do
      owner = user_scope()
      not_owner = user_scope()

      {:ok, tournament} =
        Tournaments.create_tournament(owner, %{"name" => "T", "type" => "swiss"})

      assert {:error, :not_owner} =
               Tournaments.add_collaborator(not_owner, tournament, "someone@example.com")
    end

    test "remove_collaborator/3 removes a collaborator (pending or accepted) and is owner-only" do
      owner = user_scope()
      not_owner = user_scope()

      {:ok, tournament} =
        Tournaments.create_tournament(owner, %{"name" => "T", "type" => "swiss"})

      {:ok, collaborator} = Tournaments.add_collaborator(owner, tournament, "friend@example.com")

      assert {:error, :not_owner} =
               Tournaments.remove_collaborator(not_owner, tournament, collaborator.id)

      assert {:ok, _} = Tournaments.remove_collaborator(owner, tournament, collaborator.id)
      assert Tournaments.list_collaborators(tournament) == []
    end

    test "a pending invite grants no access — only the owner can reach the tournament until it's accepted" do
      owner = user_scope()
      invited = user_scope()
      pending_email = "pending-#{System.unique_integer([:positive])}@example.com"
      stranger = user_scope()

      {:ok, tournament} =
        Tournaments.create_tournament(owner, %{"name" => "T", "type" => "swiss"})

      {:ok, _} = Tournaments.add_collaborator(owner, tournament, invited.user.email)
      {:ok, _} = Tournaments.add_collaborator(owner, tournament, pending_email)

      assert %Tournament{} = Tournaments.get_authorized_tournament!(owner, tournament.id)

      # Neither the linked-but-pending invitee, nor the not-yet-registered
      # pending invite, nor a stranger have access yet.
      assert Tournaments.get_authorized_tournament(invited, tournament.id) == nil

      pending_scope = %Scope{user: %User{id: -1, email: pending_email}}
      assert Tournaments.get_authorized_tournament(pending_scope, tournament.id) == nil

      assert Tournaments.get_authorized_tournament(stranger, tournament.id) == nil

      assert_raise Ecto.NoResultsError, fn ->
        Tournaments.get_authorized_tournament!(invited, tournament.id)
      end
    end

    test "get_user_tournament!/2 stays owner-only — an (even accepted) collaborator does not satisfy it" do
      owner = user_scope()
      collaborator = user_scope()

      {:ok, tournament} =
        Tournaments.create_tournament(owner, %{"name" => "T", "type" => "swiss"})

      {:ok, invite} = Tournaments.add_collaborator(owner, tournament, collaborator.user.email)
      assert {:ok, _} = Tournaments.accept_invitation(collaborator, invite.invite_token)

      assert %Tournament{} = Tournaments.get_user_tournament!(owner, tournament.id)

      assert_raise Ecto.NoResultsError, fn ->
        Tournaments.get_user_tournament!(collaborator, tournament.id)
      end
    end

    test "list_tournaments/1 excludes a shared tournament until the invite is accepted, then includes it (owner? false)" do
      owner = user_scope()
      collaborator = user_scope()
      {:ok, owned} = Tournaments.create_tournament(owner, %{"name" => "Owned", "type" => "swiss"})

      {:ok, shared} =
        Tournaments.create_tournament(owner, %{"name" => "Shared", "type" => "swiss"})

      {:ok, invite} = Tournaments.add_collaborator(owner, shared, collaborator.user.email)

      refute Enum.any?(Tournaments.list_tournaments(collaborator), fn {t, _count, _owner?} ->
               t.id == shared.id
             end)

      assert {:ok, _} = Tournaments.accept_invitation(collaborator, invite.invite_token)

      results = Tournaments.list_tournaments(collaborator)
      ids_and_ownership = Enum.map(results, fn {t, _count, owner?} -> {t.id, owner?} end)

      assert {shared.id, false} in ids_and_ownership
      refute Enum.any?(ids_and_ownership, fn {id, _} -> id == owned.id end)

      owner_results = Tournaments.list_tournaments(owner)

      owner_ids_and_ownership =
        Enum.map(owner_results, fn {t, _count, owner?} -> {t.id, owner?} end)

      assert {owned.id, true} in owner_ids_and_ownership
      assert {shared.id, true} in owner_ids_and_ownership
    end

    test "link_pending_collaborators/1 links pending rows by email, idempotently, but still does not grant access on its own" do
      owner = user_scope()

      {:ok, tournament} =
        Tournaments.create_tournament(owner, %{"name" => "T", "type" => "swiss"})

      # Add the collaborator by email *before* any account with that email
      # exists — this is the "pending invite" case add_collaborator/3 itself
      # covers. link_pending_collaborators/1 is the separate, login-time step
      # that backfills user_id once such an account shows up.
      pending_email = "brand-new-#{System.unique_integer([:positive])}@example.com"
      {:ok, _} = Tournaments.add_collaborator(owner, tournament, pending_email)

      [pending] = Tournaments.list_collaborators(tournament)
      assert pending.user_id == nil

      new_user =
        Repo.insert!(%User{
          email: pending_email,
          confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
        })

      new_scope = Scope.for_user(new_user)

      assert :ok = Tournaments.link_pending_collaborators(new_user)

      [linked] = Tournaments.list_collaborators(tournament)
      assert linked.user_id == new_user.id
      assert linked.status == "pending"

      # Linking backfills user_id for tidiness/lookup purposes only — it does
      # NOT grant access. The invite is still pending.
      refute Enum.any?(Tournaments.list_tournaments(new_scope), fn {t, _count, _owner?} ->
               t.id == tournament.id
             end)

      # Idempotent — calling again does nothing further.
      assert :ok = Tournaments.link_pending_collaborators(new_user)
      [still_linked] = Tournaments.list_collaborators(tournament)
      assert still_linked.user_id == new_user.id
    end

    test "accept_invitation/2 grants access, links user_id, clears the token, and requires a matching email" do
      owner = user_scope()
      invitee = user_scope()
      stranger = user_scope()

      {:ok, tournament} =
        Tournaments.create_tournament(owner, %{"name" => "T", "type" => "swiss"})

      {:ok, invite} = Tournaments.add_collaborator(owner, tournament, invitee.user.email)

      assert {:error, :email_mismatch} =
               Tournaments.accept_invitation(stranger, invite.invite_token)

      assert Tournaments.get_authorized_tournament(stranger, tournament.id) == nil

      assert {:ok, accepted} = Tournaments.accept_invitation(invitee, invite.invite_token)
      assert accepted.status == "accepted"
      assert accepted.user_id == invitee.user.id
      assert accepted.invite_token == nil

      assert %Tournament{} = Tournaments.get_authorized_tournament!(invitee, tournament.id)

      # A bad/already-used token is not found.
      assert {:error, :not_found} = Tournaments.accept_invitation(invitee, invite.invite_token)
      assert {:error, :not_found} = Tournaments.accept_invitation(invitee, "not-a-real-token")
    end

    test "accept_invitation/2 also works by collaborator id" do
      owner = user_scope()
      invitee = user_scope()

      {:ok, tournament} =
        Tournaments.create_tournament(owner, %{"name" => "T", "type" => "swiss"})

      {:ok, invite} = Tournaments.add_collaborator(owner, tournament, invitee.user.email)

      assert {:ok, accepted} = Tournaments.accept_invitation(invitee, invite.id)
      assert accepted.status == "accepted"
    end

    test "decline_invitation/2 deletes the row and requires a matching email" do
      owner = user_scope()
      invitee = user_scope()
      stranger = user_scope()

      {:ok, tournament} =
        Tournaments.create_tournament(owner, %{"name" => "T", "type" => "swiss"})

      {:ok, invite} = Tournaments.add_collaborator(owner, tournament, invitee.user.email)

      assert {:error, :email_mismatch} =
               Tournaments.decline_invitation(stranger, invite.invite_token)

      assert Tournaments.list_collaborators(tournament) != []

      assert {:ok, _} = Tournaments.decline_invitation(invitee, invite.invite_token)
      assert Tournaments.list_collaborators(tournament) == []

      assert {:error, :not_found} = Tournaments.decline_invitation(invitee, invite.invite_token)
    end

    test "list_pending_invitations/1 returns invites matched by user_id or by email, not accepted ones" do
      owner = user_scope()
      invitee = user_scope()

      {:ok, tournament} =
        Tournaments.create_tournament(owner, %{"name" => "T", "type" => "swiss"})

      {:ok, other_tournament} =
        Tournaments.create_tournament(owner, %{"name" => "T2", "type" => "swiss"})

      {:ok, _} = Tournaments.add_collaborator(owner, tournament, invitee.user.email)

      {:ok, other_invite} =
        Tournaments.add_collaborator(owner, other_tournament, invitee.user.email)

      assert [_, _] = Tournaments.list_pending_invitations(invitee)

      assert {:ok, _} = Tournaments.accept_invitation(invitee, other_invite.invite_token)

      [remaining] = Tournaments.list_pending_invitations(invitee)
      assert remaining.tournament.id == tournament.id
      assert remaining.owner_email == owner.user.email
    end

    test "the owner can revoke a still-pending invite" do
      owner = user_scope()
      invitee = user_scope()

      {:ok, tournament} =
        Tournaments.create_tournament(owner, %{"name" => "T", "type" => "swiss"})

      {:ok, invite} = Tournaments.add_collaborator(owner, tournament, invitee.user.email)

      assert {:ok, _} = Tournaments.remove_collaborator(owner, tournament, invite.id)
      assert Tournaments.list_collaborators(tournament) == []

      # Now even the correct person can't accept a revoked invite.
      assert {:error, :not_found} = Tournaments.accept_invitation(invitee, invite.invite_token)
    end
  end

  describe "forbidden pairings (arbiter-configured 'never pair these two')" do
    setup do
      tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 3})
      a = Repo.insert!(%Player{tournament_id: tournament.id, name: "Alice"})
      b = Repo.insert!(%Player{tournament_id: tournament.id, name: "Bob"})
      %{tournament: tournament, a: a, b: b}
    end

    test "add_forbidden_pairing/3 creates a row, and list_forbidden_pairings/1 preloads both players",
         %{tournament: t, a: a, b: b} do
      assert {:ok, fp} = Tournaments.add_forbidden_pairing(t, a.id, b.id)
      assert fp.tournament_id == t.id
      assert fp.player_a_id == a.id
      assert fp.player_b_id == b.id

      assert [listed] = Tournaments.list_forbidden_pairings(t.id)
      assert listed.id == fp.id
      assert listed.player_a.name == "Alice"
      assert listed.player_b.name == "Bob"
    end

    test "add_forbidden_pairing/3 rejects the same player twice", %{tournament: t, a: a} do
      assert {:error, :same_player} = Tournaments.add_forbidden_pairing(t, a.id, a.id)
      assert Tournaments.list_forbidden_pairings(t.id) == []
    end

    test "add_forbidden_pairing/3 rejects a player who doesn't belong to this tournament", %{
      tournament: t,
      a: a
    } do
      other = Repo.insert!(%Tournament{name: "Other", type: "swiss", rounds_count: 3})
      stranger = Repo.insert!(%Player{tournament_id: other.id, name: "Stranger"})

      assert {:error, :invalid_player} = Tournaments.add_forbidden_pairing(t, a.id, stranger.id)
      assert {:error, :invalid_player} = Tournaments.add_forbidden_pairing(t, stranger.id, a.id)
      assert Tournaments.list_forbidden_pairings(t.id) == []
    end

    test "add_forbidden_pairing/3 rejects a duplicate pair regardless of order", %{
      tournament: t,
      a: a,
      b: b
    } do
      assert {:ok, _} = Tournaments.add_forbidden_pairing(t, a.id, b.id)
      assert {:error, :already_forbidden} = Tournaments.add_forbidden_pairing(t, a.id, b.id)
      assert {:error, :already_forbidden} = Tournaments.add_forbidden_pairing(t, b.id, a.id)
      assert length(Tournaments.list_forbidden_pairings(t.id)) == 1
    end

    test "storage is normalized so player_a_id is always the smaller id, regardless of call order",
         %{tournament: t, a: a, b: b} do
      # Force b to have the larger id by inserting a fresh pair, since fixture
      # insertion order already makes a.id < b.id — assert that up front so
      # this test actually exercises the swap either way it's called.
      assert a.id < b.id

      assert {:ok, fp} = Tournaments.add_forbidden_pairing(t, b.id, a.id)
      assert fp.player_a_id == a.id
      assert fp.player_b_id == b.id

      stored =
        Repo.get_by(ForbiddenPairing, tournament_id: t.id, player_a_id: a.id, player_b_id: b.id)

      assert stored
      assert stored.player_a_id < stored.player_b_id
    end

    test "remove_forbidden_pairing/2 removes the row, and 404s (not_found) for another tournament's id",
         %{tournament: t, a: a, b: b} do
      {:ok, fp} = Tournaments.add_forbidden_pairing(t, a.id, b.id)
      other = Repo.insert!(%Tournament{name: "Other", type: "swiss", rounds_count: 3})

      assert {:error, :not_found} = Tournaments.remove_forbidden_pairing(other, fp.id)
      assert Tournaments.list_forbidden_pairings(t.id) != []

      assert {:ok, removed} = Tournaments.remove_forbidden_pairing(t, fp.id)
      assert removed.id == fp.id
      assert Tournaments.list_forbidden_pairings(t.id) == []
    end

    test "add_forbidden_pairing/3 and remove_forbidden_pairing/2 broadcast :settings on the tournament topic",
         %{tournament: t, a: a, b: b} do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(t.id))
      tid = t.id

      assert {:ok, fp} = Tournaments.add_forbidden_pairing(t, a.id, b.id)
      assert_receive {:tournament_changed, ^tid, :settings}

      assert {:ok, _} = Tournaments.remove_forbidden_pairing(t, fp.id)
      assert_receive {:tournament_changed, ^tid, :settings}
    end
  end

  describe "extra points (SWAR parity #12 XtPts) — Tournament.changeset/2 normalization" do
    test "count_extra_points defaults false and extra_points_bands defaults blank" do
      tournament = Repo.insert!(%Tournament{name: "Defaults", type: "swiss", rounds_count: 3})
      assert tournament.count_extra_points == false
      assert tournament.extra_points_bands == ""
    end

    test "extra_points_bands is normalized: trimmed, sorted ascending, integer bonuses without a decimal" do
      tournament = Repo.insert!(%Tournament{name: "Norm", type: "swiss", rounds_count: 3})

      {:ok, updated} =
        Tournaments.update_tournament(tournament, %{"extra_points_bands" => " 1600:0.5 , 1400:1 "})

      assert updated.extra_points_bands == "1400:1, 1600:0.5"
    end

    test "rejects a malformed extra_points_bands string with a changeset error" do
      tournament = Repo.insert!(%Tournament{name: "Bad", type: "swiss", rounds_count: 3})

      assert {:error, changeset} =
               Tournaments.update_tournament(tournament, %{"extra_points_bands" => "not-a-band"})

      assert %{extra_points_bands: [_msg]} = errors_on(changeset)
    end

    test "rejects a negative threshold or negative bonus" do
      tournament = Repo.insert!(%Tournament{name: "Negative", type: "swiss", rounds_count: 3})

      assert {:error, _} =
               Tournaments.update_tournament(tournament, %{"extra_points_bands" => "-100:1"})

      assert {:error, _} =
               Tournaments.update_tournament(tournament, %{"extra_points_bands" => "1400:-1"})
    end

    test "blank extra_points_bands is valid" do
      tournament = Repo.insert!(%Tournament{name: "Blank", type: "swiss", rounds_count: 3})

      assert {:ok, updated} =
               Tournaments.update_tournament(tournament, %{"extra_points_bands" => "  "})

      assert updated.extra_points_bands == ""
    end

    test "count_extra_points can be toggled on" do
      tournament = Repo.insert!(%Tournament{name: "Toggle", type: "swiss", rounds_count: 3})

      assert {:ok, updated} =
               Tournaments.update_tournament(tournament, %{"count_extra_points" => true})

      assert updated.count_extra_points == true
    end
  end

  describe "fide_id_ranges / fide_homologated — Tournament.changeset/2 normalization" do
    test "fide_homologated defaults false and fide_id_ranges defaults empty" do
      tournament =
        Repo.insert!(%Tournament{name: "FIDE Defaults", type: "swiss", rounds_count: 3})

      assert tournament.fide_homologated == false
      assert tournament.fide_id_ranges == []
    end

    test "accepts a well-formed range and canonicalizes round numbers to integers, sorted by from_round" do
      tournament = Repo.insert!(%Tournament{name: "FIDE Ranges", type: "swiss", rounds_count: 9})

      assert {:ok, updated} =
               Tournaments.update_tournament(tournament, %{
                 "fide_id_ranges" => [
                   %{"fide_tournament_id" => "222", "from_round" => "4", "to_round" => "9"},
                   %{"fide_tournament_id" => "111", "from_round" => "1", "to_round" => "3"}
                 ]
               })

      assert updated.fide_id_ranges == [
               %{"fide_tournament_id" => "111", "from_round" => 1, "to_round" => 3},
               %{"fide_tournament_id" => "222", "from_round" => 4, "to_round" => 9}
             ]
    end

    test "rejects overlapping ranges" do
      tournament = Repo.insert!(%Tournament{name: "FIDE Overlap", type: "swiss", rounds_count: 9})

      assert {:error, changeset} =
               Tournaments.update_tournament(tournament, %{
                 "fide_id_ranges" => [
                   %{"fide_tournament_id" => "111", "from_round" => "1", "to_round" => "5"},
                   %{"fide_tournament_id" => "222", "from_round" => "4", "to_round" => "9"}
                 ]
               })

      assert %{fide_id_ranges: [msg]} = errors_on(changeset)
      assert msg =~ "overlap"
    end

    test "rejects a range where from_round > to_round" do
      tournament =
        Repo.insert!(%Tournament{name: "FIDE Backwards", type: "swiss", rounds_count: 9})

      assert {:error, changeset} =
               Tournaments.update_tournament(tournament, %{
                 "fide_id_ranges" => [
                   %{"fide_tournament_id" => "111", "from_round" => "5", "to_round" => "1"}
                 ]
               })

      assert %{fide_id_ranges: [_msg]} = errors_on(changeset)
    end

    test "rejects a range missing a FIDE tournament ID" do
      tournament =
        Repo.insert!(%Tournament{name: "FIDE Blank Id", type: "swiss", rounds_count: 9})

      assert {:error, changeset} =
               Tournaments.update_tournament(tournament, %{
                 "fide_id_ranges" => [
                   %{"fide_tournament_id" => "", "from_round" => "1", "to_round" => "3"}
                 ]
               })

      assert %{fide_id_ranges: [_msg]} = errors_on(changeset)
    end

    test "an empty list clears any previously configured ranges" do
      tournament = Repo.insert!(%Tournament{name: "FIDE Clear", type: "swiss", rounds_count: 9})

      {:ok, tournament} =
        Tournaments.update_tournament(tournament, %{
          "fide_id_ranges" => [
            %{"fide_tournament_id" => "111", "from_round" => "1", "to_round" => "3"}
          ]
        })

      assert {:ok, cleared} = Tournaments.update_tournament(tournament, %{"fide_id_ranges" => []})
      assert cleared.fide_id_ranges == []
    end

    test "fide_homologated can be toggled on" do
      tournament = Repo.insert!(%Tournament{name: "FIDE Toggle", type: "swiss", rounds_count: 3})

      assert {:ok, updated} =
               Tournaments.update_tournament(tournament, %{"fide_homologated" => true})

      assert updated.fide_homologated == true
    end
  end

  describe "Tournament.parse_extra_points_bands/1 and band_extra_points/2" do
    test "parses a well-formed bands string into sorted-by-input {threshold, bonus} pairs" do
      assert {:ok, [{1600, 0.5}, {1400, 1.0}]} =
               Tournament.parse_extra_points_bands("1600:0.5, 1400:1")
    end

    test "blank/nil input parses to an empty list" do
      assert {:ok, []} = Tournament.parse_extra_points_bands("")
      assert {:ok, []} = Tournament.parse_extra_points_bands("   ")
      assert {:ok, []} = Tournament.parse_extra_points_bands(nil)
    end

    test "rejects malformed tokens" do
      assert :error = Tournament.parse_extra_points_bands("1400")
      assert :error = Tournament.parse_extra_points_bands("abc:1")
      assert :error = Tournament.parse_extra_points_bands("1400:abc")
      assert :error = Tournament.parse_extra_points_bands("1400:1:2")
    end

    test "a rated player matches the lowest band whose threshold they're below" do
      bands = [{1400, 1.0}, {1600, 0.5}]

      # Below both thresholds -> lowest band wins (bigger bonus).
      assert Tournament.band_extra_points(bands, 1300) == 1.0
      # At the boundary: rating == threshold does NOT count as "below" it.
      assert Tournament.band_extra_points(bands, 1400) == 0.5
      # Below only the higher threshold.
      assert Tournament.band_extra_points(bands, 1550) == 0.5
      # At/above every threshold -> no match.
      assert Tournament.band_extra_points(bands, 1600) == 0.0
      assert Tournament.band_extra_points(bands, 2000) == 0.0
    end

    test "an unrated player (rating 0) only matches an explicit 0:bonus band" do
      assert Tournament.band_extra_points([{1400, 1.0}], 0) == 0.0
      assert Tournament.band_extra_points([{0, 0.75}, {1400, 1.0}], 0) == 0.75
    end

    test "no bands configured -> everyone gets 0.0" do
      assert Tournament.band_extra_points([], 1200) == 0.0
      assert Tournament.band_extra_points([], 0) == 0.0
    end
  end

  describe "apply_extra_points_bands/1" do
    setup do
      tournament =
        Repo.insert!(%Tournament{
          name: "Bands Apply",
          type: "swiss",
          rounds_count: 3,
          extra_points_bands: "1400:1, 1600:0.5"
        })

      low = Repo.insert!(%Player{tournament_id: tournament.id, name: "Low", fide_rating: 1300})
      mid = Repo.insert!(%Player{tournament_id: tournament.id, name: "Mid", fide_rating: 1550})

      high =
        Repo.insert!(%Player{
          tournament_id: tournament.id,
          name: "High",
          fide_rating: 2000,
          extra_points: 2.0
        })

      unrated = Repo.insert!(%Player{tournament_id: tournament.id, name: "Unrated"})

      %{tournament: tournament, low: low, mid: mid, high: high, unrated: unrated}
    end

    test "sets each player's extra_points from the bands, overwriting existing values, matched counts only bonus > 0",
         %{tournament: tournament, low: low, mid: mid, high: high, unrated: unrated} do
      assert {:ok, %{matched: 2, total: 4}} = Tournaments.apply_extra_points_bands(tournament)

      assert Repo.reload!(low).extra_points == 1.0
      assert Repo.reload!(mid).extra_points == 0.5
      # High was previously 2.0 but matches no band -> overwritten to 0.0, not left alone.
      assert Repo.reload!(high).extra_points == 0.0
      # Unrated matches nothing since no "0:bonus" band is configured.
      assert Repo.reload!(unrated).extra_points == 0.0
    end

    test "fires exactly one tournament_changed broadcast", %{tournament: tournament} do
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))
      tid = tournament.id

      assert {:ok, _} = Tournaments.apply_extra_points_bands(tournament)
      assert_receive {:tournament_changed, ^tid, :players}
      refute_receive {:tournament_changed, ^tid, :players}
    end

    test "with no bands configured, applying sets everyone to 0.0" do
      tournament = Repo.insert!(%Tournament{name: "No Bands", type: "swiss", rounds_count: 3})

      p =
        Repo.insert!(%Player{
          tournament_id: tournament.id,
          name: "P",
          fide_rating: 1000,
          extra_points: 3.0
        })

      assert {:ok, %{matched: 0, total: 1}} = Tournaments.apply_extra_points_bands(tournament)
      assert Repo.reload!(p).extra_points == 0.0
    end
  end

  ## ---------- Manual standings override (SWAR parity #23) ----------

  describe "enable_manual_ranking/1" do
    # Full round robin over 3 rounds so every player ends on a distinct
    # score, and the computed order is unambiguously A(3) > B(2) > C(1) > D(0):
    #   R1: A beats D, B beats C
    #   R2: A beats C, B beats D
    #   R3: A beats B, C beats D
    defp manual_ranking_fixture do
      tournament =
        Repo.insert!(%Tournament{name: "Manual Ranking Test", type: "swiss", rounds_count: 3})

      [a, b, c, d] =
        for {name, rating} <- [{"A", 2000}, {"B", 1800}, {"C", 1700}, {"D", 1600}] do
          Repo.insert!(%Player{tournament_id: tournament.id, name: name, fide_rating: rating})
        end

      r1 = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "finished"})
      r2 = Repo.insert!(%Round{tournament_id: tournament.id, number: 2, status: "finished"})
      r3 = Repo.insert!(%Round{tournament_id: tournament.id, number: 3, status: "finished"})

      pairing1 =
        Repo.insert!(%Pairing{
          round_id: r1.id,
          board: 1,
          white_player_id: a.id,
          black_player_id: d.id,
          result: "1-0"
        })

      Repo.insert!(%Pairing{
        round_id: r1.id,
        board: 2,
        white_player_id: b.id,
        black_player_id: c.id,
        result: "1-0"
      })

      Repo.insert!(%Pairing{
        round_id: r2.id,
        board: 1,
        white_player_id: a.id,
        black_player_id: c.id,
        result: "1-0"
      })

      Repo.insert!(%Pairing{
        round_id: r2.id,
        board: 2,
        white_player_id: b.id,
        black_player_id: d.id,
        result: "1-0"
      })

      Repo.insert!(%Pairing{
        round_id: r3.id,
        board: 1,
        white_player_id: a.id,
        black_player_id: b.id,
        result: "1-0"
      })

      Repo.insert!(%Pairing{
        round_id: r3.id,
        board: 2,
        white_player_id: c.id,
        black_player_id: d.id,
        result: "1-0"
      })

      %{tournament: tournament, a: a, b: b, c: c, d: d, pairing1: pairing1}
    end

    test "sets the flag and seeds every player's manual_rank from the computed standings order" do
      %{tournament: tournament, a: a, b: b} = manual_ranking_fixture()

      assert {:ok, updated} = Tournaments.enable_manual_ranking(tournament)
      assert updated.manual_ranking

      assert Repo.reload!(a).manual_rank == 1
      assert Repo.reload!(b).manual_rank == 2
      # C and D are tied on points; both still get a distinct, positive seed.
      ranks = for p <- [a, b], do: Repo.reload!(p).manual_rank
      assert Enum.all?(ranks, &(&1 > 0))
    end

    test "is idempotent — calling it again re-seeds fresh from the current order" do
      %{tournament: tournament, a: a} = manual_ranking_fixture()

      {:ok, tournament} = Tournaments.enable_manual_ranking(tournament)
      Tournaments.move_manual_rank(tournament, Repo.reload!(a), :down)
      refute Repo.reload!(a).manual_rank == 1

      {:ok, _} = Tournaments.enable_manual_ranking(tournament)
      assert Repo.reload!(a).manual_rank == 1
    end
  end

  describe "disable_manual_ranking/1" do
    test "clears the flag but leaves manual_rank values in place" do
      %{tournament: tournament, a: a} = manual_ranking_fixture()
      {:ok, tournament} = Tournaments.enable_manual_ranking(tournament)

      assert {:ok, updated} = Tournaments.disable_manual_ranking(tournament)
      refute updated.manual_ranking
      assert Repo.reload!(a).manual_rank == 1
    end
  end

  describe "reseed_manual_ranking/1" do
    test "re-seeds fresh (positive) values from the current computed order, clearing staleness" do
      %{tournament: tournament, pairing1: pairing1, a: a} = manual_ranking_fixture()
      {:ok, tournament} = Tournaments.enable_manual_ranking(tournament)

      # A result changes -> stale.
      Tournaments.update_pairing_result(pairing1, "0-1")
      assert Repo.reload!(tournament).manual_ranking_stale

      assert {:ok, reseeded} = Tournaments.reseed_manual_ranking(tournament)
      refute reseeded.manual_ranking_stale
      refute Repo.reload!(tournament).manual_ranking_stale
      assert Repo.reload!(a).manual_rank > 0
    end
  end

  describe "move_manual_rank/3" do
    test "swaps a player with its neighbour and renumbers the whole list 1..N" do
      %{tournament: tournament, a: a, b: b} = manual_ranking_fixture()
      {:ok, tournament} = Tournaments.enable_manual_ranking(tournament)

      assert Repo.reload!(a).manual_rank == 1
      assert Repo.reload!(b).manual_rank == 2

      assert {:ok, _} = Tournaments.move_manual_rank(tournament, Repo.reload!(b), :up)

      assert Repo.reload!(a).manual_rank == 2
      assert Repo.reload!(b).manual_rank == 1
    end

    test "moving confirms freshness — clears staleness for the whole tournament, not just the two rows touched" do
      %{tournament: tournament, pairing1: pairing1, a: a, b: b, c: c, d: d} =
        manual_ranking_fixture()

      {:ok, tournament} = Tournaments.enable_manual_ranking(tournament)

      Tournaments.update_pairing_result(pairing1, "0-1")
      assert Repo.reload!(tournament).manual_ranking_stale

      assert {:ok, _} = Tournaments.move_manual_rank(tournament, Repo.reload!(b), :up)

      refute Repo.reload!(tournament).manual_ranking_stale
      for p <- [a, b, c, d], do: assert(Repo.reload!(p).manual_rank > 0)
    end

    test "returns {:error, :edge} at the top of the list moving up, and the bottom moving down" do
      %{tournament: tournament, a: a, d: d} = manual_ranking_fixture()
      {:ok, tournament} = Tournaments.enable_manual_ranking(tournament)

      assert {:error, :edge} = Tournaments.move_manual_rank(tournament, Repo.reload!(a), :up)
      assert {:error, :edge} = Tournaments.move_manual_rank(tournament, Repo.reload!(d), :down)
    end
  end

  describe "invalidate_manual_ranking (via update_pairing_result/2)" do
    test "a result change marks the tournament's manual order stale, leaving manual_rank values untouched" do
      %{tournament: tournament, pairing1: pairing1, a: a, b: b} = manual_ranking_fixture()
      {:ok, tournament} = Tournaments.enable_manual_ranking(tournament)
      refute tournament.manual_ranking_stale

      before_a = Repo.reload!(a).manual_rank
      before_b = Repo.reload!(b).manual_rank

      assert {:ok, _} = Tournaments.update_pairing_result(pairing1, "0-1")

      assert Repo.reload!(tournament).manual_ranking_stale
      assert Repo.reload!(a).manual_rank == before_a
      assert Repo.reload!(b).manual_rank == before_b
    end

    test "a second result change while already stale is a no-op (stays stale, one row either way)" do
      %{tournament: tournament, pairing1: pairing1} = manual_ranking_fixture()
      {:ok, tournament} = Tournaments.enable_manual_ranking(tournament)

      Tournaments.update_pairing_result(pairing1, "0-1")
      assert Repo.reload!(tournament).manual_ranking_stale

      Tournaments.update_pairing_result(pairing1, "1/2-1/2")
      assert Repo.reload!(tournament).manual_ranking_stale
    end

    test "does nothing when manual_ranking is off" do
      %{tournament: tournament, pairing1: pairing1, a: a} = manual_ranking_fixture()
      {:ok, tournament} = Tournaments.enable_manual_ranking(tournament)
      {:ok, tournament} = Tournaments.disable_manual_ranking(tournament)
      refute tournament.manual_ranking
      rank_before = Repo.reload!(a).manual_rank

      Tournaments.update_pairing_result(pairing1, "0-1")

      refute Repo.reload!(tournament).manual_ranking_stale
      assert Repo.reload!(a).manual_rank == rank_before
    end

    test "invalidation commits before the :results broadcast — a subscriber's immediate reload already sees the stale flag" do
      %{tournament: tournament, pairing1: pairing1} = manual_ranking_fixture()
      {:ok, tournament} = Tournaments.enable_manual_ranking(tournament)

      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))

      assert {:ok, _} = Tournaments.update_pairing_result(pairing1, "0-1")

      tid = tournament.id
      assert_receive {:tournament_changed, ^tid, :results}
      # By the time the broadcast is observable, the write has already
      # committed — no separate confirmation step needed after the message.
      assert Repo.reload!(tournament).manual_ranking_stale
    end
  end

  ## ---------- Logo (SWAR parity #14-16) ----------

  describe "set_logo/2, clear_logo/1 and detect_image_type/1" do
    # 1x1 transparent PNG — real signature bytes, not a fake/truncated stub.
    @tiny_png Base.decode64!(
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
              )
    # Minimal valid JPEG (SOI + EOI markers, nothing between).
    @tiny_jpeg <<0xFF, 0xD8, 0xFF, 0xD9>>
    # Minimal valid GIF89a header.
    @tiny_gif "GIF89a" <> <<0, 0, 0, 0, 0, 0>>
    # Minimal RIFF/WEBP container shape (fourcc + WEBP, no real payload —
    # only the signature bytes matter for detect_image_type/1).
    @tiny_webp "RIFF" <> <<0, 0, 0, 0>> <> "WEBP"
    # A well-formed SVG — deliberately never accepted, even though it's a
    # perfectly valid image format elsewhere: it's an XML document that can
    # carry a <script>, and this blob is rendered straight back into pages
    # the app serves. No signature match should ever let this through.
    @tiny_svg "<svg xmlns=\"http://www.w3.org/2000/svg\"><script>alert(1)</script></svg>"

    defp logo_tournament do
      Repo.insert!(%Tournament{name: "Logo Test", type: "swiss", rounds_count: 3})
    end

    test "accepts a valid PNG and stores the verified content-type" do
      tournament = logo_tournament()

      assert {:ok, updated} = Tournaments.set_logo(tournament, @tiny_png)
      assert updated.logo_data == @tiny_png
      assert updated.logo_content_type == "image/png"
      assert Repo.reload!(tournament).logo_content_type == "image/png"
    end

    test "accepts a valid JPEG, GIF and WebP" do
      tournament = logo_tournament()

      assert {:ok, updated} = Tournaments.set_logo(tournament, @tiny_jpeg)
      assert updated.logo_content_type == "image/jpeg"

      assert {:ok, updated} = Tournaments.set_logo(tournament, @tiny_gif)
      assert updated.logo_content_type == "image/gif"

      assert {:ok, updated} = Tournaments.set_logo(tournament, @tiny_webp)
      assert updated.logo_content_type == "image/webp"
    end

    test "rejects an SVG outright, no matter how it's labelled" do
      tournament = logo_tournament()

      assert Tournaments.set_logo(tournament, @tiny_svg) == {:error, :invalid_image}
      # Never stored — the row is untouched.
      refute Repo.reload!(tournament).logo_data
      refute Repo.reload!(tournament).logo_content_type
    end

    test "rejects a file whose bytes don't match any accepted image signature" do
      tournament = logo_tournament()

      # A renamed-but-not-actually-an-image file — plain text, no magic
      # bytes at all. Validation checks the real content, not a claimed
      # filename/extension/content-type, so this is rejected exactly like
      # the SVG case, not accepted because someone might call it "logo.png".
      assert Tournaments.set_logo(tournament, "just some text, not an image") ==
               {:error, :invalid_image}

      refute Repo.reload!(tournament).logo_data
    end

    test "rejects a file over the size cap even with a valid PNG signature" do
      tournament = logo_tournament()
      oversized = <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>> <> :binary.copy(<<0>>, 2_000_001)

      assert Tournaments.set_logo(tournament, oversized) == {:error, :invalid_image}
    end

    test "clear_logo/1 removes a previously set logo" do
      tournament = logo_tournament()
      {:ok, tournament} = Tournaments.set_logo(tournament, @tiny_png)
      assert tournament.logo_data

      assert {:ok, cleared} = Tournaments.clear_logo(tournament)
      refute cleared.logo_data
      refute cleared.logo_content_type
      refute Repo.reload!(tournament).logo_data
    end

    test "set_logo/2 broadcasts :settings, same as any other tournament write" do
      tournament = logo_tournament()
      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))

      assert {:ok, _} = Tournaments.set_logo(tournament, @tiny_png)

      tid = tournament.id
      assert_receive {:tournament_changed, ^tid, :settings}
    end

    test "logo_data_uri/1 builds a base64 data: URI, or nil with no logo set" do
      tournament = logo_tournament()
      refute Tournaments.logo_data_uri(tournament)

      {:ok, tournament} = Tournaments.set_logo(tournament, @tiny_png)
      uri = Tournaments.logo_data_uri(tournament)
      assert uri == "data:image/png;base64,#{Base.encode64(@tiny_png)}"
    end

    test "ordinary update_tournament/2 never touches the logo fields" do
      tournament = logo_tournament()
      {:ok, tournament} = Tournaments.set_logo(tournament, @tiny_png)

      assert {:ok, updated} = Tournaments.update_tournament(tournament, %{"name" => "Renamed"})
      assert updated.name == "Renamed"
      assert updated.logo_data == @tiny_png
      assert updated.logo_content_type == "image/png"
    end
  end

  describe "publish_mode / publish_delay_minutes — Tournament.changeset/2 validation" do
    test "defaults to immediate mode with a zero delay" do
      tournament = Repo.insert!(%Tournament{name: "Defaults", type: "swiss", rounds_count: 3})
      assert tournament.publish_mode == "immediate"
      assert tournament.publish_delay_minutes == 0
    end

    test "accepts every documented publish_mode value" do
      tournament = Repo.insert!(%Tournament{name: "Modes", type: "swiss", rounds_count: 3})

      for mode <- Tournament.publish_modes() do
        assert {:ok, updated} =
                 Tournaments.update_tournament(tournament, %{"publish_mode" => mode})

        assert updated.publish_mode == mode
      end
    end

    test "rejects an unrecognized publish_mode" do
      tournament = Repo.insert!(%Tournament{name: "Bad mode", type: "swiss", rounds_count: 3})

      assert {:error, changeset} =
               Tournaments.update_tournament(tournament, %{"publish_mode" => "whenever"})

      assert %{publish_mode: [_msg]} = errors_on(changeset)
    end

    test "rejects a negative publish_delay_minutes" do
      tournament =
        Repo.insert!(%Tournament{name: "Negative delay", type: "swiss", rounds_count: 3})

      assert {:error, changeset} =
               Tournaments.update_tournament(tournament, %{"publish_delay_minutes" => -5})

      assert %{publish_delay_minutes: [_msg]} = errors_on(changeset)
    end

    test "accepts a zero or positive publish_delay_minutes" do
      tournament = Repo.insert!(%Tournament{name: "Zero delay", type: "swiss", rounds_count: 3})

      assert {:ok, updated} =
               Tournaments.update_tournament(tournament, %{"publish_delay_minutes" => 30})

      assert updated.publish_delay_minutes == 30
    end
  end

  describe "compute_published_at/2" do
    test "immediate mode returns roughly now" do
      tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 3})

      at = Tournaments.compute_published_at(tournament, 1)

      assert DateTime.diff(DateTime.utc_now(), at, :second) in -2..2
    end

    test "manual mode returns nil — the round starts out hidden" do
      tournament =
        Repo.insert!(%Tournament{
          name: "T",
          type: "swiss",
          rounds_count: 3,
          publish_mode: "manual"
        })

      assert Tournaments.compute_published_at(tournament, 1) == nil
    end

    test "timed mode returns now plus the configured delay" do
      tournament =
        Repo.insert!(%Tournament{
          name: "T",
          type: "swiss",
          rounds_count: 3,
          publish_mode: "timed",
          publish_delay_minutes: 15
        })

      at = Tournaments.compute_published_at(tournament, 1)
      expected = DateTime.add(DateTime.utc_now(), 15 * 60, :second)

      assert DateTime.diff(expected, at, :second) in -2..2
    end

    test "scheduled mode returns midnight UTC of that round's own round_dates entry" do
      tournament =
        Repo.insert!(%Tournament{
          name: "T",
          type: "swiss",
          rounds_count: 3,
          publish_mode: "scheduled",
          round_dates: ["2026-09-01", "2026-09-08", "2026-09-15"]
        })

      assert Tournaments.compute_published_at(tournament, 2) ==
               DateTime.new!(~D[2026-09-08], ~T[00:00:00], "Etc/UTC")
    end

    test "scheduled mode falls back to now when that round's date is missing or unparseable" do
      tournament =
        Repo.insert!(%Tournament{
          name: "T",
          type: "swiss",
          rounds_count: 3,
          publish_mode: "scheduled",
          round_dates: ["2026-09-01", "", "not-a-date"]
        })

      # Round 2's entry is blank, round 3's is garbage — neither should ever
      # produce a round that can never be published.
      at2 = Tournaments.compute_published_at(tournament, 2)
      at3 = Tournaments.compute_published_at(tournament, 3)

      assert DateTime.diff(DateTime.utc_now(), at2, :second) in -2..2
      assert DateTime.diff(DateTime.utc_now(), at3, :second) in -2..2
    end

    test "scheduled mode falls back to now when round_dates doesn't cover that round at all" do
      tournament =
        Repo.insert!(%Tournament{
          name: "T",
          type: "swiss",
          rounds_count: 3,
          publish_mode: "scheduled",
          round_dates: ["2026-09-01"]
        })

      at = Tournaments.compute_published_at(tournament, 3)

      assert DateTime.diff(DateTime.utc_now(), at, :second) in -2..2
    end
  end

  describe "round_published?/2" do
    test "immediate mode is always public, regardless of published_at — including nil" do
      tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 3})
      round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, published_at: nil})

      assert Tournaments.round_published?(tournament, round)
    end

    test "non-immediate mode with published_at nil is not public" do
      tournament =
        Repo.insert!(%Tournament{
          name: "T",
          type: "swiss",
          rounds_count: 3,
          publish_mode: "manual"
        })

      round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, published_at: nil})

      refute Tournaments.round_published?(tournament, round)
    end

    test "non-immediate mode with a past published_at is public" do
      tournament =
        Repo.insert!(%Tournament{
          name: "T",
          type: "swiss",
          rounds_count: 3,
          publish_mode: "timed"
        })

      past = DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.truncate(:second)
      round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, published_at: past})

      assert Tournaments.round_published?(tournament, round)
    end

    test "non-immediate mode with a future published_at is not public yet" do
      tournament =
        Repo.insert!(%Tournament{
          name: "T",
          type: "swiss",
          rounds_count: 3,
          publish_mode: "scheduled"
        })

      future = DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second)
      round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, published_at: future})

      refute Tournaments.round_published?(tournament, round)
    end
  end

  describe "publish_round_now/1 and unpublish_round/1" do
    test "publish_round_now/1 sets published_at to now and broadcasts :settings" do
      tournament =
        Repo.insert!(%Tournament{
          name: "T",
          type: "swiss",
          rounds_count: 3,
          publish_mode: "manual"
        })

      round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, published_at: nil})

      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))

      assert {:ok, updated} = Tournaments.publish_round_now(round)
      assert updated.published_at
      assert DateTime.diff(DateTime.utc_now(), updated.published_at, :second) in -2..2

      tid = tournament.id
      assert_receive {:tournament_changed, ^tid, :settings}
    end

    test "unpublish_round/1 clears published_at back to nil and broadcasts :settings" do
      tournament =
        Repo.insert!(%Tournament{
          name: "T",
          type: "swiss",
          rounds_count: 3,
          publish_mode: "manual"
        })

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, published_at: now})

      Phoenix.PubSub.subscribe(PairingsEngine.PubSub, Tournaments.tournament_topic(tournament.id))

      assert {:ok, updated} = Tournaments.unpublish_round(round)
      assert updated.published_at == nil

      tid = tournament.id
      assert_receive {:tournament_changed, ^tid, :settings}
    end
  end

  describe "latest_published_round_number/1" do
    test "immediate mode delegates straight to the paired-rounds count" do
      tournament = Repo.insert!(%Tournament{name: "T", type: "swiss", rounds_count: 3})
      Repo.insert!(%Round{tournament_id: tournament.id, number: 1, published_at: nil})
      Repo.insert!(%Round{tournament_id: tournament.id, number: 2, published_at: nil})

      assert Tournaments.latest_published_round_number(tournament) == 2
    end

    test "non-immediate mode counts only rounds with a published_at that has passed" do
      tournament =
        Repo.insert!(%Tournament{
          name: "T",
          type: "swiss",
          rounds_count: 3,
          publish_mode: "manual"
        })

      past = DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.truncate(:second)
      future = DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second)

      Repo.insert!(%Round{tournament_id: tournament.id, number: 1, published_at: past})
      Repo.insert!(%Round{tournament_id: tournament.id, number: 2, published_at: nil})
      Repo.insert!(%Round{tournament_id: tournament.id, number: 3, published_at: future})

      assert Tournaments.latest_published_round_number(tournament) == 1
    end

    test "non-immediate mode with nothing published returns 0" do
      tournament =
        Repo.insert!(%Tournament{
          name: "T",
          type: "swiss",
          rounds_count: 3,
          publish_mode: "manual"
        })

      Repo.insert!(%Round{tournament_id: tournament.id, number: 1, published_at: nil})

      assert Tournaments.latest_published_round_number(tournament) == 0
    end

    test "non-immediate mode can report a later round published out of order" do
      tournament =
        Repo.insert!(%Tournament{
          name: "T",
          type: "swiss",
          rounds_count: 3,
          publish_mode: "manual"
        })

      past = DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.truncate(:second)

      Repo.insert!(%Round{tournament_id: tournament.id, number: 1, published_at: nil})
      Repo.insert!(%Round{tournament_id: tournament.id, number: 2, published_at: past})

      # Round 1 was skipped but round 2 was explicitly published — the
      # "latest" number just tracks the highest published round, callers
      # that need per-round truth still go through round_published?/2.
      assert Tournaments.latest_published_round_number(tournament) == 2
    end
  end
end
