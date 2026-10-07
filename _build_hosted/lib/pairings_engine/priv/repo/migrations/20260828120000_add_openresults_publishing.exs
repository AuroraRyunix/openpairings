defmodule PairingsEngine.Repo.Migrations.AddOpenresultsPublishing do
  @moduledoc """
  Publishing a tournament to OpenResults.

  Two things, for the two halves of the feature.

  `tournaments.publish_to_openresults` is the per-event opt-in. It defaults
  to false and is deliberately NOT cast by the ordinary changeset, exactly
  like `public_pages_enabled` and `registration_open` beside it: a normal
  settings save must not be able to start sending an event's player names,
  ratings and clubs to a remote server, and an existing tournament must not
  inherit that on upgrade.

  `publish_queue` is what makes the split worth having. A chess venue's wifi
  - school gyms, hotel basements - is exactly where an arbiter is standing
  when they pair round 5, and a failed publish must sit in a queue and retry
  rather than surface as an error in the middle of a round.

  The queue holds an INTENT, not a payload: one row per tournament, with a
  unique index enforcing that. A snapshot is a whole document rather than a
  delta, so five publishes stacked up behind a dead connection are not five
  things to send - they are one send of the current state, and rebuilding at
  send time is both smaller and more correct than replaying a stale body.
  """
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      add :publish_to_openresults, :boolean, null: false, default: false
    end

    create table(:publish_queue) do
      add :tournament_id, references(:tournaments, on_delete: :delete_all), null: false

      # Attempt bookkeeping. `attempts` drives the backoff and is reset on
      # success; `last_error` is what the settings card shows the arbiter,
      # because "it is not working" is useless and "connection timed out at
      # 14:32" is actionable.
      add :attempts, :integer, null: false, default: 0
      add :last_error, :text
      add :last_attempt_at, :utc_datetime_usec

      # When the drain may next try this row. Set into the future on failure
      # so a dead endpoint is retried on a backoff rather than hammered.
      add :next_attempt_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # One pending publish per tournament: enqueueing twice is not two sends.
    create unique_index(:publish_queue, [:tournament_id])

    # The drain's only query is "what is due now", oldest first.
    create index(:publish_queue, [:next_attempt_at])
  end
end
