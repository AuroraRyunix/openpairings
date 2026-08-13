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

    belongs_to :tournament, PairingsEngine.Tournaments.Tournament
    belongs_to :user, PairingsEngine.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [:tournament_id, :user_id, :trigger, :summary, :payload])
    |> validate_required([:tournament_id, :trigger, :payload])
  end
end
