defmodule PairingsEngine.BoardLinkTest do
  @moduledoc """
  The board link's own rules: who may make a code and what it reaches, what
  a report may and may not do, what the box is told, and what travels in an
  export. The HTTP side is `BoardLinkControllerTest`.
  """
  use PairingsEngine.DataCase, async: false

  import PairingsEngine.AccountsFixtures
  import PairingsEngine.BoardLinkFixtures

  alias PairingsEngine.{
    BoardLink,
    PgnExport,
    Repo,
    TournamentExport,
    TournamentGroups,
    TournamentImport,
    Tournaments
  }

  alias PairingsEngine.BoardLink.{Document, Game, Link, TimeControl}
  alias PairingsEngine.Tournaments.Pairing

  setup do
    scope = user_scope_fixture()
    Map.put(paired_tournament(scope), :scope, scope)
  end

  describe "codes" do
    test "a code is random, shown once and kept as a hash", %{scope: scope, tournament: t} do
      assert {:ok, %Link{} = link, "oplt_" <> _ = secret} = BoardLink.create_link(scope, t)
      assert byte_size(secret) > 40
      assert link.secret_hint == String.slice(secret, -4, 4)

      # Nothing in the row can be turned back into the secret.
      row = Repo.get!(Link, link.id)
      refute row.secret_hash == secret
      refute Enum.any?(Map.values(Map.from_struct(row)), &(&1 == secret))

      assert {:ok, %Link{id: id}} = BoardLink.authenticate(secret)
      assert id == link.id
      assert :error = BoardLink.authenticate(secret <> "x")
      assert :error = BoardLink.authenticate(nil)
    end

    test "withdrawing a code ends it", %{scope: scope, tournament: t} do
      {:ok, link, secret} = BoardLink.create_link(scope, t)
      assert {:ok, _link} = BoardLink.revoke_link(scope, t, link.id)
      assert :error = BoardLink.authenticate(secret)
      assert %{tournament: [], group: []} = BoardLink.list_links(t)
    end

    test "only somebody who may edit the tournament makes or withdraws a code", %{
      scope: scope,
      tournament: t
    } do
      stranger = user_scope_fixture()
      assert {:error, :not_found} = BoardLink.create_link(stranger, t)

      {:ok, link, _secret} = BoardLink.create_link(scope, t)
      assert {:error, :not_found} = BoardLink.revoke_link(stranger, t, link.id)
      assert {:error, :not_found} = BoardLink.set_relay_key(stranger, t, "orrk_0123456789abcdef")
    end

    test "an archived tournament gets no code", %{scope: scope, tournament: t} do
      {:ok, archived} = Tournaments.archive_tournament(t)
      assert {:error, :archived} = BoardLink.create_link(scope, archived)
    end

    test "a code of another tournament cannot be withdrawn from this one", %{
      scope: scope,
      tournament: t
    } do
      other = paired_tournament(scope, %{name: "Another"}).tournament
      {:ok, link, _secret} = BoardLink.create_link(scope, other)
      assert {:error, :not_found} = BoardLink.revoke_link(scope, t, link.id)
    end

    test "there is a ceiling on codes", %{scope: scope, tournament: t} do
      for _ <- 1..BoardLink.max_links(), do: {:ok, _, _} = BoardLink.create_link(scope, t)
      assert {:error, :too_many_codes} = BoardLink.create_link(scope, t)
    end

    test "every act is in the audit trail", %{scope: scope, tournament: t} do
      {:ok, link, _secret} = BoardLink.create_link(scope, t)
      {:ok, _t} = BoardLink.set_relay_key(scope, t, "orrk_0123456789abcdef")
      {:ok, _link} = BoardLink.revoke_link(scope, t, link.id)

      actions = t.id |> PairingsEngine.Audit.list_for_tournament() |> Enum.map(& &1.action)

      for action <- ~w(boards.code_created boards.relay_key_saved boards.code_revoked) do
        assert action in actions
      end
    end
  end

  describe "what a code reaches" do
    test "a tournament code reaches its tournament and no other", %{scope: scope, tournament: t} do
      other = paired_tournament(scope, %{name: "Another"}).tournament
      {:ok, link, _secret} = BoardLink.create_link(scope, t)

      assert [%{tournament: %{id: id}}] = BoardLink.covered(link)
      assert id == t.id
      assert {:ok, _} = BoardLink.fetch_covered(link, t.id)
      assert :error = BoardLink.fetch_covered(link, other.id)
    end

    test "a group code reaches the group, and a tournament added later", %{
      scope: scope,
      tournament: t
    } do
      {:ok, group} = TournamentGroups.create_group(scope, t, "The Event")
      {:ok, link, "oplg_" <> _} = BoardLink.create_group_link(scope, t)

      assert [t.id] == Enum.map(BoardLink.covered(link), & &1.tournament.id)

      later = paired_tournament(scope, %{name: "Added Later"}).tournament
      {:ok, _group} = TournamentGroups.join_group(scope, later, group.id)

      assert [t.id, later.id] == Enum.map(BoardLink.covered(link), & &1.tournament.id)
      assert %{"kind" => "group", "group" => %{"name" => "The Event"}} = BoardLink.listing(link)
    end

    test "a group code does not reach a member its maker may not open", %{
      scope: scope,
      tournament: t
    } do
      {:ok, group} = TournamentGroups.create_group(scope, t, "The Event")
      {:ok, link, _secret} = BoardLink.create_group_link(scope, t)

      # Somebody else's tournament, put in the same group behind the maker's
      # back: the row is there, the code's maker has no access to it.
      theirs = paired_tournament(user_scope_fixture(), %{name: "Not Mine"}).tournament

      Repo.insert!(%TournamentGroups.Member{
        group_id: group.id,
        tournament_id: theirs.id,
        position: 9
      })

      assert [t.id] == Enum.map(BoardLink.covered(link), & &1.tournament.id)
      assert :error = BoardLink.fetch_covered(link, theirs.id)
    end

    test "a tournament in no group has no group code", %{scope: scope, tournament: t} do
      assert {:error, :not_grouped} = BoardLink.create_group_link(scope, t)
    end

    test "an archived tournament is no longer reached", %{scope: scope, tournament: t} do
      {:ok, link, _secret} = BoardLink.create_link(scope, t)
      {:ok, _archived} = Tournaments.archive_tournament(t)
      assert [] == BoardLink.covered(link)
    end
  end

  describe "reports" do
    setup %{scope: scope, tournament: t} do
      {:ok, link, _secret} = BoardLink.create_link(scope, t)
      %{link: link}
    end

    test "a report is stored, and the tournament's result is not touched", %{
      link: link,
      tournament: t,
      boards: [board1 | _]
    } do
      report =
        report_for(board1, %{
          "status" => "finished",
          "result" => "1-0",
          "white_ms" => 5_000,
          "black_ms" => 61_000,
          "move_clocks" => [5_400_000, nil, 5_390_000],
          "reconstructed" => 2,
          "guessed" => 1,
          "rewritten" => 1,
          # A field this version has never heard of: ignored, not refused.
          "mood" => "tense",
          "pgn" => "1. e4 e5 2. Nf3 1-0"
        })

      assert {:ok, %{applied: true, seq: 1, reason: nil}} = BoardLink.report(link, t, report)

      game = BoardLink.get_game(t.id, board1.game_uid)
      assert game.moves == ["e4", "e5", "Nf3"]
      assert game.move_clocks == [5_400_000, nil, 5_390_000]
      assert game.result == "1-0"
      assert game.status == "finished"
      assert game.reconstructed == 2 and game.guessed == 1 and game.rewritten == 1
      assert %{rewritten: 1} = BoardLink.summaries(t.id)[board1.game_uid]
      assert game.finished_at

      # A box that does not know the count sends none, and none is zero.
      assert {:ok, %{applied: true}} =
               BoardLink.report(link, t, report |> Map.delete("rewritten") |> Map.put("seq", 2))

      assert BoardLink.get_game(t.id, board1.game_uid).rewritten == 0

      assert {:error, :invalid_request, "rewritten" <> _} =
               BoardLink.report(link, t, report |> Map.put("rewritten", -1) |> Map.put("seq", 3))

      # The one rule: a board never enters a result.
      assert Repo.get!(Pairing, board1.id).result == ""
    end

    test "a late duplicate does not overwrite a newer state", %{
      link: link,
      tournament: t,
      boards: [board1 | _]
    } do
      newer = report_for(board1, %{"seq" => 7, "moves" => ~w(e4 e5 Nf3 Nc6)})
      assert {:ok, %{applied: true}} = BoardLink.report(link, t, newer)

      assert {:ok, %{applied: false, reason: :duplicate, seq: 7}} =
               BoardLink.report(link, t, newer)

      older = report_for(board1, %{"seq" => 3, "moves" => ~w(e4)})
      assert {:ok, %{applied: false, reason: :stale, seq: 7}} = BoardLink.report(link, t, older)
      assert BoardLink.get_game(t.id, board1.game_uid).moves == ~w(e4 e5 Nf3 Nc6)

      # Unless the box says it means it.
      assert {:ok, %{applied: true, seq: 3}} =
               BoardLink.report(link, t, Map.put(older, "replace", true))

      assert BoardLink.get_game(t.id, board1.game_uid).moves == ~w(e4)
    end

    test "a report for a game that is gone is refused by name", %{link: link, tournament: t} do
      ghost = %{"game" => "no-such-game", "white" => 1, "black" => 2, "seq" => 1}
      assert {:error, :pairing_gone, _detail} = BoardLink.report(link, t, ghost)
      assert Repo.aggregate(Game, :count, :id) == 0
    end

    test "a report for a board whose players changed is refused, not filed under the new ones",
         %{link: link, tournament: t, round: round, boards: [board1, board2]} do
      stale = report_for(board1)

      {:ok, _} =
        Tournaments.swap_players_in_round(
          Tournaments.get_round(t.id, round.number),
          board1.white_player_id,
          board2.white_player_id
        )

      assert {:error, :pairing_changed, _detail} = BoardLink.report(link, t, stale)
      assert Repo.aggregate(Game, :count, :id) == 0

      # With the players the board has now, it is this game again.
      fresh = Repo.get!(Pairing, board1.id)
      assert {:ok, %{applied: true}} = BoardLink.report(link, t, report_for(fresh))
    end

    test "a bye is not a game", %{link: link, tournament: t, round: round, players: [a | _]} do
      bye =
        Repo.insert!(%Pairing{round_id: round.id, board: 3, white_player_id: a.id, result: "bye"})

      uid = Repo.get!(Pairing, bye.id).game_uid

      assert {:error, :not_a_game, _detail} =
               BoardLink.report(link, t, %{
                 "game" => uid,
                 "white" => a.id,
                 "black" => a.id,
                 "seq" => 1
               })
    end

    test "a move is shaped like a move or the report is refused", %{
      link: link,
      tournament: t,
      boards: [board1 | _]
    } do
      for bad <- [~s(e4 {"x"}), "e4 e5", "[Event", "", String.duplicate("a", 11)] do
        assert {:error, :invalid_request, detail} =
                 BoardLink.report(link, t, report_for(board1, %{"moves" => ["e4", bad]}))

        assert detail =~ "ply 2"
      end

      assert {:error, :invalid_request, _} =
               BoardLink.report(link, t, report_for(board1, %{"result" => "2-0"}))

      assert {:error, :invalid_request, _} =
               BoardLink.report(link, t, report_for(board1, %{"move_clocks" => [1]}))

      assert {:error, :invalid_request, _} =
               BoardLink.report(link, t, Map.delete(report_for(board1), "seq"))

      assert {:error, :invalid_request, _} =
               BoardLink.report(
                 link,
                 t,
                 report_for(board1, %{"moves" => List.duplicate("e4", 1001)})
               )

      assert Repo.aggregate(Game, :count, :id) == 0
    end
  end

  describe "the board's result beside the arbiter's" do
    test "compare/2" do
      seen = fn result -> %{result: result, status: "finished", plies: 40} end

      assert :none == BoardLink.compare("1-0", nil)
      assert :none == BoardLink.compare("", %{result: nil, status: "waiting", plies: 0})
      assert :live == BoardLink.compare("", %{result: nil, status: "live", plies: 12})
      assert :pending == BoardLink.compare("", seen.("1-0"))
      assert :pending == BoardLink.compare("*", seen.("1-0"))
      assert :match == BoardLink.compare("1-0", seen.("1-0"))
      assert :match == BoardLink.compare("1/2-1/2U", seen.("1/2-1/2"))
      assert :match == BoardLink.compare("0-1FF", seen.("0-1"))
      assert :mismatch == BoardLink.compare("0-1", seen.("1-0"))
      assert :mismatch == BoardLink.compare("1/2-1/2", seen.("1-0"))
      assert :mismatch == BoardLink.compare("0-0", seen.("1/2-1/2"))
    end
  end

  describe "the round that is on" do
    # A paired round `number` with one game, and that game's result.
    defp round_with(t, number, result, [white, black]) do
      round =
        Repo.insert!(%PairingsEngine.Tournaments.Round{
          tournament_id: t.id,
          number: number,
          status: "playing"
        })

      Repo.insert!(%Pairing{
        round_id: round.id,
        board: 1,
        white_player_id: white.id,
        black_player_id: black.id,
        result: result
      })
    end

    defp current(t), do: Document.document(Repo.reload!(t))["current_round"]

    defp results(boards, result),
      do:
        for(
          b <- boards,
          do:
            Pairing |> Repo.get!(b.id) |> Ecto.Changeset.change(result: result) |> Repo.update!()
        )

    test "a Swiss: the round paired last, whatever is still open before it", %{
      tournament: t,
      boards: [board1 | _] = boards,
      players: [a, b | _]
    } do
      assert current(t) == 1

      # Round 2 is paired while a game of round 1 has no result at all.
      results(tl(boards), "1-0")
      round_with(t, 2, "", [b, a])
      assert current(t) == 2
      doc = Document.document(Repo.reload!(t))
      assert ["finished", "current"] == Enum.map(doc["rounds"], & &1["state"])

      # A result of round 1 entered, then cleared to be corrected: round 2 stays on.
      results([board1], "0-1")
      assert current(t) == 2
      results([board1], "")
      assert current(t) == 2

      # Everything complete: still the last round, until another is paired.
      results(boards, "1/2-1/2")
      Repo.update_all(Pairing, set: [result: "1-0"])
      assert current(t) == 2
      round_with(t, 3, "", [a, b])
      assert current(t) == 3
    end

    test "a round robin, every round paired at once: the first round with a game still open", %{
      tournament: t,
      boards: boards,
      players: [a, b | _]
    } do
      t = t |> Ecto.Changeset.change(pairing_system: "round_robin") |> Repo.update!()
      round_with(t, 2, "", [b, a])
      round_with(t, 3, "", [a, b])
      assert current(t) == 1

      results(boards, "1-0")
      assert current(t) == 2

      # A postponed game is a result: it does not hold the schedule up.
      results(boards, "*")
      assert current(t) == 2

      # A result cleared in round 1 brings a round robin back to round 1:
      # nothing has said round 2 was begun.
      results(tl(boards), "")
      assert current(t) == 1
    end

    test "a Swiss of two-leg matches: the first open leg of the pair that was paired last", %{
      tournament: t,
      boards: boards,
      players: [a, b | _]
    } do
      t = t |> Ecto.Changeset.change(swiss_match_format: true) |> Repo.update!()
      round_with(t, 2, "", [b, a])
      assert current(t) == 1

      results(boards, "1-0")
      assert current(t) == 2

      # The next match: legs 3 and 4, paired together. Leg 2 unfinished changes nothing.
      round_with(t, 3, "", [a, b])
      round_with(t, 4, "", [b, a])
      assert current(t) == 3
    end
  end

  describe "what the box is told" do
    test "the boards, the players, the rate of play - and nothing private", %{
      tournament: t,
      boards: [board1, board2],
      players: [a, b | _]
    } do
      doc = Document.document(t)

      assert doc["current_round"] == 1
      assert doc["tournament"]["name"] == "Board Link Open"
      assert doc["tournament"]["time_control"]["pgn"] == "40/5400+30:1800+30"
      assert doc["openresults"] == nil

      assert [%{"number" => 1, "state" => "current", "boards" => [first, second]}] = doc["rounds"]

      assert first == %{
               "game" => board1.game_uid,
               "board" => 1,
               "label" => "1",
               "kind" => "game",
               "white" => a.id,
               "black" => b.id,
               "result" => nil
             }

      assert second["game"] == board2.game_uid

      assert %{"name" => "Player 1", "rating" => 1990, "federation" => "BEL", "no" => 1} =
               Enum.find(doc["players"], &(&1["id"] == a.id))

      json = Jason.encode!(doc)
      refute json =~ "Secret Club"
      refute json =~ "birth"
      refute json =~ "1971"
      refute json =~ "email"
    end

    test "the version moves with a result and with a re-pairing, and not otherwise", %{
      tournament: t,
      round: round,
      boards: [board1, board2]
    } do
      v0 = Document.version(t)
      assert v0 == Document.version(Tournaments.get_tournament!(t.id))
      assert v0 == Document.document(t)["version"]

      {:ok, _} = Tournaments.update_pairing_result(board1, "1-0")
      v1 = Document.version(t)
      refute v1 == v0

      {:ok, _} =
        Tournaments.swap_players_in_round(
          Tournaments.get_round(t.id, round.number),
          board1.white_player_id,
          board2.white_player_id
        )

      refute Document.version(t) == v1
    end

    test "a team event: every board says its match and its place in it", %{scope: scope} do
      teams = for i <- 1..4, do: {"Team #{i}", [2100 - i * 10, 2000 - i * 10]}

      {t, _teams} =
        PairingsEngine.TeamFixtures.team_round_robin(teams, boards: 2, user_id: scope.user.id)

      t = PairingsEngine.TeamFixtures.pair_all!(t)
      doc = Document.document(t)

      assert doc["tournament"]["team_event"] == true
      assert doc["tournament"]["boards_per_match"] == 2
      # A round robin pairs every round at once: the first is the one on.
      assert doc["current_round"] == 1
      assert ["current", "upcoming", "upcoming"] == Enum.map(doc["rounds"], & &1["state"])

      [round1 | _] = doc["rounds"]
      assert length(round1["boards"]) == 4

      # Round-wide board numbers, and beside each its match and its board
      # within the match.
      assert [{1, 1, 1}, {2, 1, 2}, {3, 2, 1}, {4, 2, 2}] ==
               Enum.map(
                 round1["boards"],
                 &{&1["board"], &1["match"]["number"], &1["match"]["board"]}
               )

      first = hd(round1["boards"])
      assert is_binary(first["match"]["team_a"]) and is_binary(first["match"]["team_b"])

      white = Enum.find(doc["players"], &(&1["id"] == first["white"]))
      assert white["team"] in [first["match"]["team_a"], first["match"]["team_b"]]
    end

    test "the relay key travels only while the tournament is on a results site", %{
      scope: scope,
      tournament: t
    } do
      {:ok, t} = BoardLink.set_relay_key(scope, t, "orrk_0123456789abcdef")
      assert BoardLink.openresults_target(t) == nil
      assert Document.document(t)["openresults"] == nil

      assert {:error, :relay_key_shape} = BoardLink.set_relay_key(scope, t, "has a space in it !")

      {:ok, t} = BoardLink.set_relay_key(scope, t, "")
      assert t.openresults_relay_key == nil
    end
  end

  describe "the rate of play as numbers" do
    test "pgn/1" do
      assert "40/5400+30:1800+30" ==
               TimeControl.pgn("90min/40moves+30min/end+30sec/move from move 1")

      assert "5400+30" == TimeControl.pgn("90min/end+30sec/move from move 1")
      assert "7200" == TimeControl.pgn("120min/end")

      assert "40/7200:900+30" ==
               TimeControl.pgn("120min/40moves+15min/end+30sec/move from move 41")

      # An increment from a move that starts no period, a delay clock, prose:
      # no tag rather than a wrong one.
      assert nil == TimeControl.pgn("120min/40moves+15min/end+30sec/move from move 40")
      assert nil == TimeControl.pgn("90min/end+30sec DELAY /move from move 1")
      assert nil == TimeControl.pgn("as agreed")
      assert nil == TimeControl.pgn(nil)
    end
  end

  describe "PGN" do
    setup %{scope: scope, tournament: t} do
      {:ok, link, _secret} = BoardLink.create_link(scope, t)
      %{link: link}
    end

    test "headers from the tournament, moves from the board, result from the arbiter", %{
      link: link,
      tournament: t,
      boards: [board1, _board2]
    } do
      {:ok, _} =
        BoardLink.report(
          link,
          t,
          report_for(board1, %{
            "status" => "finished",
            "result" => "1-0",
            "move_clocks" => [5_398_000, 5_391_000, nil]
          })
        )

      # Not entered yet: the board saw 1-0, the tournament knows nothing.
      pgn = PgnExport.export(t, nil, moves: true, game: board1.game_uid)

      assert pgn =~ ~s([Event "Board Link Open"])
      assert pgn =~ ~s([Round "1.1"])
      assert pgn =~ ~s([White "Player 1"])
      assert pgn =~ ~s([Black "Player 2"])
      assert pgn =~ ~s([Result "*"])
      assert pgn =~ ~s([WhiteElo "1990"])
      assert pgn =~ ~s([TimeControl "40/5400+30:1800+30"])
      assert pgn =~ "1. e4 {[%clk 1:29:58]} e5 {[%clk 1:29:51]} 2. Nf3 *"
      refute pgn =~ "Player 3"

      {:ok, _} = Tournaments.update_pairing_result(board1, "1/2-1/2")
      pgn = PgnExport.export(t, nil, moves: true, game: board1.game_uid)
      assert pgn =~ ~s([Result "1/2-1/2"])
      assert pgn =~ "2. Nf3 1/2-1/2"
    end

    test "a round and the whole tournament, a board without a report included", %{
      link: link,
      tournament: t,
      boards: [board1, _board2]
    } do
      {:ok, _} = BoardLink.report(link, t, report_for(board1))

      whole = PgnExport.export(t, nil, moves: true)
      assert whole == PgnExport.export(t, 1, moves: true)
      assert whole =~ "1. e4 e5 2. Nf3 *"
      assert whole =~ ~s([Round "1.2"])
      assert whole =~ ~s([White "Player 3"])
    end

    test "the plain export is what it always was", %{link: link, tournament: t, boards: [b | _]} do
      before = PgnExport.export(t)
      {:ok, _} = BoardLink.report(link, t, report_for(b))
      assert before == PgnExport.export(t)
      refute before =~ "e4"
    end
  end

  describe "export and import" do
    test "the games travel; the codes and the relay key do not", %{
      scope: scope,
      tournament: t,
      boards: [board1 | _]
    } do
      {:ok, link, secret} = BoardLink.create_link(scope, t)
      {:ok, t} = BoardLink.set_relay_key(scope, t, "orrk_0123456789abcdef")

      {:ok, _} =
        BoardLink.report(
          link,
          t,
          report_for(board1, %{"status" => "finished", "result" => "0-1"})
        )

      envelope = TournamentExport.export_tournament(t)
      json = Jason.encode!(envelope)

      refute json =~ "orrk_0123456789abcdef"
      refute json =~ secret
      refute json =~ link.secret_hash

      assert [%{"board_games" => [%{"game_uid" => uid, "moves" => ["e4", "e5", "Nf3"]}]}] =
               envelope["tournaments"]

      assert uid == board1.game_uid

      {:ok, [copy]} = TournamentImport.import(Jason.decode!(json), scope)

      assert %Game{result: "0-1", status: "finished", moves: ["e4", "e5", "Nf3"]} =
               BoardLink.get_game(copy.id, board1.game_uid)

      assert copy.openresults_relay_key == nil
      assert %{tournament: [], group: []} = BoardLink.list_links(copy)
      # And the code still opens the original, and only the original.
      assert {:ok, original_link} = BoardLink.authenticate(secret)
      assert :error = BoardLink.fetch_covered(original_link, copy.id)
    end

    test "an envelope without the block imports as before", %{scope: scope, tournament: t} do
      envelope = TournamentExport.export_tournament(t)

      stripped =
        update_in(envelope, ["tournaments"], fn entries ->
          Enum.map(entries, &Map.delete(&1, "board_games"))
        end)

      assert {:ok, [copy]} =
               TournamentImport.import(Jason.decode!(Jason.encode!(stripped)), scope)

      assert %{} == BoardLink.games_by_uid(copy.id)
    end
  end
end
