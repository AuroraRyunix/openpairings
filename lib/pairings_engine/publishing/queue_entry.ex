defmodule PairingsEngine.Publishing.QueueEntry do
  @moduledoc """
  One pending publish.

  There is at most one row per tournament, enforced by a unique index rather
  than by anything in application code - see
  `PairingsEngine.Publishing`'s moduledoc for why a snapshot's
  whole-document shape makes that the right cardinality.
  """
  use Ecto.Schema

  schema "publish_queue" do
    belongs_to :tournament, PairingsEngine.Tournaments.Tournament

    field :attempts, :integer, default: 0
    field :last_error, :string
    field :last_attempt_at, :utc_datetime_usec
    field :next_attempt_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end
end
