defmodule PairingsEngine.Tournaments.Tournament do
  use Ecto.Schema
  import Ecto.Changeset

  @types ~w(swiss roundrobin team-swiss team-roundrobin)
  @rating_types ~w(fide national none)
  @accelerations ~w(none baku)
  @statuses ~w(setup running finished)

  schema "tournaments" do
    field :name, :string
    field :type, :string, default: "swiss"
    field :venue, :string, default: ""
    field :city, :string, default: ""
    field :federation, :string, default: ""
    field :start_date, :string, default: ""
    field :end_date, :string, default: ""
    field :organizer, :string, default: ""
    field :chief_arbiter, :string, default: ""
    field :deputy_arbiter, :string, default: ""
    field :time_control, :string, default: ""
    field :rounds_count, :integer, default: 9
    field :rating_type, :string, default: "fide"
    field :points_win, :float, default: 1.0
    field :points_draw, :float, default: 0.5
    field :points_loss, :float, default: 0.0
    field :bye_value, :float, default: 1.0
    field :tiebreaks, {:array, :string}, default: []
    field :acceleration, :string, default: "none"
    field :status, :string, default: "setup"

    belongs_to :user, PairingsEngine.Accounts.User
    has_many :players, PairingsEngine.Tournaments.Player
    has_many :teams, PairingsEngine.Tournaments.Team
    has_many :rounds, PairingsEngine.Tournaments.Round

    timestamps(type: :utc_datetime)
  end

  def changeset(tournament, attrs) do
    tournament
    |> cast(attrs, [
      :name, :type, :venue, :city, :federation, :start_date, :end_date,
      :organizer, :chief_arbiter, :deputy_arbiter, :time_control,
      :rounds_count, :rating_type, :points_win, :points_draw, :points_loss,
      :bye_value, :tiebreaks, :acceleration, :status
    ])
    |> validate_required([:name, :type, :rounds_count])
    |> validate_length(:name, min: 1, max: 200)
    |> validate_inclusion(:type, @types)
    |> validate_inclusion(:rating_type, @rating_types)
    |> validate_inclusion(:acceleration, @accelerations)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:rounds_count, greater_than: 0, less_than_or_equal_to: 30)
  end

  def types, do: @types

  def type_label("swiss"), do: "Swiss (individual)"
  def type_label("roundrobin"), do: "Round robin (individual)"
  def type_label("team-swiss"), do: "Swiss (teams)"
  def type_label("team-roundrobin"), do: "Round robin (teams)"
  def type_label(other), do: other
end
