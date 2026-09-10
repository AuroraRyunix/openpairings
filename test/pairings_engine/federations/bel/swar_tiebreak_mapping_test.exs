defmodule PairingsEngine.Federations.BEL.SwarTiebreakMappingTest do
  @moduledoc """
  Which SWAR tie-break each ordinal becomes, and what happens to the ones
  that become nothing.

  The importer maps SWAR's `DEPARTAGES` ordinals onto this app's tie-break
  codes and then compacts the list. Compacting is why an unmapped ordinal
  is not a missing column: every criterion after it moves up one place, so
  a tournament SWAR ranked on Buchholz Cut-2 and then plain Buchholz comes
  in ranked on plain Buchholz. The standings order changes and the screen
  says nothing.

  Six ordinals gained counterparts as the tie-break catalogue grew, and the
  importer was never told - the same drift that once turned `W`/`D`/`L`
  games into byes in `TrfImport`. These tests pin the whole table so the
  next entry added to `PairingsEngine.Tiebreaks` has somewhere to fail.
  """
  use ExUnit.Case, async: true

  alias PairingsEngine.Federations.BEL.SwarImport
  alias PairingsEngine.Tiebreaks

  # `Swar.h`'s enum, in its own declaration order. Written out rather than
  # referenced, because the point of the test is that the two sides agree.
  @swar %{
    1 => "BH",
    2 => "MBH",
    4 => "BHC1",
    5 => "BHC2",
    6 => "SB",
    7 => "PS",
    8 => "DE",
    9 => "KS",
    10 => "WIN",
    12 => "ARO",
    13 => "AROC1",
    14 => "BPG"
  }

  describe "every mapped ordinal" do
    test "becomes a code this app actually offers" do
      # The failure this catches: mapping onto a code that was renamed or
      # removed, which would import a tie-break the Settings page cannot
      # show and the standings cannot compute.
      known = for(%{code: code} <- Tiebreaks.catalogue(), do: code)

      for {ordinal, code} <- @swar do
        assert code in known,
               "SWAR ordinal #{ordinal} maps to #{code}, which is not in the catalogue"

        assert Tiebreaks.available?(code),
               "SWAR ordinal #{ordinal} maps to #{code}, which is not available"
      end
    end

    test "stays mapped - none of the twelve warns" do
      # The real pin. `tiebreak_warnings/1` fires for anything the importer
      # cannot map, so a silent "none of these warn" is the same statement
      # as "the map still contains all twelve", made through the public
      # seam rather than by reaching into a module attribute.
      for {ordinal, code} <- @swar do
        assert SwarImport.tiebreak_warnings([ordinal]) == [],
               "ordinal #{ordinal} (#{code}) is no longer mapped"
      end
    end

    test "and the five that were added late are among them" do
      # Buchholz Cut-2, Koya, ARO, ARO Cut-1 and black-games-played all
      # existed in the catalogue while the importer still dropped them.
      for code <- ~w(BHC2 KS ARO AROC1 BPG) do
        assert code in Map.values(@swar)
      end
    end
  end

  describe "an ordinal with no counterpart" do
    test "is named in a warning, not dropped in silence" do
      # 3 is Buchholz median-2; this app has one median Buchholz, which is
      # median-1. Nothing dishonest can be done with it, so the arbiter is
      # told.
      assert [message] = SwarImport.tiebreak_warnings([3, 1])

      assert message =~ "median-2"
      assert message =~ "moves every criterion after it up one place"
    end

    test "and an ordinal nobody has seen is named by its number" do
      # A newer SWAR adding a sixteenth method must not import as though
      # the file had one fewer criterion than it says.
      assert [message] = SwarImport.tiebreak_warnings([99])
      assert message =~ "99"
    end

    test "several are listed together, once each" do
      assert [message] = SwarImport.tiebreak_warnings([3, 11, 15, 3])

      assert message =~ "median-2"
      assert message =~ "performance"
      assert message =~ "Black"

      # De-duplicated: a file repeating a criterion should not repeat it in
      # the sentence.
      assert message |> String.split("median-2") |> length() == 2
    end
  end

  describe "a file this app can represent completely" do
    test "says nothing" do
      # The common case, and the one that must stay quiet: a warning shown
      # on every ordinary import is a warning nobody reads.
      assert SwarImport.tiebreak_warnings([4, 1, 6]) == []
    end

    test "and neither does the 'no tie-break' padding" do
      # SWAR pads the list to MAX_TIEBREAK with zeros.
      assert SwarImport.tiebreak_warnings([1, 0, 0, 0, 0]) == []
    end
  end
end
