defmodule PairingsEngine.RatingLists.CustomEntry do
  @moduledoc "One player of a custom rating list."
  use Ecto.Schema

  schema "custom_rating_entries" do
    field :list_id, :integer
    # The list's own identifier for the player (not necessarily a FIDE ID).
    field :ext_id, :string
    field :name, :string
    field :rating, :integer
    field :federation, :string, default: ""
    field :title, :string, default: ""
    field :birth_year, :integer
    # Optional link to the FIDE list, so the entry can be shown beside a FIDE
    # search result.
    field :fide_id, :integer
  end
end
