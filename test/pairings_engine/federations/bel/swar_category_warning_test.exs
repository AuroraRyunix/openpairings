defmodule PairingsEngine.Federations.BEL.SwarCategoryWarningTest do
  @moduledoc """
  SWAR's `[CATEGORIES]` block carries two value lists, `value1`/`value2`.
  Settled 2026-09-09 from SWAR's own source
  (`docs/swar-source-audit-2026-09-09.md`): for `Categorie` type 3
  (age-then-rating) and 4 (rating-then-age) both lists are real, independent
  axes of numeric bounds; for every other type (0 = none, 1 = rating alone,
  2 = age alone, 5 = free text) `value2` is blank padding.

  A player carries a SET of category tags
  (`PairingsEngine.Categories` moduledoc), so a two-axis import tags a
  player with BOTH axes' names - `category_axes/2` decodes a `CatIndex`
  into `{axis1, axis2}`, and `map_categories/1`/`player_attrs/2` (exercised
  indirectly here through the same seam) use both. This app can now
  represent everything SWAR's category block carries, so
  `category_warnings/1` only fires on a genuinely unrecognised type - it no
  longer warns about a populated `value2`.

  Tested against `category_warnings/1` and `category_axes/2` directly,
  because the alternative is a binary fixture nobody has: the parse is not
  what is under test, the decode is.
  """
  use ExUnit.Case, async: true

  # The parser pads both lists to `max_categ + 1` blank strings, so a real
  # block is mostly empty - the tests have to survive that rather than
  # accidentally exercise the padding.
  defp block(type, value1, value2) do
    pad = fn list -> list ++ List.duplicate("", 17 - length(list)) end
    %{type: type, value1: pad.(value1), value2: pad.(value2)}
  end

  defp warnings(categories),
    do: PairingsEngine.Federations.BEL.SwarImport.category_warnings(categories)

  defp axes(index, categories),
    do: PairingsEngine.Federations.BEL.SwarImport.category_axes(index, categories)

  defp name(index, value1),
    do: PairingsEngine.Federations.BEL.SwarImport.category_name(index, block(1, value1, []))

  describe "a file that defines no categories" do
    test "says nothing, whatever padding it carries" do
      assert warnings(block(0, [], [])) == []
      assert warnings(block(0, ["Senior"], ["1800"])) == []
    end
  end

  describe "a single-axis file (types 1, 2, 5)" do
    test "says nothing, value2 stays unread padding" do
      assert warnings(block(1, ["A", "B"], [])) == []
      assert warnings(block(1, ["A", "B"], ["1800", "1600"])) == []
      assert warnings(block(2, ["Junior"], ["U16"])) == []
      assert warnings(block(5, ["Open"], [])) == []
    end
  end

  describe "a two-axis file (types 3, 4)" do
    test "says nothing - both axes are read" do
      assert warnings(block(3, ["-14", "-18"], ["-1800", "-2000"])) == []
      assert warnings(block(4, ["-1800", "-2000"], ["-14", "-18"])) == []
    end
  end

  describe "an unrecognised type" do
    test "warns, and still doesn't raise" do
      assert [message] = warnings(block(9, ["A"], ["B"]))
      assert message =~ "unrecognised type"
    end
  end

  describe "a file with no category block at all" do
    test "says nothing rather than raising" do
      assert warnings(%{}) == []
      assert warnings(%{type: 3}) == []
    end
  end

  describe "resolving a player's CatIndex - single axis" do
    # SWAR stores the first-axis slot as `(slot + 1) * 100` - `Categories.cpp`
    # line 737, over a zero-based `i`. So slot 0 arrives as 100. This read it
    # as `div(index, 100)`, which is `slot + 1`: every player came in one
    # category too strong and the last category never got anybody. Fixed in
    # 0.53.0.
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

    test "a second-axis-only component resolves axis 1 to nothing" do
      # The units place is axis 2. A single-axis file's `value2` is blank
      # padding, so slot 2 of it resolves to "" - and so does axis 1, since
      # there is no hundreds component here at all.
      assert name(3, ["Senior", "Junior"]) == ""
    end

    # `TournoiReadWrite.cpp:623-624` normalises any stored `CatIndex` under
    # 100 by multiplying it by 100, unconditionally - not only for files old
    # enough to still use the un-scaled encoding.
    test "a legacy file's un-scaled index still resolves, once value1 has enough slots" do
      list = ["Senior", "Junior", "Cadet"]

      assert name(2, list) == "Junior"
      assert name(2, list) == name(200, list)
    end
  end

  describe "resolving a player's CatIndex - two axes" do
    # `Categories.cpp:737`: `CatIndex += (value == 1 ? (i + 1) * 100 : i + 1)`
    # - axis 1 in the hundreds, axis 2 in the units, each one-based over a
    # zero-based slot `i`. Age-then-rating (type 3): axis 1 is age, axis 2
    # is rating. Rating-then-age (type 4): the reverse. `category_axes/2`
    # doesn't need the type to decode - `value1` is always axis 1,
    # `value2` always axis 2.
    setup do
      categories = block(3, ["-14", "-18", "+18"], ["-1600", "-2000", "+2000"])
      %{categories: categories}
    end

    test "both axes resolve from one packed index", %{categories: categories} do
      # Age slot 0 ("-14"), rating slot 1 ("-2000"): (0+1)*100 + (1+1) = 102.
      assert axes(102, categories) == {"-14", "-2000"}
    end

    test "the last slot of each axis, together", %{categories: categories} do
      # (2+1)*100 + (2+1) = 303.
      assert axes(303, categories) == {"+18", "+2000"}
    end

    test "axis 1 alone when the units are 0 (no axis-2 slot)", %{categories: categories} do
      assert axes(200, categories) == {"-18", ""}
    end

    test "zero is no category on either axis", %{categories: categories} do
      assert axes(0, categories) == {"", ""}
    end

    test "category_name/2 still answers axis 1 alone", %{categories: categories} do
      assert PairingsEngine.Federations.BEL.SwarImport.category_name(102, categories) == "-14"
    end

    test "an edge bound at either end of each axis resolves cleanly" do
      categories = block(4, ["-2000"], ["-14"])
      # Rating-then-age, one bound each: (0+1)*100 + (0+1) = 101.
      assert axes(101, categories) == {"-2000", "-14"}
    end
  end
end
