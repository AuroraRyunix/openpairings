defmodule PairingsEngine.Repo.Migrations.AddPublishQueueRevision do
  @moduledoc """
  A counter that makes "something was queued while the last publish was in
  flight" a fact rather than a guess.

  ## The loss this closes

  A queue row is the ONLY record that a tournament has unsent changes - the
  payload is rebuilt at send time, so there is nothing else to inspect. The
  drain deleted that row after a successful send. Between the moment
  `Snapshot.build/1` read the database and the moment the row was deleted sat
  a whole HTTP round trip, up to fifteen seconds of it on a bad venue
  connection; and `enqueue/1` is deliberately `on_conflict: :nothing`, so a
  result typed inside that window found the row already there and wrote
  nothing at all. Deleting the row then threw away the only trace of it. The
  result stayed in the arbiter's database and never reached the public page -
  not late, never - until some unrelated later write happened to enqueue
  again.

  `backfill/0` could not rescue it either: it only looks for tournaments with
  no `openresults_key`, and a tournament in this state has one.

  ## Why a counter rather than a timestamp

  `updated_at` already exists and could carry the same signal, but only if
  every enqueue bumped it, and then "the row changed" and "the row was
  retried" become the same event - `record_failure/2` writes the row too. A
  counter that ONLY `enqueue` moves says exactly one thing, and the drain's
  conditional delete (`where revision == the revision it read`) reads as what
  it is: delete this row only if nothing has been queued since I picked it up.

  Existing rows start at 0, which is correct - whatever their history, the
  next drain reads their current value and compares against it.
  """
  use Ecto.Migration

  def change do
    alter table(:publish_queue) do
      add :revision, :integer, null: false, default: 0
    end
  end
end
