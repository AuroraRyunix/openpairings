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

    # The event's address on the results site (`/e/<public_slug>`): random,
    # minted once when the group is made and never cast from a form. It is
    # what the published snapshots of the members have in common, and it
    # says nothing about this machine's row ids. See
    # `PairingsEngine.TournamentGroups`, "On the results site".
    field :public_slug, :string

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
    |> put_public_slug()
  end

  defp put_public_slug(changeset) do
    if get_field(changeset, :public_slug),
      do: changeset,
      else: put_change(changeset, :public_slug, generate_public_slug())
  end

  @doc "A fresh random event slug: 72 bits, lowercase hex."
  def generate_public_slug, do: :crypto.strong_rand_bytes(9) |> Base.encode16(case: :lower)
end
