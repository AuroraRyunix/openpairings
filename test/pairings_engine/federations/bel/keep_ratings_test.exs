defmodule PairingsEngine.Federations.BEL.KeepRatingsTest do
  use PairingsEngine.DataCase, async: true

  alias PairingsEngine.Federations.BEL.{Member, Sync}

  defp seed! do
    Repo.insert_all(Member, [
      %{national_id: "12345", last_name: "Peeters", first_name: "Jan", national_rating: 1850},
      %{national_id: "67890", last_name: "Dubois", first_name: "Marie", national_rating: 2010}
    ])
  end

  defp row(id, rating), do: %{national_id: id, last_name: "X", national_rating: rating}

  describe "keep_ratings_when_list_has_none/1" do
    test "a list with no rating on any row keeps each player's stored rating" do
      seed!()

      rows = Sync.keep_ratings_when_list_has_none([row("12345", nil), row("99999", nil)])

      assert Enum.find(rows, &(&1.national_id == "12345")).national_rating == 1850
      # A player the store has never seen stays unrated.
      assert Enum.find(rows, &(&1.national_id == "99999")).national_rating == nil
    end

    test "a list with even one rating is authoritative, unrated rows included" do
      seed!()

      rows = Sync.keep_ratings_when_list_has_none([row("12345", nil), row("67890", 1999)])

      assert Enum.find(rows, &(&1.national_id == "12345")).national_rating == nil
      assert Enum.find(rows, &(&1.national_id == "67890")).national_rating == 1999
    end

    test "an empty list is left for the count guard to refuse" do
      assert Sync.keep_ratings_when_list_has_none([]) == []
    end
  end
end
