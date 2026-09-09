defmodule PairingsEngine.Federations.BEL.SwarCategoryWarningTest do
  @moduledoc """
  SWAR's `[CATEGORIES]` block carries two value lists and this import can
  read one of them.

  `map_categories/1` flattens `value1 ++ value2` into the tournament's
  category list; `category_name/2` resolves a player's `CatIndex` against
  `value1` alone, because the manual (§10.2) defines the index as a slot in
  that list. A file with a non-empty `value2` therefore imports categories no
  player can be in, at positions that match no index.

  `value2` was settled on 2026-09-09 from SWAR's own source: it is the second
  axis, and for all four category types both lists hold numeric bounds rather
  than names. The warning stays anyway, because knowing what it is does not
  make this app able to hold it - SWAR renders the two axes as one label and
  a player here carries a name. So the arbiter is still told, rather than
  left to notice that a category has nobody in it.

  `category_name/2` is tested here too, for the same reason and through the
  same seam: the index it resolves is one-based in SWAR and was read as
  zero-based here.

  Tested against `category_warnings/1` directly, because the alternative is a
  binary fixture nobody has: the parse is not what is under test, the
  decision about what to warn is.
  """
  use ExUnit.Case, async: true

  # The parser pads both lists to `max_categ + 1` blank strings, so a real
  # block is mostly empty - the warning has to survive that rather than fire
  # on the padding.
  defp block(type, value1, value2) do
    pad = fn list -> list ++ List.duplicate("", 17 - length(list)) end
    %{type: type, value1: pad.(value1), value2: pad.(value2)}
  end

  defp warnings(categories),
    do: PairingsEngine.Federations.BEL.SwarImport.category_warnings(categories)

  describe "a file that defines no categories" do
    test "says nothing, whatever padding it carries" do
      assert warnings(block(0, [], [])) == []
      assert warnings(block(0, ["Senior"], ["1800"])) == []
    end
  end

  describe "a file whose second value list is empty" do
    test "says nothing - the whole block is readable" do
      assert warnings(block(1, ["A", "B"], [])) == []
    end
  end

  describe "a file that carries a second list" do
    test "warns, naming both sets so the arbiter can see the mismatch" do
      assert [message] = warnings(block(1, ["A", "B"], ["1800", "1600"]))

      assert message =~ "second set of values"
      assert message =~ "1800, 1600"
      assert message =~ "A, B"
    end

    test "says what happened to them rather than only that something did" do
      [message] = warnings(block(2, ["Junior"], ["U16"]))

      # The two facts an arbiter needs: they are in the list, and nobody is
      # in them.
      assert message =~ "added to the tournament's category list"
      assert message =~ "no player is assigned to them"
      assert message =~ "Settings"
    end
  end

  describe "a file with no category block at all" do
    test "says nothing rather than raising" do
      assert warnings(%{}) == []
      assert warnings(%{type: 3}) == []
    end
  end

  describe "resolving a player's CatIndex" do
    # SWAR stores the first-axis slot as `(slot + 1) * 100` - `Categories.cpp`
    # line 737, over a zero-based `i`. So slot 0 arrives as 100. This read it
    # as `div(index, 100)`, which is `slot + 1`: every player came in one
    # category too strong and the last category never got anybody.
    defp name(index, value1),
      do: PairingsEngine.Federations.BEL.SwarImport.category_name(index, block(1, value1, []))

    test "the first category is the one stored as 100" do
      assert name(100, ["Senior", "Junior", "Cadet"]) == "Senior"
    end

    test "and the rest follow it, including the last" do
      list = ["Senior", "Junior", "Cadet"]

      assert name(200, list) == "Junior"
      assert name(300, list) == "Cadet"
    end

    test "no category at all stays blank" do
      assert name(0, ["Senior"]) == ""
    end

    test "an index past the list is blank rather than a crash" do
      # A file naming fewer categories than a player's index claims is
      # corrupt, not something to guess at.
      assert name(900, ["Senior"]) == ""
    end

    test "a second-axis component on its own resolves to nothing" do
      # The units place is the OTHER axis (`i + 1`, no hundreds). It indexes
      # `value2`, which this app does not model, so there is no first-axis
      # answer to give - and answering with `value1`'s first entry would be
      # inventing one.
      assert name(3, ["Senior", "Junior"]) == ""
    end
  end
end
