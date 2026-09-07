defmodule PairingsEngine.RateOfPlayTest do
  use ExUnit.Case, async: true

  alias Ainalrami.Trf
  alias PairingsEngine.RateOfPlay

  describe "trf26_code/1" do
    test "encodes the catalogue's wordings as TRF26's 222 line" do
      for {text, code} <- [
            {"90min/40moves+30min/end+30sec/move from move 1", "40/5400+30:1800+30"},
            {"100min/40moves+50min/20moves+15min/end+30sec/move from move 1",
             "40/6000+30:20/3000+30:900+30"},
            {"105min/40moves+15min/end", "40/6300:900"},
            {"150min/end", "9000"},
            {"5min/end+2sec/move from move 1", "300+2"},
            # "From move 40" is this catalogue's wording for "after the
            # first time control": the increment belongs to the period that
            # starts at move 41.
            {"120min/40moves+15min/end+30sec/move from move 40", "40/7200:900+30"}
          ] do
        assert RateOfPlay.trf26_code(text) == code, text
        assert Trf.encoded_time_control?(code), code
      end
    end

    test "leaves out what the grammar cannot say" do
      for text <- [
            nil,
            "",
            "90+30",
            "90min/end+30sec DELAY /move from move 1",
            "120min/end+10sec/move from move 40",
            "120min/10moves+30min/end+30sec/move from move 40",
            "90min/40moves"
          ] do
        assert RateOfPlay.trf26_code(text) == nil, inspect(text)
      end
    end

    test "every catalogue entry encodes to something the grammar accepts, or is left out" do
      for standard <- ~w(standard rapid blitz), text <- RateOfPlay.list_for(standard) do
        case RateOfPlay.trf26_code(text) do
          nil -> :ok
          code -> assert Trf.encoded_time_control?(code), "#{text} -> #{code}"
        end
      end
    end
  end
end
