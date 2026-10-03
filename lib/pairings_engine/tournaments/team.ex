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

    # The first round a withdrawn team does not play
    # (`Tournaments.withdraw_team/3`); nil for a team still in the event.
    # Never cast: only the withdrawal and its reversal write it.
    field :withdrawn_from_round, :integer
    # The players the withdrawal withdrew, so `Tournaments.reinstate_team/2`
    # brings back exactly those and not one withdrawn on their own before.
    field :withdrawal_player_ids, {:array, :integer}, default: []

    # A rating typed for the team by the arbiter: used for seeding and shown
    # in place of the one worked out from the roster whenever it is set
    # (`Tournaments.team_rating/2`), so a team with no players can be seeded
    # too. nil - the default - works it out.
    field :rating_override, :integer

    # The rounds the team as a whole does not play (`Tournaments.
    # set_team_absent/4`), ascending. A team Swiss leaves it out of those
    # rounds' pairing; a team round robin gives each of its boards in those
    # rounds to the opponent. Never cast.
    field :absent_rounds, {:array, :integer}, default: []

    belongs_to :tournament, PairingsEngine.Tournaments.Tournament
    has_many :players, PairingsEngine.Tournaments.Player
  end

  def changeset(team, attrs) do
    team
    |> cast(attrs, [:name, :captain, :short_name, :rating_override])
    |> update_change(:name, &trim/1)
    |> update_change(:short_name, &trim/1)
    |> update_change(:captain, &trim/1)
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_length(:short_name, max: 12)
    |> validate_length(:captain, max: 100)
    |> validate_number(:rating_override, greater_than_or_equal_to: 0, less_than: 4000)
  end

  @doc "Whether the team as a whole sits out round `number` (`absent_rounds`)."
  def absent_in?(%__MODULE__{absent_rounds: rounds}, number) when is_list(rounds),
    do: number in rounds

  def absent_in?(_team, _number), do: false

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value

  @doc "The label a narrow column has room for: the short name when set, the name otherwise."
  def label(%__MODULE__{short_name: short}) when is_binary(short) and short != "", do: short
  def label(%__MODULE__{name: name}), do: name
end
