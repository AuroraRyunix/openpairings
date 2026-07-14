defmodule PairingsEngine.Tournaments.Round do
  use Ecto.Schema
  import Ecto.Changeset

  schema "rounds" do
    field :number, :integer
    field :date, :string, default: ""
    field :status, :string, default: "pairing"

    belongs_to :tournament, PairingsEngine.Tournaments.Tournament
    has_many :pairings, PairingsEngine.Tournaments.Pairing
  end

  def changeset(round, attrs) do
    round
    |> cast(attrs, [:number, :date, :status])
    |> validate_required([:number])
    |> validate_inclusion(:status, ~w(pairing playing finished))
  end
end
