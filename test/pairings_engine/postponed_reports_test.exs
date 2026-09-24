defmodule PairingsEngine.PostponedReportsTest do
  @moduledoc """
  Postponed games, second part: the per-tournament setting and provisional
  score, and sending results - the TRF marked as sent, the reports after it,
  and the postponed-games TRF. The rule under test above all: no wrong TRF
  data is ever sent, and no game is sent twice.
  """
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.{
    Compliance,
    Pairing,
    PostponedGames,
    Repo,
    Standings,
    TrfExport,
    TrfImport,
    Tournaments
  }

  alias PairingsEngine.Federations.BEL.SwarPublish
  alias PairingsEngine.Tournaments.Tournament

  import PairingsEngine.AccountsFixtures, only: [user_scope_fixture: 0]

  defp tournament(attrs \\ []) do
    t =
      Repo.insert!(
        struct(
          Tournament,
          Map.merge(
            %{
              name: "Club championship",
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
      for {name, rating} <- [{"Alice", 2000}, {"Bob", 1900}, {"Carol", 1800}, {"Dave", 1700}],
          into: %{} do
        {:ok, p} =
          Tournaments.create_player(t.id, %{tournament_id: t.id, name: name, fide_rating: rating})

        {name, p}
      end

    {t, players}
  end

  defp pair!(t, opts \\ []) do
    {:ok, round} = Pairing.pair_next_round(Repo.reload!(t), opts)
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

  defp rank(t, player_id),
    do: Enum.find(Tournaments.list_players(t.id), &(&1.id == player_id)).pairing_number

  # The `001` line of `rank`, and the round `r` result character on it.
  defp line_of(text, rank) do
    text
    |> String.split("\r\n")
    |> Enum.find(fn line ->
      String.starts_with?(line, "001") and
        line |> String.slice(4, 4) |> String.trim() == Integer.to_string(rank)
    end)
  end

  defp result_char(line, r), do: String.at(line, 98 + (r - 1) * 10)

  describe "the tickbox" do
    test "off (the default): no postponed code can be written, and pairing never offers one" do
      {t, %{"Alice" => alice}} = tournament(postponed_games: false)
      round1 = pair!(t)
      board = board_of(round1, alice)

      assert {:error, :postponed_games_off} = Tournaments.update_pairing_result(board, "*W")
      assert Repo.reload!(board).result == ""

      others!(round1, board)
      assert PostponedGames.pairing_warnings(Repo.reload!(t)) == []
    end

    test "a fresh tournament starts with it off, and both values a draw" do
      t = %Tournament{}
      refute t.postponed_games
      assert {t.postponed_requester_outcome, t.postponed_opponent_outcome} == {"draw", "draw"}
    end
  end

  describe "the provisional score" do
    test "the player who postponed can count higher, everywhere - pairing included" do
      {t, %{"Alice" => alice}} =
        tournament(postponed_requester_outcome: "win", postponed_opponent_outcome: "draw")

      round1 = pair!(t)
      board = round1 |> board_of(alice) |> result!("*W")
      others!(round1, board)

      assert board.postponed_by == "white"
      assert {board.provisional_white, board.provisional_black} == {"win", "draw"}

      scores = Standings.player_scores_before_round(t, 2)
      assert scores[board.white_player_id] == t.points_win
      assert scores[board.black_player_id] == t.points_draw

      # The engine is handed a legal played draw - colours count, they have
      # met - with the provisional score in the points column it brackets by.
      rows = Pairing.trf_player_rows(Repo.reload!(t), Tournaments.list_players(t.id))
      white_row = Enum.find(rows, &(&1.id == board.white_player_id))
      assert hd(white_row.games).result == "="
      assert white_row.points == t.points_win

      assert %{number: 2} = pair!(t)
    end

    test "changing the setting later leaves games already postponed alone" do
      {t, %{"Alice" => alice}} = tournament(postponed_requester_outcome: "win")
      board = t |> pair!() |> board_of(alice) |> result!("*B")

      {:ok, _} =
        Tournaments.update_tournament(Repo.reload!(t), %{"postponed_requester_outcome" => "draw"})

      assert Repo.reload!(board).provisional_black == "win"
    end

    test "anything but a draw is a departure from FIDE mode, and only while postponed games are on" do
      codes = fn t -> t |> Compliance.check() |> Enum.map(& &1.code) end

      assert :postponed_requester_not_draw in codes.(%Tournament{
               postponed_games: true,
               postponed_requester_outcome: "win"
             })

      refute :postponed_requester_not_draw in codes.(%Tournament{
               postponed_games: false,
               postponed_requester_outcome: "win"
             })

      assert codes.(%Tournament{postponed_games: true}) == []
    end

    test "who postponed it, and when it was played, outlive the result" do
      {t, %{"Alice" => alice}} = tournament()
      board = t |> pair!() |> board_of(alice) |> result!("*B")

      played = result!(board, "1/2-1/2", played_on: ~D[2026-09-25])

      assert played.postponed_by == "black"
      assert played.played_on == ~D[2026-09-25]
    end
  end

  describe "finalising a TRF for sending" do
    test "marks every board of the rounds, an open postponed game as sent as ?" do
      {t, %{"Alice" => alice}} = tournament()
      round1 = pair!(t)
      postponed = round1 |> board_of(alice) |> result!("*W")
      [other] = others!(round1, postponed)

      assert {:ok, 2} = PostponedGames.finalise(Repo.reload!(t), [1])

      assert %{finalised_open: true, finalised_at: %DateTime{}} = Repo.reload!(postponed)
      assert %{finalised_open: false, finalised_at: %DateTime{}} = Repo.reload!(other)

      # Twice is a no-op: nothing is re-marked.
      assert {:ok, 0} = PostponedGames.finalise(Repo.reload!(t), [1])
    end

    test "is refused, marking nothing, while a round has a board with no result" do
      {t, %{"Alice" => alice}} = tournament()
      round1 = pair!(t)
      open = board_of(round1, alice)
      others!(round1, open)

      assert {:error, {:blank_results, [1]}} = PostponedGames.finalise(Repo.reload!(t), [1])
      assert Enum.all?(Tournaments.get_round(t.id, 1).pairings, &is_nil(&1.finalised_at))
    end

    test "a sent result is semi-frozen: changing it asks first" do
      {t, %{"Alice" => alice}} = tournament()
      round1 = pair!(t)
      postponed = round1 |> board_of(alice) |> result!("*W")
      [other] = others!(round1, postponed)
      {:ok, _} = PostponedGames.finalise(Repo.reload!(t), [1])

      assert {:error, {:needs_acknowledgement, [:finalised_result_changed]}} =
               Tournaments.update_pairing_result(other, "0-1")

      assert result!(other, "0-1", acknowledged: [:finalised_result_changed]).result == "0-1"

      # The game sent as `?` still takes its real result without that: it
      # was never sent with one.
      assert result!(postponed, "1/2-1/2").result == "1/2-1/2"
    end
  end

  describe "the main report after it was sent" do
    test "a game sent as ? stays ? in every later report; its real result never appears there" do
      {t, %{"Alice" => alice}} = tournament()
      round1 = pair!(t)
      postponed = round1 |> board_of(alice) |> result!("*W")
      others!(round1, postponed)
      {:ok, before} = TrfExport.export(Repo.reload!(t), [1])
      {:ok, _} = PostponedGames.finalise(Repo.reload!(t), [1])

      result!(postponed, "1-0", acknowledged: [:adjourned_non_draw_result])
      {:ok, later} = TrfExport.export(Repo.reload!(t), [1])

      for id <- [postponed.white_player_id, postponed.black_player_id] do
        line = line_of(later, rank(t, id))
        assert result_char(line, 1) == "?"
        # Scored at the file's own X, a draw - as it was sent.
        assert line |> String.slice(80, 4) |> String.trim() == "0.5"
      end

      # Byte for byte the report that was sent, but for the generator stamp.
      strip = fn text -> text |> String.split("\r\n") |> Enum.reject(&(&1 =~ ~r/^0[0-9][0-9] /)) end
      assert strip.(later) -- strip.(before) == []
    end

    test "a game played before its round was sent goes in that round with its result" do
      {t, %{"Alice" => alice}} = tournament()
      round1 = pair!(t)
      postponed = round1 |> board_of(alice) |> result!("*W")
      others!(round1, postponed)
      result!(postponed, "1/2-1/2", played_on: ~D[2026-09-25])

      {:ok, text} = TrfExport.export(Repo.reload!(t), [1])
      {:ok, _} = PostponedGames.finalise(Repo.reload!(t), [1])

      assert result_char(line_of(text, rank(t, postponed.white_player_id)), 1) == "="
      assert PostponedGames.sendable_late_games(Repo.reload!(t)) == []
    end
  end

  describe "the postponed-games TRF" do
    test "carries each late game once, in an extra round, and never again once sent" do
      {t, %{"Alice" => alice}} = tournament()
      round1 = pair!(t)
      postponed = round1 |> board_of(alice) |> result!("*W")
      others!(round1, postponed)
      {:ok, _} = PostponedGames.finalise(Repo.reload!(t), [1])
      result!(postponed, "1-0", acknowledged: [:adjourned_non_draw_result], played_on: ~D[2026-10-02])

      assert {:ok, text, [game]} = TrfExport.postponed_export(Repo.reload!(t))
      assert game.pairing.id == postponed.id

      parsed = Ainalrami.Trf.parse(text)
      # Only the two players of the game, under their own starting ranks.
      assert Enum.sort(Enum.map(parsed.players, & &1.rank)) ==
               Enum.sort([rank(t, postponed.white_player_id), rank(t, postponed.black_player_id)])

      white = Enum.find(parsed.players, &(&1.rank == rank(t, postponed.white_player_id)))
      assert [%{result: "1", colour: "w"}] = white.games
      assert text =~ "26/10/02"

      :ok = PostponedGames.mark_late_games_sent([game])

      assert {:error, :nothing_to_send} = TrfExport.postponed_export(Repo.reload!(t))

      assert {:error, :already_sent} =
               Tournaments.set_played_on(Repo.reload!(postponed), ~D[2026-10-03])
    end
  end

  describe "packing late games into rounds" do
    defp game(id, w, b), do: %{id: id, white_player_id: w, black_player_id: b}

    defp valid?(rounds) do
      Enum.all?(rounds, fn games ->
        players = Enum.flat_map(games, &[&1.white_player_id, &1.black_player_id])
        length(players) == length(Enum.uniq(players))
      end)
    end

    test "nobody plays twice in a round, every game once, as few rounds as possible" do
      games = [game(1, :a, :b), game(2, :c, :d), game(3, :a, :c), game(4, :b, :d)]
      rounds = PostponedGames.pack(games)

      assert valid?(rounds)
      assert Enum.sort(Enum.map(List.flatten(rounds), & &1.id)) == [1, 2, 3, 4]
      assert length(rounds) == 2
    end

    test "an odd cycle needs one round more than any player's own games" do
      rounds = PostponedGames.pack([game(1, :a, :b), game(2, :b, :c), game(3, :c, :a)])

      assert valid?(rounds)
      assert length(rounds) == 3
    end

    test "nothing to pack is no rounds" do
      assert PostponedGames.pack([]) == []
    end
  end

  describe "elsewhere" do
    test "the KBSB page says Voorlopige stand while a game is postponed" do
      {t, %{"Alice" => alice}} = tournament()
      board = t |> pair!() |> board_of(alice) |> result!("*W")

      assert SwarPublish.export(Repo.reload!(t)) =~ "Voorlopige stand"

      result!(board, "1/2-1/2")
      html = SwarPublish.export(Repo.reload!(t))
      assert html =~ "Eindstand"
      refute html =~ "Voorlopige stand"
    end

    test "a TRF with ? imports with postponed games allowed, each counting as a draw" do
      {t, %{"Alice" => alice}} = tournament()
      round1 = pair!(t)
      postponed = round1 |> board_of(alice) |> result!("*W")
      others!(round1, postponed)
      {:ok, text} = TrfExport.export(Repo.reload!(t))

      {:ok, imported, _warnings} = TrfImport.import_text(text, user_scope_fixture())

      assert imported.postponed_games
      [game] = PostponedGames.open_games(imported)
      assert {game.pairing.provisional_white, game.pairing.provisional_black} == {"draw", "draw"}
    end
  end
end
