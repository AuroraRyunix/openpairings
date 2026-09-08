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

    # Bumped by `PairingsEngine.Publishing.enqueue/1` and nothing else, so a
    # drain can tell "nothing has been queued since I read this row" from
    # "the row is still here because the send failed". See the migration for
    # the result that used to be lost without it.
    field :revision, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end
end
