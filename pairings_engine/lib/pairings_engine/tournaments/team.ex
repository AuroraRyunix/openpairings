defmodule PairingsEngine.Tournaments.Team do
  use Ecto.Schema
  import Ecto.Changeset

  schema "teams" do
    field :name, :string
    field :captain, :string, default: ""

    belongs_to :tournament, PairingsEngine.Tournaments.Tournament
    has_many :players, PairingsEngine.Tournaments.Player
  end

  def changeset(team, attrs) do
    team
    |> cast(attrs, [:name, :captain])
    |> validate_required([:name])
  end
end
