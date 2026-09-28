defmodule PairingsEngine.Repo.Migrations.AddRoundPublishDueAt do
  @moduledoc """
  A due-at marker for a round paired under "timed" or "scheduled" publish
  mode, so a delay running out has something to wake up for.

  `rounds.published_at` already holds the instant a round becomes public,
  but nothing revisited it once pairing wrote it: the only thing that ever
  enqueues an OpenResults publish is a write elsewhere in the app, so a
  round paired with, say, "15 minutes after pairing" and nothing else
  touched in the meantime never actually reached the results site once
  those 15 minutes ran out - see `PairingsEngine.Publishing.promote_due_rounds/1`.

  `publish_due_at` is that round's own copy of `published_at`, set ONLY
  when it is genuinely in the future at pairing time (immediate/manual
  rounds, and a "timed" round with a zero delay, leave it nil - the
  ordinary post-pairing publish already covers them). `promote_due_rounds/1`
  clears it the moment it acts, which is what makes the sweep idempotent
  and safe to run on every `Publishing.Drain` tick and at boot.

  Additive and nil-by-default, so reversible and inert for every round
  paired before this shipped.
  """
  use Ecto.Migration

  def change do
    alter table(:rounds) do
      add :publish_due_at, :utc_datetime
    end

    create index(:rounds, [:publish_due_at])
  end
end
