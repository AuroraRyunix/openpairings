defmodule PairingsEngine.Repo.Migrations.RepublishAfterUnlisting do
  @moduledoc """
  Tells the results site about the unlisting the previous migration did.

  `20260829180000_unlist_by_default` reset `public_listed` on every row. That
  is a local flag, and the only way it reaches the results site is by riding
  along in a snapshot - so the front page went on listing sixteen tournaments
  that this machine had just decided were unlisted, and would have gone on
  doing so until each of them happened to publish for some other reason.

  `Tournaments.set_public_listed/2` enqueues a publish for exactly this
  reason. A migration is raw SQL and cannot call it, which is the same trap
  the morning's publishing migration fell into: the state changes here and
  the consequence does not.

  ## Why a migration writes to an application queue

  It does not, quite. It writes an INTENT - `publish_queue` holds tournament
  ids and nothing else, and `PairingsEngine.Publishing.drain/0` rebuilds every
  document from the live tournament when it sends. So this is the same row
  `enqueue/1` would have written, and no payload is being frozen into a
  migration.

  It is scoped to tournaments that have actually published (`openresults_key`
  is not null). A tournament with no key has nothing out there to correct, and
  `Publishing.backfill/0` already covers the case where one is switched on but
  has never sent.

  Harmless to run on a machine with no results site configured: the drain
  finds nothing to send to, and the rows are retried and eventually just sit
  there costing nothing.
  """
  use Ecto.Migration

  def up do
    execute """
    INSERT OR IGNORE INTO publish_queue (tournament_id, attempts, inserted_at, updated_at)
    SELECT id, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    FROM tournaments
    WHERE openresults_key IS NOT NULL AND deleted_at IS NULL
    """
  end

  # Nothing to undo. A queued publish either went out or was cleaned up by the
  # drain; either way there is no state here to reverse, and deleting queue
  # rows on a rollback could throw away intents that have nothing to do with
  # this migration.
  def down, do: :ok
end
