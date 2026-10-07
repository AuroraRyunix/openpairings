defmodule PairingsEngine.Repo.Migrations.CreateTournamentCollaborators do
  use Ecto.Migration

  def change do
    # "Share a tournament with other users by email" - see docs/teams.md.
    # `user_id` starts out nil while the invited email has no account yet
    # ("pending"); it gets linked the moment that email logs in (see
    # PairingsEngine.Tournaments.link_pending_collaborators/1). Until then,
    # access is still granted by matching on `email` alone.
    #
    # Not to be confused with the `teams` table (chess teams within a team
    # tournament, PairingsEngine.Tournaments.Team) - this is unrelated,
    # user-access sharing.
    create table(:tournament_collaborators) do
      add :tournament_id, references(:tournaments, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all)
      add :email, :string, null: false, collate: :nocase
      # "editor" only for v1 - the owner is implicit via tournaments.user_id,
      # not a row in this table.
      add :role, :string, null: false, default: "editor"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:tournament_collaborators, [:tournament_id, :email])
    create index(:tournament_collaborators, [:user_id])
  end
end
