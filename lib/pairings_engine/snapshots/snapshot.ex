defmodule PairingsEngine.Snapshots.Snapshot do
  @moduledoc """
  One point-in-time copy of a whole tournament — see
  `PairingsEngine.Snapshots` for when these are taken and what the payload
  contains.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "tournament_snapshots" do
    field :trigger, :string
    field :summary, :string
    field :payload, :map

    # Exempt from retention pruning — see the migration and
    # `PairingsEngine.Snapshots.prune/1`. Set on the snapshot a restore takes
    # of the state it's about to replace, so stepping forward again stays
    # possible however much back-and-forth happens.
    field :pinned, :boolean, default: false

    belongs_to :tournament, PairingsEngine.Tournaments.Tournament
    belongs_to :user, PairingsEngine.Accounts.User

    # The restore point that was current when this one was taken — see the
    # migration. Nil for a tournament's first snapshot (a root).
    belongs_to :parent, __MODULE__, foreign_key: :parent_id

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [:tournament_id, :user_id, :trigger, :summary, :payload, :pinned, :parent_id])
    |> validate_required([:tournament_id, :trigger, :payload])
  end
end
