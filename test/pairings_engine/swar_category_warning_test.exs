defmodule PairingsEngine.SwarCategoryWarningTest do
  @moduledoc """
  SWAR's `[CATEGORIES]` block carries two value lists and this import can
  read one of them.

  `map_categories/1` flattens `value1 ++ value2` into the tournament's
  category list; `category_name/2` resolves a player's `CatIndex` against
  `value1` alone, because the manual (§10.2) defines the index as a slot in
  that list. A file with a non-empty `value2` therefore imports categories no
  player can be in, at positions that match no index.

  What `value2` means is not settled and cannot be settled here - all three
  `.swar` fixtures carry `type = 0`, the "no categories" case. So the arbiter
  is told, rather than left to notice that a category has nobody in it.

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

  defp warnings(categories), do: PairingsEngine.SwarImport.category_warnings(categories)

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
end
