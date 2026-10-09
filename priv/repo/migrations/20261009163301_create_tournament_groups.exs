defmodule PairingsEngine.Repo.Migrations.CreateTournamentGroups do
  @moduledoc """
  Tournament groups: one event made of several separate tournaments (the
  Open, the U20, the rapid on the side), so the app can switch between them.
  See `PairingsEngine.TournamentGroups`.

  Two tables rather than three columns on `tournaments`: a group is a thing
  with its own name, and the tournaments row is wide enough already.
  `tournament_id` is unique - a tournament is in one group or none - and
  cascades, so purging a tournament takes its membership with it.
  """
  use Ecto.Migration

  def change do
    create table(:tournament_groups) do
      add :name, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create table(:tournament_group_members) do
      add :group_id, references(:tournament_groups, on_delete: :delete_all), null: false
      add :tournament_id, references(:tournaments, on_delete: :delete_all), null: false
      add :label, :string
      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:tournament_group_members, [:tournament_id])
    create index(:tournament_group_members, [:group_id])
  end
end
