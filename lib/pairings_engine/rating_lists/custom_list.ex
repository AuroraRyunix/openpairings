defmodule PairingsEngine.RatingLists.CustomList do
  @moduledoc "A rating list loaded from a CSV file (see `PairingsEngine.RatingLists`)."
  use Ecto.Schema

  schema "custom_rating_lists" do
    field :name, :string
    field :entry_count, :integer, default: 0
    timestamps(type: :utc_datetime)
  end
end
