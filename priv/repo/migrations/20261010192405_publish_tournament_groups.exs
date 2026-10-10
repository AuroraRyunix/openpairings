defmodule PairingsEngine.Repo.Migrations.PublishTournamentGroups do
  @moduledoc """
  What publishing a tournament group as one event needs to remember. See
  `PairingsEngine.TournamentGroups`, "On the results site".

    * `tournament_groups.public_slug` - the event's address on the results
      site (`/e/<slug>`). Random, so it says nothing about this machine's
      row ids or how many groups it has; minted here for the groups that
      already exist and by the schema for new ones. Nullable in the table
      because SQLite cannot add a NOT NULL column without a constant
      default; every row has one after this runs, and the unique index
      would refuse a second NULL-free duplicate anyway.
    * `tournaments.openresults_group_sent` - a fingerprint of the `group`
      block in the last snapshot that reached the results site, so the app
      can tell which members' published pages are out of date when a
      sibling is published, withdrawn, renamed or moved, without re-sending
      every member on every result.
  """
  use Ecto.Migration

  def up do
    alter table(:tournament_groups) do
      add :public_slug, :string
    end

    alter table(:tournaments) do
      add :openresults_group_sent, :string
    end

    flush()

    # 72 random bits per group, as lowercase hex - the same strength as a
    # tournament's own public slug.
    execute "UPDATE tournament_groups SET public_slug = lower(hex(randomblob(9))) WHERE public_slug IS NULL"

    create unique_index(:tournament_groups, [:public_slug])
  end

  def down do
    drop unique_index(:tournament_groups, [:public_slug])

    alter table(:tournaments) do
      remove :openresults_group_sent
    end

    alter table(:tournament_groups) do
      remove :public_slug
    end
  end
end
