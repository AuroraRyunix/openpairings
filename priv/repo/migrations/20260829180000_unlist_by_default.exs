defmodule PairingsEngine.Repo.Migrations.UnlistByDefault do
  @moduledoc """
  Publishing a tournament stops meaning advertising it.

  `public_listed` shipped defaulting to true, on the reasoning that it was
  what publishing had always meant. That reasoning was about not changing
  behaviour, and it produced behaviour nobody chose: the 2026-08-29 migration
  switched publishing on for every tournament that had local public pages, and
  all of them appeared on the results site's front page at once - sixteen
  events listed publicly because of a schema change, not because sixteen
  arbiters decided to advertise them.

  Two acts now, not one. Publishing gives a tournament a public address.
  Listing puts it on the front page, and is a separate deliberate choice.

  ## Why the column is dropped and re-added

  SQLite has no `ALTER COLUMN`, so a default cannot be changed in place. It
  could have been left stale - every insert in this app goes through
  `Tournament`'s schema default, which is the one that actually governs - but
  a database default that disagrees with the schema is exactly the sort of
  thing that surfaces years later through a restore or a raw insert, and here
  it costs nothing to fix: every row is being reset to the same value anyway,
  so the drop loses no information that the UPDATE would have kept.

  ## Why existing rows are reset

  The feature is hours old, so there is no arbiter's decision to overwrite -
  every `true` in the column is this default rather than a choice. Leaving
  them would preserve exactly the state being corrected.

  Nothing is deleted and nothing is taken down: an unlisted tournament keeps
  its address and stays readable to anyone holding the link. This changes what
  a stranger browsing the site finds, which is the thing that should have been
  opt-in from the start.
  """
  use Ecto.Migration

  def up do
    alter table(:tournaments) do
      remove :public_listed
    end

    alter table(:tournaments) do
      add :public_listed, :boolean, default: false, null: false
    end
  end

  def down do
    alter table(:tournaments) do
      remove :public_listed
    end

    alter table(:tournaments) do
      add :public_listed, :boolean, default: true, null: false
    end
  end
end
