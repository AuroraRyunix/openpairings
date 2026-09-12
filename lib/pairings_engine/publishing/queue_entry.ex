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

    # The same failure as `last_error`, as data - a
    # `PairingsEngine.Publishing.Failure` encoded by `Failure.encode/1`, or
    # nil. `last_error` is an English line for logs; this is what a screen
    # words in the arbiter's language, with the limit the server named.
    # Written for public-mode sends only, where the server's codes are the
    # whole story.
    field :last_reason, :string

    # Set when the server said this tournament cannot be published as it is
    # (`tournament_limit`, `snapshot_too_large`, `not_owner`). A stopped row
    # is never due: retrying on a timer would only hear the same refusal. It
    # is kept, because it is still the record that something is unsent, and
    # `Publishing.retry/1` - the arbiter's "Try again" - clears it.
    field :stopped_at, :utc_datetime_usec
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
