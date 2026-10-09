defmodule PairingsEngine.TournamentGroups.Group do
  @moduledoc """
  An event made of several separate tournaments - the Open, the U20, the
  rapid on the side - so an arbiter can jump between them. See
  `PairingsEngine.TournamentGroups`.

  Not a player category (`PairingsEngine.Categories`): a category splits one
  tournament's field, a group strings together tournaments that each have
  their own players, rounds and pairings.

  It has no owner. Who may touch it is decided by its members: anyone who
  may edit one of them. A group with no members has no reason to exist and
  is deleted when the last one leaves.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @max_name 120

  schema "tournament_groups" do
    field :name, :string

    has_many :members, PairingsEngine.TournamentGroups.Member, foreign_key: :group_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def max_name, do: @max_name

  def changeset(group, attrs) do
    group
    |> cast(attrs, [:name])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: @max_name)
  end
end
