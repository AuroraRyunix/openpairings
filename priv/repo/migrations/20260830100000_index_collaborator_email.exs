defmodule PairingsEngine.Repo.Migrations.IndexCollaboratorEmail do
  use Ecto.Migration

  # `Tournaments.collaborator_tournament_ids/1` matches a collaborator row by
  # `user_id OR email` - an invite is created against an email address and
  # only gains a `user_id` once that person signs in. The table has a
  # composite unique index on `[tournament_id, email]` and one on `[user_id]`;
  # nothing served the email half on its own, and SQLite cannot use the
  # composite for a query that does not constrain its leading column.
  #
  # That subquery runs inside `list_tournaments/1`, so it is on every
  # authorized page mount, not just the collaboration screens. The table is
  # small - one row per invite, on a feature most tournaments never use - so
  # this is not fixing a measured problem; it is one line closing the last
  # unindexed access path on a query that runs constantly.
  def change do
    create index(:tournament_collaborators, [:email])
  end
end
