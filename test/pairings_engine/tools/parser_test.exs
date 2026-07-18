defmodule PairingsEngine.Tools.ParserTest do
  # async: true — Parser is pure (dispatches to the pure build_structs/1
  # builders), no database, no filesystem.
  use ExUnit.Case, async: true

  alias PairingsEngine.{Tools.Parser, Trf}
  alias PairingsEngine.Tournaments.{Tournament, Player}

  defp trf_text do
    Trf.serialize(%{
      tournament: %{
        name: "Parser Test Open",
        city: "Ghent",
        federation: "BEL",
        start_date: "2026-01-01",
        end_date: "2026-01-02",
        type: "swiss"
      },
      players: [
        %{
          rank: 1,
          name: "Alice",
          fide_rating: 2000,
          fide_number: 111,
          points: 1.0,
          games: [%{opponent_rank: 2, colour: "w", result: "1"}]
        },
        %{
          rank: 2,
          name: "Bob",
          fide_rating: 1900,
          fide_number: 222,
          points: 0.0,
          games: [%{opponent_rank: 1, colour: "b", result: "0"}]
        }
      ]
    })
  end

  test "a .trf file goes to the TRF builder" do
    assert {:ok, {%Tournament{} = t, [%Player{}, %Player{}] = players}} =
             Parser.parse("report.trf", trf_text())

    assert t.name == "Parser Test Open"
    assert Enum.map(players, & &1.name) == ["Alice", "Bob"]
  end

  test "extension matching is case-insensitive" do
    assert {:ok, {%Tournament{}, _players}} = Parser.parse("REPORT.TRF", trf_text())
  end

  test "an unknown extension falls back to trying SWAR then TRF" do
    assert {:ok, {%Tournament{name: "Parser Test Open"}, _players}} =
             Parser.parse("renamed.txt", trf_text())
  end

  test "a .trf file with garbage content fails with the TRF-specific message" do
    assert {:error, message} = Parser.parse("garbage.trf", "this is not a TRF file")
    assert message =~ "TRF"
  end

  test "a .swar file with garbage content fails with the SWAR-specific message" do
    assert {:error, message} = Parser.parse("garbage.swar", "this is not a SWAR file")
    assert message =~ "SWAR"
  end

  test "an unknown extension where both parsers fail names both formats" do
    assert {:error, message} = Parser.parse("garbage.bin", "neither format at all")
    assert message =~ "either SWAR or TRF"
  end
end
