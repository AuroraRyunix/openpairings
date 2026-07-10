defmodule PairingsEngine.Tournaments.Player do
  use Ecto.Schema
  import Ecto.Changeset

  schema "players" do
    field :name, :string
    field :sex, :string, default: ""
    field :title, :string, default: ""
    field :fide_id, :integer
    field :fide_rating, :integer, default: 0
    field :national_id, :string, default: ""
    field :national_rating, :integer, default: 0
    field :federation, :string, default: ""
    field :birth_year, :integer
    field :club, :string, default: ""
    field :status, :string, default: "active"
    field :start_round, :integer, default: 1
    field :board_order, :integer
    field :pairing_number, :integer

    belongs_to :tournament, PairingsEngine.Tournaments.Tournament
    belongs_to :team, PairingsEngine.Tournaments.Team

    timestamps(type: :utc_datetime)
  end

  def changeset(player, attrs) do
    player
    |> cast(attrs, [
      :name, :sex, :title, :fide_id, :fide_rating, :national_id,
      :national_rating, :federation, :birth_year, :club, :status,
      :start_round, :team_id, :board_order, :pairing_number
    ])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_inclusion(:status, ~w(active withdrawn))
    |> unique_fide_id_in_tournament()
  end

  defp unique_fide_id_in_tournament(changeset) do
    # Enforced at the context level (needs tournament scope); placeholder for
    # schema-level validations that don't require a query.
    changeset
  end

  @doc "Rating used for sorting/pairing display: FIDE first, national as fallback."
  def rating(%__MODULE__{fide_rating: f, national_rating: n}) do
    if f > 0, do: f, else: n
  end
end
