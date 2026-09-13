defmodule PairingsEngine.Tournaments.Team do
  @moduledoc """
  A chess team inside a team tournament (`type` `team-roundrobin` or
  `team-swiss`). Not to be confused with `PairingsEngine.Tournaments.Collaborator`,
  the people an arbiter shares a tournament with.

  The roster is `players` with this `team_id`, in `board_order`. See
  `docs/team-tournaments.md`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "teams" do
    field :name, :string
    field :captain, :string, default: ""
    field :short_name, :string, default: ""

    # The arbiter's ordering of the teams before the draw is frozen - what
    # becomes `pairing_number` when round 1 is paired. Managed by
    # `Tournaments.move_team/3` and `Tournaments.seed_teams_by_rating/1`, and
    # NOT cast, so an ordinary rename cannot reorder the field.
    field :seed, :integer

    # The team's TPN (C.04.6 Art. 1.1). nil until the first round is paired,
    # then frozen: every match already on the board was built from it. Written
    # only by `PairingsEngine.TeamRoundRobin`, never cast.
    field :pairing_number, :integer

    belongs_to :tournament, PairingsEngine.Tournaments.Tournament
    has_many :players, PairingsEngine.Tournaments.Player
  end

  def changeset(team, attrs) do
    team
    |> cast(attrs, [:name, :captain, :short_name])
    |> update_change(:name, &trim/1)
    |> update_change(:short_name, &trim/1)
    |> update_change(:captain, &trim/1)
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_length(:short_name, max: 12)
    |> validate_length(:captain, max: 100)
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value

  @doc "The label a narrow column has room for: the short name when set, the name otherwise."
  def label(%__MODULE__{short_name: short}) when is_binary(short) and short != "", do: short
  def label(%__MODULE__{name: name}), do: name
end
