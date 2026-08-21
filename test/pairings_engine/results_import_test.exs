defmodule PairingsEngine.ResultsImportTest do
  # async: false - writes through the same Repo tables as every other
  # import/export test (see TrfExportTest's comment).
  use PairingsEngine.DataCase, async: false

  import PairingsEngine.AccountsFixtures

  alias PairingsEngine.{Repo, ResultsImport, Tournaments}
  alias PairingsEngine.Tournaments.{Player, Round, Pairing}

  ## ---------- parse_text/1 ----------

  describe "parse_text/1" do
    test "parses comma-separated board,result lines" do
      csv = "1,1-0\n2,0-1\n3,1/2-1/2\n"
      assert ResultsImport.parse_text(csv) == {:ok, [{1, "1-0"}, {2, "0-1"}, {3, "1/2-1/2"}]}
    end

    test "auto-detects semicolon separator" do
      csv = "1;1-0\n2;0-1\n"
      assert ResultsImport.parse_text(csv) == {:ok, [{1, "1-0"}, {2, "0-1"}]}
    end

    test "skips an optional header row" do
      csv = "board,result\n1,1-0\n2,0-1\n"
      assert ResultsImport.parse_text(csv) == {:ok, [{1, "1-0"}, {2, "0-1"}]}
    end

    test "ignores blank lines" do
      csv = "1,1-0\n\n\n2,0-1\n"
      assert ResultsImport.parse_text(csv) == {:ok, [{1, "1-0"}, {2, "0-1"}]}
    end

    test "accepts every result token including symbolic and forfeit variants" do
      csv = """
      1,1-0
      2,0-1
      3,1/2-1/2
      4,½-½
      5,0.5-0.5
      6,=
      7,0-0
      8,X
      9,1-0FF
      10,+/-
      11,0-1FF
      12,-/+
      13,0-0FF
      14,-/-
      """

      assert {:ok, rows} = ResultsImport.parse_text(csv)

      assert rows == [
               {1, "1-0"},
               {2, "0-1"},
               {3, "1/2-1/2"},
               {4, "1/2-1/2"},
               {5, "1/2-1/2"},
               {6, "1/2-1/2"},
               {7, "0-0"},
               {8, "0-0"},
               {9, "1-0FF"},
               {10, "1-0FF"},
               {11, "0-1FF"},
               {12, "0-1FF"},
               {13, "0-0FF"},
               {14, "0-0FF"}
             ]
    end

    test "results are case-insensitive" do
      assert ResultsImport.parse_text("1,ff\n") ==
               {:error, ["line 1: unrecognized result \"ff\""]}

      assert ResultsImport.parse_text("1,x\n") == {:ok, [{1, "0-0"}]}
    end

    test "decodes a Windows-1252 byte string (with accented player-adjacent content)" do
      # 0xE9 is "é" in Windows-1252/Latin-1 but invalid on its own as UTF-8 -
      # forces the CP1252 fallback path.
      csv = <<"1,1-0 ", 0xE9, "\n">>
      assert {:error, _} = ResultsImport.parse_text(csv)
      refute String.valid?(csv)
    end

    test "tolerates a UTF-8 BOM" do
      csv = <<0xEF, 0xBB, 0xBF>> <> "1,1-0\n"
      assert ResultsImport.parse_text(csv) == {:ok, [{1, "1-0"}]}
    end

    test "malformed lines are all collected, not just the first" do
      csv = "1,1-0\nnope\n3,huh\n"
      assert {:error, errors} = ResultsImport.parse_text(csv)
      assert length(errors) == 2
      assert Enum.any?(errors, &(&1 =~ "line 2"))
      assert Enum.any?(errors, &(&1 =~ "line 3"))
    end

    test "duplicate boards are rejected" do
      csv = "1,1-0\n1,0-1\n"
      assert {:error, [error]} = ResultsImport.parse_text(csv)
      assert error =~ "board 1"
      assert error =~ "more than once"
    end

    test "empty file is an error" do
      assert {:error, ["The file is empty"]} = ResultsImport.parse_text("")
    end
  end

  ## ---------- apply_import/3 ----------

  # 4 players, board 1 (a vs b) and board 2 (c vs d), round 1.
  defp fixture(scope) do
    {:ok, tournament} =
      Tournaments.create_tournament(scope, %{
        "name" => "Results Import Test",
        "type" => "swiss",
        "rounds_count" => "3"
      })

    [a, b, c, d] =
      for name <- ["A", "B", "C", "D"] do
        Repo.insert!(%Player{tournament_id: tournament.id, name: name})
      end

    round = Repo.insert!(%Round{tournament_id: tournament.id, number: 1, status: "playing"})

    p1 =
      Repo.insert!(%Pairing{
        round_id: round.id,
        board: 1,
        white_player_id: a.id,
        black_player_id: b.id,
        result: ""
      })

    p2 =
      Repo.insert!(%Pairing{
        round_id: round.id,
        board: 2,
        white_player_id: c.id,
        black_player_id: d.id,
        result: ""
      })

    bye =
      Repo.insert!(%Pairing{
        round_id: round.id,
        board: 3,
        white_player_id: a.id,
        black_player_id: nil,
        result: "bye"
      })

    {tournament, %{p1: p1, p2: p2, bye: bye}}
  end

  describe "apply_import/3" do
    test "writes every row's result" do
      scope = user_scope_fixture()
      {tournament, %{p1: p1, p2: p2}} = fixture(scope)

      assert {:ok, 2} = ResultsImport.apply_import(tournament, 1, [{1, "1-0"}, {2, "0-1"}])

      assert Repo.reload!(p1).result == "1-0"
      assert Repo.reload!(p2).result == "0-1"
    end

    test "partial entry: boards left out keep their current result" do
      scope = user_scope_fixture()
      {tournament, %{p1: p1, p2: p2}} = fixture(scope)
      Tournaments.update_pairing_result(p2, "1/2-1/2")

      assert {:ok, 1} = ResultsImport.apply_import(tournament, 1, [{1, "1-0"}])

      assert Repo.reload!(p1).result == "1-0"
      assert Repo.reload!(p2).result == "1/2-1/2"
    end

    test "unknown board is rejected and nothing is written (all-or-nothing)" do
      scope = user_scope_fixture()
      {tournament, %{p1: p1, p2: p2}} = fixture(scope)

      assert {:error, errors} =
               ResultsImport.apply_import(tournament, 1, [{1, "1-0"}, {99, "0-1"}])

      assert Enum.any?(errors, &(&1 =~ "board 99"))

      assert Repo.reload!(p1).result == ""
      assert Repo.reload!(p2).result == ""
    end

    test "a bye board is rejected and nothing is written" do
      scope = user_scope_fixture()
      {tournament, %{p1: p1}} = fixture(scope)

      assert {:error, errors} =
               ResultsImport.apply_import(tournament, 1, [{1, "1-0"}, {3, "0-1"}])

      assert Enum.any?(errors, &(&1 =~ "board 3"))
      assert Enum.any?(errors, &(&1 =~ "bye"))

      assert Repo.reload!(p1).result == ""
    end

    test "unpaired round is rejected" do
      scope = user_scope_fixture()
      {tournament, _} = fixture(scope)

      assert {:error, [error]} = ResultsImport.apply_import(tournament, 2, [{1, "1-0"}])
      assert error =~ "Round 2"
    end
  end
end
