defmodule PairingsEngine.ImportBoundsTest do
  @moduledoc """
  What each importer refuses at the door, and what it must still accept.

  Every test here comes in a pair. One feeds input that is absurd for the
  format and asserts the refusal; the other feeds the largest input that is
  still legitimate - a field bigger than any tournament ever played, a line
  as long as the longest record TRF16 can hold, a CSV covering a whole
  round - and asserts it still goes through. A bound that cannot tell those
  two apart is not a bound, it is a bug waiting to be reported as "the
  import stopped working".

  The refusals are asserted as refusals, never as elapsed time: the defects
  behind them are quadratic loops, and a wall-clock assertion for one of
  those is a test that fails on a busy machine and passes on a fast one.

  See the "input bounds" sections in `PairingsEngine.TrfImport`,
  `PairingsEngine.ResultsImport` and `PairingsEngine.TournamentImport` for
  where each number comes from.
  """
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.{ResultsImport, TournamentImport, TrfImport}

  ## ---------- TRF16 ----------

  # A TRF record is fixed-column, so the test builds one by writing fields
  # into a blank line at their documented offsets rather than by counting
  # spaces in a string literal.
  defp at(line, col, text) do
    at = col - 1

    binary_part(line, 0, at) <>
      text <> binary_part(line, at + byte_size(text), byte_size(line) - at - byte_size(text))
  end

  defp blank(width), do: String.duplicate(" ", width)

  # Columns per the TRF16 spec: code 1-3, starting rank 5-8, name 15-47,
  # points 81-84. Everything else is left blank, which the parser allows.
  defp player_line(rank, name \\ "Player, Test", width \\ 91) do
    blank(width)
    |> at(1, "001")
    |> at(5, String.pad_leading(to_string(rank), 4))
    |> at(15, String.pad_trailing(name, 33))
    |> at(81, " 0.0")
  end

  # The same, plus all 30 round blocks: a block starts at column 92 and
  # repeats every 10, with the opponent id in the first four columns and
  # the result in the eighth. A half-point bye ("H") against opponent 0000
  # is the shortest thing a round column can legally say about a lone
  # player.
  defp thirty_round_player_line do
    Enum.reduce(1..30, player_line(1, "Player, Test", 91 + 10 * 30), fn r, line ->
      base = 92 + (r - 1) * 10

      line
      |> at(base, "0000")
      |> at(base + 7, "H")
    end)
  end

  # The "132" round-dates line: an 8-character YY/MM/DD in every round slot,
  # which start at column 92 and repeat every 10.
  defp round_dates_line(rounds) do
    blank(91 + 10 * rounds)
    |> at(1, "132")
    |> then(fn line ->
      Enum.reduce(1..rounds, line, fn r, acc -> at(acc, 92 + (r - 1) * 10, "26/01/01") end)
    end)
  end

  defp trf(lines), do: Enum.join(lines, "\r\n")

  describe "a TRF with more records than the format can describe" do
    test "is refused, naming the count" do
      text = trf(Enum.map(1..20_001, &player_line/1))

      assert {:error, {:parse_failed, message}} = TrfImport.build_structs(text)
      assert message =~ "20001 lines"
      assert message =~ "not a tournament report"
    end

    test "but a field larger than any tournament ever played still imports" do
      # 3,000 players is more than the biggest Swiss that has been run, and
      # is the shape the refusal above must not catch: same record type,
      # same line width, only fewer of them.
      text = trf(Enum.map(1..3_000, &player_line(&1, "Player #{&1}")))

      assert {:ok, {_tournament, players}} = TrfImport.build_structs(text)
      assert length(players) == 3_000
    end
  end

  describe "a TRF holding one enormous line" do
    test "is refused, naming the line length" do
      # Two lines, and the file hangs the parser: `parse_round_dates/3`
      # re-measures the whole line at every 10-column step, so the cost is
      # quadratic in this one line's length.
      text = trf([player_line(1), "132 " <> String.duplicate("26/01/01", 1_000)])

      assert {:error, {:parse_failed, message}} = TrfImport.build_structs(text)
      assert message =~ "-byte line"
      assert message =~ "fixed-column"
    end

    test "but a full-width 30-round file still imports" do
      # 30 rounds is `Tournament.max_rounds/0` - the longest event this app
      # will hold - so these are the longest `001` and `132` lines a
      # legitimate file can carry, and both must pass. The player's own line
      # carries all 30 round blocks, so the file really is 30 rounds long
      # rather than merely padded to that width.
      text = trf([thirty_round_player_line(), round_dates_line(30)])

      assert {:ok, {tournament, players}} = TrfImport.build_structs(text)
      assert length(players) == 1
      assert tournament.rounds_count == 30
      assert length(tournament.round_dates) == 30
    end
  end

  describe "a TRF larger than the format can be" do
    test "is refused without being parsed" do
      # Deliberately not valid TRF at all: if this came back complaining
      # about the CONTENT, the size gate would not have run first.
      text = String.duplicate("x", 5_000_001)

      assert {:error, {:parse_failed, message}} = TrfImport.build_structs(text)
      assert message =~ "5 MB"
      assert message =~ "9,999 players"
    end
  end

  ## ---------- results CSV ----------

  describe "a results CSV with more lines than a round has boards" do
    test "is refused with a single message" do
      text = Enum.map_join(1..10_001, "\n", fn i -> "#{i},1-0" end)

      assert {:error, [message]} = ResultsImport.parse_text(text)
      assert message =~ "10001 lines"
    end

    test "but a CSV covering a whole round of a very large open still parses" do
      text = Enum.map_join(1..1_250, "\n", fn i -> "#{i},1-0" end)

      assert {:ok, rows} = ResultsImport.parse_text(text)
      assert length(rows) == 1_250
    end
  end

  describe "a results CSV where every line is wrong" do
    test "reports a bounded number of problems and counts the rest" do
      # A good first line, so it is treated as data rather than skipped as a
      # header row - the 5,000 bad lines after it are then all reported on.
      text = "1,1-0\n" <> String.duplicate("nonsense\n", 5_000)

      assert {:error, errors} = ResultsImport.parse_text(text)

      # 50 problems plus the one line that says how many were left out.
      assert length(errors) == 51
      assert List.last(errors) =~ "and 4950 more"
    end

    test "but a handful of mistakes is still listed in full" do
      text = "1,1-0\nnonsense\n3,what\n"

      assert {:error, errors} = ResultsImport.parse_text(text)
      assert length(errors) == 2
      refute Enum.any?(errors, &(&1 =~ "more problem"))
    end
  end

  ## ---------- export envelope ----------

  defp tmp_file(content) do
    path =
      Path.join(
        System.tmp_dir!(),
        "import-bounds-#{System.unique_integer([:positive])}.json"
      )

    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "an export file larger than an export can be" do
    test "is refused before it is decoded" do
      # Not JSON, so `:unreadable` is the answer the decoder would give.
      # Getting `:too_large` instead is the proof that the size was checked
      # on disk and the file was never read, let alone decoded.
      path = tmp_file(String.duplicate("x", TournamentImport.max_bytes() + 1))

      assert {:error, :too_large} = TournamentImport.decode_file(path)
    end

    test "while the same content under the limit is read and reported as unreadable" do
      path = tmp_file(String.duplicate("x", 1_000))

      assert {:error, :unreadable} = TournamentImport.decode_file(path)
    end

    test "and a real envelope decodes" do
      path = tmp_file(~s({"format":"openpairings-export","version":1,"tournaments":[]}))

      assert {:ok, %{"format" => "openpairings-export"}} = TournamentImport.decode_file(path)
    end
  end
end
