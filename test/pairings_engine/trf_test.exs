defmodule PairingsEngine.TrfTest do
  use ExUnit.Case, async: true

  alias PairingsEngine.Trf

  # Column numbers are 1-indexed inclusive, straight from the FIDE spec.
  defp col(line, start, stop), do: String.slice(line, start - 1, stop - start + 1)

  defp sample do
    %{
      tournament: %{
        name: "Test Open 2026",
        city: "Ghent",
        federation: "BEL",
        start_date: "2026-07-01",
        end_date: "2026-07-05",
        type: "swiss",
        chief_arbiter: "Jorian Burssens",
        deputy_arbiters: ["Assistant One"],
        time_control: "90+30",
        round_dates: ["2026-07-01", "2026-07-02", "2026-07-03"]
      },
      players: [
        %{
          rank: 1,
          sex: "m",
          title: "GM",
          name: "Carlsen, Magnus",
          fide_rating: 2823,
          federation: "NOR",
          fide_number: 1_503_014,
          birth_date: "1990-11-30",
          points: 2.5,
          games: [
            %{opponent_rank: 2, colour: "w", result: "1"},
            %{opponent_rank: 3, colour: "b", result: "="},
            %{opponent_rank: nil, colour: nil, result: "U"}
          ]
        },
        %{
          rank: 2,
          sex: "w",
          title: "",
          name: "Vandekerckhove, Ava",
          fide_rating: 1674,
          federation: "BEL",
          fide_number: 207_918,
          birth_date: "1990-01-01",
          points: 0.0,
          games: [
            %{opponent_rank: 1, colour: "b", result: "0"},
            %{opponent_rank: 3, colour: "w", result: "0"},
            %{opponent_rank: 2, colour: nil, result: "Z"}
          ]
        }
      ]
    }
  end

  test "header lines use the code + free-text layout" do
    lines = sample() |> Trf.serialize() |> String.split("\r\n")

    assert Enum.at(lines, 0) == "012 Test Open 2026"
    assert Enum.at(lines, 1) == "022 Ghent"
    assert Enum.at(lines, 2) == "032 BEL"
    assert Enum.at(lines, 3) == "042 2026/07/01"
    assert Enum.at(lines, 4) == "052 2026/07/05"
  end

  test "player line matches the exact FIDE TRF16 column positions" do
    line =
      sample()
      |> Trf.serialize()
      |> String.split("\r\n")
      |> Enum.find(&(String.starts_with?(&1, "001") and &1 =~ "Carlsen"))

    assert col(line, 1, 3) == "001"
    assert col(line, 5, 8) |> String.trim() == "1"
    assert col(line, 10, 10) == "m"
    assert col(line, 11, 13) |> String.trim() == "GM"
    assert col(line, 15, 47) |> String.trim() == "Carlsen, Magnus"
    assert col(line, 49, 52) |> String.trim() == "2823"
    assert col(line, 54, 56) == "NOR"
    assert col(line, 58, 68) |> String.trim() == "1503014"
    assert col(line, 70, 79) == "1990/11/30"
    assert col(line, 81, 84) == " 2.5"
    assert col(line, 86, 89) |> String.trim() == "1"

    # Round 1: opponent 2, colour w, result 1 (win)
    assert col(line, 92, 95) |> String.trim() == "2"
    assert col(line, 97, 97) == "w"
    assert col(line, 99, 99) == "1"

    # Round 2: opponent 3, colour b, result = (draw)
    assert col(line, 102, 105) |> String.trim() == "3"
    assert col(line, 107, 107) == "b"
    assert col(line, 109, 109) == "="

    # Round 3: pairing-allocated bye -> opponent 0000, colour '-', result U
    assert col(line, 112, 115) == "0000"
    assert col(line, 117, 117) == "-"
    assert col(line, 119, 119) == "U"
  end

  test "a control character in a name can't split or inject a TRF line" do
    # A player name has no format check beyond length, so it can carry a
    # newline/CR/tab. TRF is line- and column-oriented and this text is written
    # to the JaVaFo pairing-input file, so an unstripped newline would break
    # the row into two — corrupting the parse or injecting a line.
    data = put_in(sample(), [:players, Access.at(0), :name], "Ev\r\nil\t001 injected")

    lines = Trf.serialize(data) |> String.split("\r\n")
    player_lines = Enum.filter(lines, &String.starts_with?(&1, "001"))

    # Still exactly one 001 line per player (2 in the sample), none injected.
    assert length(player_lines) == 2

    carlsen_replacement = Enum.find(player_lines, &(&1 =~ "Ev"))
    refute carlsen_replacement =~ "\n"
    refute carlsen_replacement =~ "\t"
    # The controls became spaces, so the name field stays inside its columns.
    assert col(carlsen_replacement, 15, 47) |> String.trim() =~ ~r/^Ev  il 001 injected$/
  end

  test "082 (number of teams) is always emitted, even 0 for an individual tournament" do
    lines = sample() |> Trf.serialize() |> String.split("\r\n")
    assert Enum.any?(lines, &(&1 == "082 0"))
  end

  test "082 reflects the real team count when teams are present" do
    data =
      sample()
      |> Map.put(:teams, [%{name: "A", player_ranks: [1]}, %{name: "B", player_ranks: [2]}])

    lines = Trf.serialize(data) |> String.split("\r\n")
    assert Enum.any?(lines, &(&1 == "082 2"))
  end

  test "132 (round dates) is omitted when every round in the list is blank/nil" do
    data = put_in(sample(), [:tournament, :round_dates], [nil, "", nil])
    lines = Trf.serialize(data) |> String.split("\r\n")
    refute Enum.any?(lines, &String.starts_with?(&1, "132"))
  end

  test "132 (round dates) is still emitted, with blanks for missing rounds, when at least one date is set" do
    data = put_in(sample(), [:tournament, :round_dates], [nil, "2026-07-02", nil])

    line =
      Trf.serialize(data) |> String.split("\r\n") |> Enum.find(&String.starts_with?(&1, "132"))

    assert col(line, 92, 99) == "        "
    assert col(line, 102, 109) == "26/07/02"
  end

  test "round-dates (132) line places YY/MM/DD at the round-block columns" do
    line =
      sample()
      |> Trf.serialize()
      |> String.split("\r\n")
      |> Enum.find(&String.starts_with?(&1, "132"))

    assert col(line, 92, 99) == "26/07/01"
    assert col(line, 102, 109) == "26/07/02"
    assert col(line, 112, 119) == "26/07/03"
  end

  test "parse/1 is the inverse of serialize/1 for header + player data" do
    parsed = sample() |> Trf.serialize() |> Trf.parse()

    assert parsed.tournament[:name] == "Test Open 2026"
    assert parsed.tournament[:city] == "Ghent"
    assert parsed.tournament[:federation] == "BEL"
    assert parsed.tournament[:start_date] == "2026-07-01"
    assert parsed.tournament[:end_date] == "2026-07-05"
    assert parsed.tournament.deputy_arbiters == ["Assistant One"]
    assert parsed.tournament[:time_control] == "90+30"
    assert parsed.tournament[:round_dates] == ["2026-07-01", "2026-07-02", "2026-07-03"]

    assert length(parsed.players) == 2
    [magnus | _] = parsed.players
    assert magnus.rank == 1
    assert magnus.sex == "m"
    assert magnus.title == "GM"
    assert magnus.name == "Carlsen, Magnus"
    assert magnus.fide_rating == 2823
    assert magnus.federation == "NOR"
    assert magnus.fide_number == 1_503_014
    assert magnus.birth_date == "1990-11-30"
    assert magnus.points == 2.5

    assert magnus.games == [
             %{opponent_rank: 2, colour: "w", result: "1"},
             %{opponent_rank: 3, colour: "b", result: "="},
             %{opponent_rank: nil, colour: nil, result: "U"}
           ]
  end

  test "teams are serialized and parsed with correct player-slot columns" do
    data = sample() |> Map.put(:teams, [%{name: "KGSRL Gent", player_ranks: [1, 2]}])
    trf = Trf.serialize(data)
    line = trf |> String.split("\r\n") |> Enum.find(&String.starts_with?(&1, "013"))

    assert col(line, 1, 3) == "013"
    assert col(line, 5, 36) |> String.trim() == "KGSRL Gent"
    assert col(line, 37, 40) |> String.trim() == "1"
    assert col(line, 42, 45) |> String.trim() == "2"

    parsed = Trf.parse(trf)
    assert parsed.teams == [%{name: "KGSRL Gent", player_ranks: [1, 2]}]
  end

  test "a name longer than 33 characters is truncated, not overflowed into the rating field" do
    data = %{
      tournament: %{name: "T"},
      players: [%{rank: 1, name: String.duplicate("A", 50), points: 0.0, games: []}]
    }

    line =
      data
      |> Trf.serialize()
      |> String.split("\r\n")
      |> Enum.find(&String.starts_with?(&1, "001"))

    assert col(line, 15, 47) == String.duplicate("A", 33)
    assert col(line, 48, 48) == " "
  end

  ## ---------- result validation ----------

  # Two players paired against each other for round 1, with the given TRF
  # result codes on each side.
  defp two_player_round(result_a, result_b) do
    %{
      tournament: %{name: "T"},
      players: [
        %{
          rank: 1,
          name: "A",
          points: 0.0,
          games: [%{opponent_rank: 2, colour: "w", result: result_a}]
        },
        %{
          rank: 2,
          name: "B",
          points: 0.0,
          games: [%{opponent_rank: 1, colour: "b", result: result_b}]
        }
      ]
    }
  end

  defp set_char(line, col, char) do
    {a, rest} = String.split_at(line, col - 1)
    <<_::binary-size(1), b::binary>> = rest
    a <> char <> b
  end

  test "serialize/1 raises when both players claim a win" do
    assert_raise Trf.ValidationError, ~r/illegal result combination/, fn ->
      two_player_round("1", "1") |> Trf.serialize()
    end
  end

  test "serialize/1 raises when both players are marked forfeit-win" do
    assert_raise Trf.ValidationError, ~r/illegal result combination/, fn ->
      two_player_round("+", "+") |> Trf.serialize()
    end
  end

  test "serialize/1 raises when a played result is paired with a mismatched score (win vs draw)" do
    assert_raise Trf.ValidationError, ~r/illegal result combination/, fn ->
      two_player_round("1", "=") |> Trf.serialize()
    end
  end

  test "serialize/1 raises on a result code that isn't in the TRF16 spec" do
    assert_raise Trf.ValidationError, ~r/unrecognized TRF result code/, fn ->
      two_player_round("X", "0") |> Trf.serialize()
    end
  end

  test "serialize/1 accepts a played 0-0 (both players score a loss, code '0' for both)" do
    trf = two_player_round("0", "0") |> Trf.serialize()
    assert trf =~ "001"
  end

  test "serialize/1 accepts a double forfeit ('-' for both sides)" do
    trf = two_player_round("-", "-") |> Trf.serialize()
    assert trf =~ "001"
  end

  test "serialize/1 accepts a single forfeit ('+' vs '-')" do
    trf = two_player_round("+", "-") |> Trf.serialize()
    assert trf =~ "001"
  end

  test "serialize/1 does not flag a dangling/unresolvable opponent reference as illegal" do
    # Round 1's opponent (rank 2) doesn't exist in this single-player roster —
    # that's a caller concern (e.g. a partial player card), not a result
    # validation error.
    data = %{
      tournament: %{name: "T"},
      players: [
        %{rank: 1, name: "A", points: 0.0, games: [%{opponent_rank: 2, colour: "w", result: "1"}]}
      ]
    }

    assert Trf.serialize(data) =~ "001"
  end

  test "parse/1 also raises on an illegal result combination" do
    text = two_player_round("1", "0") |> Trf.serialize()
    lines = String.split(text, "\r\n")
    p2 = Enum.find(lines, &(String.starts_with?(&1, "001") and &1 =~ "B"))

    # Round 1's result column is 99 (base 92 + 7) — see round_cols/1. Flip
    # player B's loss into a second win, making the round illegal.
    bad_p2 = set_char(p2, 99, "1")
    bad_text = lines |> Enum.map(&if &1 == p2, do: bad_p2, else: &1) |> Enum.join("\r\n")

    assert_raise Trf.ValidationError, ~r/illegal result combination/, fn ->
      Trf.parse(bad_text)
    end
  end

  test "serialize/1 raises when opponent 0000 carries a played-game result code" do
    data = %{
      tournament: %{name: "T"},
      players: [
        %{
          rank: 1,
          name: "A",
          points: 1.0,
          games: [%{opponent_rank: nil, colour: nil, result: "1"}]
        }
      ]
    }

    assert_raise Trf.ValidationError, ~r/opponent 0000 cannot carry played-game result/, fn ->
      Trf.serialize(data)
    end
  end

  test "serialize/1 accepts a legitimate bye code (F/H/Z/U) with no opponent" do
    for code <- ["F", "H", "Z", "U"] do
      data = %{
        tournament: %{name: "T"},
        players: [
          %{
            rank: 1,
            name: "A",
            points: 1.0,
            games: [%{opponent_rank: nil, colour: nil, result: code}]
          }
        ]
      }

      assert Trf.serialize(data) =~ "001"
    end
  end

  test "parse/1 succeeds on a legal round-trip" do
    text = two_player_round("+", "-") |> Trf.serialize()
    parsed = Trf.parse(text)
    [a, b] = parsed.players
    assert a.games == [%{opponent_rank: 2, colour: "w", result: "+"}]
    assert b.games == [%{opponent_rank: 1, colour: "b", result: "-"}]
  end
end
