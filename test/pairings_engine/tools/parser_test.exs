defmodule PairingsEngine.Tools.ParserTest do
  # async: true - Parser is pure (dispatches to the pure build_structs/1
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

  # A `.swar` opens with its version string, length-prefixed - all
  # `detect_format/2` reads, so the trailing bytes can be anything.
  defp swar_bytes(version \\ "v7.04"),
    do: <<byte_size(version)::little-signed-32, version::binary, 0, 1, 2, 3>>

  describe "detect_format/2 - content decides, extension only breaks ties" do
    test "SWAR content wins over a .trf filename" do
      assert Parser.detect_format("misnamed.trf", swar_bytes()) == :swar
      assert Parser.detect_format("misnamed.trf", swar_bytes("v6.78")) == :swar
    end

    test "TRF content wins over a .swar filename" do
      assert Parser.detect_format("misnamed.swar", trf_text()) == :trf
    end

    test "the extension decides only when the bytes say nothing" do
      assert Parser.detect_format("mystery.swar", "not either format") == :swar
      assert Parser.detect_format("mystery.trf", "not either format") == :trf
      assert Parser.detect_format("mystery.bin", "not either format") == :unknown
    end

    test "text that merely mentions 001 isn't mistaken for TRF" do
      assert Parser.detect_format("notes.bin", "call 001 for the arbiter") == :unknown
    end
  end

  # The whole point of sniffing: a `.swar` handed to the TRF path must not
  # come back with TRF's "no 001 lines" complaint, which is true and useless.
  test "a SWAR file named .trf is routed to the SWAR parser" do
    assert {:error, message} = Parser.parse("misnamed.trf", swar_bytes())
    assert message =~ "SWAR"
    refute message =~ "001"
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
