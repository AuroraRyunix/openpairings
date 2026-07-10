defmodule PairingsEngine.Fide.FidePlayer do
  use Ecto.Schema

  @primary_key {:fide_id, :integer, autogenerate: false}
  schema "fide_players" do
    field :name, :string
    field :federation, :string, default: ""
    field :sex, :string, default: ""
    field :title, :string, default: ""
    field :standard_rating, :integer
    field :rapid_rating, :integer
    field :blitz_rating, :integer
    field :birth_year, :integer
    field :flag, :string, default: ""
  end
end
