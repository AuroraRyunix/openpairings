defmodule PairingsEngine.TrfUnknownResultTest do
  # TRF26's unknown result: `?` in a `001` record, worth what the `162`
  # record's `X` says (a draw's points when it says nothing). Imported as a
  # postponed game counted at that value, exported as `?` with the same `X`,
  # paired on as a played game, and overwritten by the real result when it
  # turns up.
  #
  # async: false - whole tournaments through real transactions (SQLite has
  # one writer), like trf_import_test.exs.
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{Repo, Standings, TrfExport, TrfImport, Tournaments}
  alias PairingsEngine.Pairing, as: PairingCtx
  alias PairingsEngine.Accounts.{Scope, User}
  alias PairingsEngine.Tournaments.Round

  defp user_scope do
    user =
      Repo.insert!(%User{
        email: "user#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    Scope.for_user(user)
  end

  # Exact 1-indexed column placement, as trf_import_test.exs builds its
  # lines: hand-typed spacing is how column bugs hide.
  defp col(line, position, text) do
    text = to_string(text)
    needed = position - 1 + String.length(text)
    line = if String.length(line) < needed, do: String.pad_trailing(line, needed), else: line
    {before, rest} = String.split_at(line, position - 1)
    {_, after_} = String.split_at(rest, String.length(text))
    before <> text <> after_
  end

  defp player(rank, name, points, rounds) do
    line =
      ""
      |> col(1, "001")
      |> col(5, String.pad_leading(to_string(rank), 4))
      |> col(15, name)
      |> col(81, String.pad_leading(points, 4))
      |> col(86, String.pad_leading(to_string(rank), 4))

    rounds
    |> Enum.with_index()
    |> Enum.reduce(line, fn {{opp, colour, result}, i}, acc ->
      base = 92 + i * 10

      acc
      |> col(base, String.pad_leading(to_string(opp), 4))
      |> col(base + 5, colour)
      |> col(base + 7, result)
    end)
  end

  defp pts(value), do: :erlang.float_to_binary(value, decimals: 1)

  # What `?` is worth in `file/1`: its `X`, or the draw without one.
  defp x_value(nil), do: 0.5
  defp x_value(x), do: x

  # Round 1: Alpha v Bravo, result unknown; Charlie beats Delta. Round 2:
  # Alpha (black) beats Charlie, Bravo and Delta draw. The points columns
  # add up under `x` (nil: no `X` in the file, so a draw).
  defp file(x) do
    value = x_value(x)

    x_entry = if x, do: "    X #{pts(x)}", else: ""

    ([
       "012 Unknown result",
       "022 Ghent",
       "032 BEL",
       "042 2026-01-01",
       "052 2026-01-02",
       "062 4",
       "092 Individual: Swiss-System",
       "142 4",
       "" |> col(1, "132") |> col(92, "26/01/01") |> col(102, "26/01/02"),
       "162  W 1.0    D 0.5    L 0.0    A 0.0    P 1.0" <> x_entry,
       player(1, "Alpha, One", pts(1.0 + value), [{2, "w", "?"}, {3, "b", "1"}]),
       player(2, "Bravo, Two", pts(0.5 + value), [{1, "b", "?"}, {4, "w", "="}]),
       player(3, "Charlie, Three", "1.0", [{4, "w", "1"}, {1, "w", "0"}]),
       player(4, "Delta, Four", "0.5", [{3, "b", "0"}, {2, "b", "="}])
     ]
     |> Enum.join("\r\n")) <> "\r\n"
  end

  defp import!(text) do
    {:ok, t, report} = TrfImport.import_with_report(text, user_scope())
    {Tournaments.get_tournament!(t.id), report}
  end

  defp round_one(t) do
    Round
    |> Repo.get_by!(tournament_id: t.id, number: 1)
    |> Repo.preload(pairings: [:white_player, :black_player])
  end

  defp unknown_board(t), do: Enum.find(round_one(t).pairings, &(&1.result == "*"))

  # A tournament out of FIDE mode exports with an open postponed game; in
  # FIDE mode VCL4THP Q169 refuses any TRF until the game has a result or is
  # recorded as not played in this event - see the FIDE-mode test below.
  defp out_of_fide_mode(t) do
    t
    |> Ecto.Changeset.change(fide_compliance_lost_round: 0)
    |> Repo.update!()
  end

  defp export!(t, rounds \\ nil) do
    {:ok, text} = TrfExport.export(Tournaments.get_tournament!(t.id), rounds)
    text
  end

  defp lines_001(text) do
    for "001" <> _ = line <- String.split(text, ~r/\r?\n/), do: line
  end

  # Starting rank => {points column, round 1 result}.
  defp columns(text) do
    Map.new(lines_001(text), fn line ->
      rank = line |> String.slice(4, 4) |> String.trim() |> String.to_integer()
      points = line |> String.slice(80, 4) |> String.trim() |> String.to_float()
      {rank, {points, String.slice(line, 98, 1)}}
    end)
  end

  defp points_warnings(report), do: Enum.filter(report.warnings, &(&1.kind == :points))

  describe "importing a ? valued by X" do
    for {x, outcome} <- [{nil, "draw"}, {0.5, "draw"}, {0.0, "loss"}, {1.0, "win"}] do
      test "X = #{inspect(x)}: a postponed game counted as #{outcome} for both" do
        {t, report} = import!(file(unquote(x)))
        board = unknown_board(t)

        assert board.provisional_white == unquote(outcome)
        assert board.provisional_black == unquote(outcome)

        # The file's points column adds up from its own X, so the import
        # finds nothing to complain about in it.
        assert points_warnings(report) == []

        assert [assumed] = Enum.filter(report.warnings, &(&1.kind == :unknown_results_assumed))
        assert assumed.outcome == String.to_atom(unquote(outcome))
        assert assumed.points == x_value(unquote(x))
        refute Enum.any?(report.warnings, &(&1.kind in [:verification_failed, :round_unverified]))
      end
    end

    test "an X other than the draw becomes the tournament's postponed valuation" do
      {t, _report} = import!(file(0.0))

      assert t.postponed_games
      assert t.postponed_requester_outcome == "loss"
      assert t.postponed_opponent_outcome == "loss"
    end

    test "no X leaves the settings at FIDE's draw" do
      {t, _report} = import!(file(nil))

      assert t.postponed_games
      assert t.postponed_requester_outcome == "draw"
      assert t.postponed_opponent_outcome == "draw"
    end

    test "an X that is no win, draw or loss is refused, naming the value" do
      assert {:error, message} = TrfImport.import_text(file(0.3), user_scope())
      assert message =~ "0.3"
      assert message =~ "X in record 162"
    end
  end

  describe "the round trip" do
    for x <- [nil, 0.0, 1.0] do
      test "X = #{inspect(x)}: exported as ? with the same X, and re-imported the same" do
        x = unquote(x)
        {t, _report} = import!(file(x))
        text = t |> out_of_fide_mode() |> export!()

        # Both seats of the lost game are `?` again, in the columns the
        # file had them in, and the points columns are the file's.
        original = columns(file(x))
        assert columns(text) == original
        assert text =~ ~r/^162 .*X #{Regex.escape(pts(x_value(x)))}/m

        {again, report} = import!(text)
        board = unknown_board(again)
        assert board.provisional_white == unknown_board(t).provisional_white
        assert board.provisional_black == unknown_board(t).provisional_black
        assert points_warnings(report) == []
      end
    end
  end

  describe "pairing, standings and the real result" do
    test "the next round pairs, the standings count X, and the real result replaces it" do
      {t, _report} = import!(file(0.0))

      t
      |> Ecto.Changeset.change(tiebreaks: ["BH"])
      |> Repo.update!()

      t = Tournaments.get_tournament!(t.id)
      totals = fn t -> Map.new(Standings.standings(t), &{&1.player.name, &1.total}) end

      # X = 0: Alpha and Bravo scored nothing for the lost game.
      assert totals.(t) == %{
               "Alpha, One" => 1.0,
               "Bravo, Two" => 0.5,
               "Charlie, Three" => 1.0,
               "Delta, Four" => 0.5
             }

      assert Enum.all?(Standings.standings(t), &is_map(&1.tiebreaks))

      # The open game from an older round is confirmed, as any postponed
      # game is (VCL4THP Q168); nothing crashes on the way.
      assert {:ok, %Round{number: 3}} =
               PairingCtx.pair_next_round(t, acknowledged: [:adjourned_older_round_open])

      # The scoresheet turns up: Alpha won. It is an ordinary result now.
      board = unknown_board(t)

      assert {:ok, _} =
               Tournaments.update_pairing_result(board, "1-0",
                 acknowledged: [:adjourned_non_draw_result]
               )

      t = Tournaments.get_tournament!(t.id)
      assert totals.(t)["Alpha, One"] == 2.0
      assert totals.(t)["Bravo, Two"] == 0.5

      # Rounds 1-2: round 3 has no date, and no `?` either way.
      text = t |> out_of_fide_mode() |> export!([1, 2])
      assert columns(text)[1] == {2.0, "1"}
      refute Enum.any?(lines_001(text), &(String.slice(&1, 98, 1) == "?"))
    end

    test "the engine is handed the game as played, colours and all" do
      {t, _report} = import!(file(nil))
      players = Tournaments.list_players(t.id)
      rows = PairingCtx.trf_player_rows(t, players)
      alpha = Enum.find(rows, &(&1.rank == 1))
      [game | _] = alpha.games

      assert game.opponent_rank == 2
      assert game.colour == "w"
      assert game.result == "="
      assert game.provisional_points == 0.5
    end
  end

  describe "in FIDE mode" do
    test "no TRF goes out while the game is open (VCL4THP Q169), as for any postponed game" do
      {t, _report} = import!(file(nil))

      assert PairingsEngine.Compliance.fide_mode?(t)
      assert {:error, {:open_postponed, [_]}} = TrfExport.export(t)
    end
  end
end
