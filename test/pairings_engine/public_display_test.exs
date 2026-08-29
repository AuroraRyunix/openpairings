defmodule PairingsEngine.PublicDisplayTest do
  @moduledoc """
  What a published tournament may show.

  Every test here is about one rule - absent means shown - because that rule
  is what makes the feature safe to add keys to, safe to publish from an old
  app to a new server, and safe to turn on for tournaments that predate it.
  Get it backwards and columns vanish from pages nobody touched.
  """
  use ExUnit.Case, async: true

  alias PairingsEngine.PublicDisplay

  describe "show?/2" do
    test "a tournament that predates the feature shows everything" do
      for key <- PublicDisplay.keys(), do: assert(PublicDisplay.show?(nil, key))
    end

    test "only an explicit false hides a column" do
      refute PublicDisplay.show?(%{"club" => false}, "club")
      assert PublicDisplay.show?(%{"club" => true}, "club")
      assert PublicDisplay.show?(%{}, "club")
    end

    test "a key the map has never heard of is shown" do
      # The case that matters when a key is added later: every tournament
      # already in the database is silent about it, and a new column must not
      # arrive switched off on all of them.
      assert PublicDisplay.show?(%{"club" => false}, "something_added_in_2027")
    end

    test "junk in the column does not blank the page" do
      # `:map` is not a schema. A hand-edited row, a restore from a mangled
      # backup - the answer is still "show it", because the alternative is a
      # page that silently loses columns and gives no reason.
      assert PublicDisplay.show?("not a map", "club")
      assert PublicDisplay.show?(%{"club" => "false"}, "club")
    end
  end

  describe "cast/1" do
    test "an unticked box is off, an absent one too" do
      cast = PublicDisplay.cast(%{"rating" => "true"})

      assert cast["club"] == false
      refute Map.has_key?(cast, "rating")
    end

    test "records only the negatives" do
      cast = PublicDisplay.cast(Map.new(PublicDisplay.keys(), &{&1, "true"}))

      assert cast == %{}
    end

    test "accepts every shape a checkbox actually arrives in" do
      for truthy <- ["true", "on", "1", true] do
        refute Map.has_key?(PublicDisplay.cast(%{"club" => truthy}), "club")
      end
    end
  end

  describe "resolve/1" do
    test "is total - every key, every value a real boolean" do
      for stored <- [nil, %{}, %{"club" => false}] do
        resolved = PublicDisplay.resolve(stored)

        assert Enum.sort(Map.keys(resolved)) == Enum.sort(PublicDisplay.keys())
        assert Enum.all?(Map.values(resolved), &is_boolean/1)
      end
    end

    test "a reader needs no knowledge of this module's defaults" do
      # The whole reason the snapshot carries the resolved map rather than the
      # sparse one: `%{"club" => false}` alone would require the other side to
      # know the six keys it does not mention.
      assert PublicDisplay.resolve(%{"club" => false}) == %{
               "rating" => true,
               "title" => true,
               "federation" => true,
               "club" => false,
               "category" => true,
               "tiebreaks" => true,
               "player_cards" => true
             }
    end
  end

  describe "fields/0" do
    test "every field has a key, a label and a hint" do
      for field <- PublicDisplay.fields() do
        assert is_binary(field.key) and field.key != ""
        assert is_binary(field.label) and field.label != ""
        assert is_binary(field.hint) and field.hint != ""
      end
    end

    test "keys are unique, and are what travels" do
      keys = PublicDisplay.keys()
      assert length(Enum.uniq(keys)) == length(keys)
    end

    test "nothing structural is offered as hideable" do
      # Names, boards, results and placings are the tournament. A page
      # without them is not a page, and an arbiter who does not want them
      # public should not publish.
      for forbidden <- ~w(name result board rank points standings pairings) do
        refute forbidden in PublicDisplay.keys()
      end
    end
  end
end
