defmodule PairingsEngine.ResultsTest do
  use ExUnit.Case, async: true

  alias PairingsEngine.Results
  alias PairingsEngine.Standings
  alias PairingsEngine.Tournaments.Pairing

  describe "codes/0 and entry_codes/0" do
    test "the schema validates against this list" do
      assert Pairing.results() == Results.codes()
    end

    test "entry codes are every real result plus the blank that clears one" do
      assert "1-0" in Results.entry_codes()
      assert "1/2-1/2U" in Results.entry_codes()
      assert "" in Results.entry_codes()
    end

    test "the engine's bye and the legacy forfeit notation are storable but not offerable" do
      for code <- ["bye", "+--", "--+"] do
        assert code in Results.codes()
        refute code in Results.entry_codes()
      end
    end
  end

  describe "classify/1" do
    test "the asymmetric disciplinary codes differ by seat" do
      assert {:draw, :loss, true, false} = Results.classify("1/2-0")
      assert {:loss, :draw, true, false} = Results.classify("0-1/2")
    end

    test "a forfeit is unplayed for both sides, including the one awarded the point" do
      assert {:win, :loss, false, true} = Results.classify("1-0FF")
      assert {:loss, :loss, false, true} = Results.classify("0-0FF")
    end

    test "\"0-0\" is a played game both players lose, unlike \"0-0FF\"" do
      assert {:loss, :loss, true, false} = Results.classify("0-0")
    end

    test "unrated twins classify exactly like their rated originals" do
      for {rated, unrated} <- [{"1-0", "1-0U"}, {"0-1", "0-1U"}, {"1/2-1/2", "1/2-1/2U"}] do
        assert Results.classify(rated) == Results.classify(unrated)
      end
    end

    test "the blank, the bye and anything unknown have no outcome" do
      for code <- ["", "bye", "nonsense"] do
        assert {:none, :none, false, false} = Results.classify(code)
      end
    end
  end

  describe "outcome/2" do
    test "reads the seat asked for" do
      assert Results.outcome("1-0", true) == :win
      assert Results.outcome("1-0", false) == :loss
      assert Results.outcome("1/2-0", true) == :draw
      assert Results.outcome("1/2-0", false) == :loss
    end
  end

  describe "played?/1" do
    test "agrees with Standings.played_result?/1, which now delegates here" do
      for code <- Results.codes() do
        assert Results.played?(code) == Standings.played_result?(code)
      end
    end

    test "the nine contested codes, and only those" do
      played = Enum.filter(Results.codes(), &Results.played?/1)

      assert Enum.sort(played) ==
               Enum.sort(~w(1-0 1/2-1/2 0-1 1/2-0 0-1/2 0-0 1-0U 0-1U 1/2-1/2U))
    end
  end

  describe "parse_token/1" do
    test "the three unrated codes are importable, which they were not" do
      assert Results.parse_token("1-0U") == {:ok, "1-0U"}
      assert Results.parse_token("0-1u") == {:ok, "0-1U"}
      assert Results.parse_token("1/2-1/2U") == {:ok, "1/2-1/2U"}
      assert Results.parse_token("½-½U") == {:ok, "1/2-1/2U"}
    end

    test "case and surrounding whitespace do not matter" do
      assert Results.parse_token("  1-0ff  ") == {:ok, "1-0FF"}
      assert Results.parse_token("x") == {:ok, "0-0"}
    end

    test "every token maps to a code the schema will accept" do
      for {code, _tokens} <- Results.token_groups() do
        assert code in Results.codes()
      end
    end

    test "unrecognised input is an error, not a guess" do
      assert Results.parse_token("1") == :error
      assert Results.parse_token("win") == :error
      assert Results.parse_token("") == :error
    end
  end
end
