defmodule PairingsEngine.Repo.Migrations.AddInviteStatusToCollaborators do
  use Ecto.Migration

  # Upgrades sharing from "added = instant access" to "added = pending, must
  # explicitly accept" — see docs/teams.md. `status` gates access everywhere
  # (PairingsEngine.Tournaments.collaborator_tournament_ids/1 only honours
  # "accepted" rows); `invite_token` is the secret in the /invites/:token
  # accept/decline URL emailed to the invitee.
  def up do
    alter table(:tournament_collaborators) do
      add :status, :string, null: false, default: "pending"
      add :invite_token, :string
    end

    create unique_index(:tournament_collaborators, [:invite_token])

    # Rows created before this migration were granted access instantly under
    # the old semantics — grandfather them in as already accepted so nobody's
    # existing access is silently revoked by this upgrade.
    execute "UPDATE tournament_collaborators SET status = 'accepted'"
  end

  def down do
    drop unique_index(:tournament_collaborators, [:invite_token])

    alter table(:tournament_collaborators) do
      remove :status
      remove :invite_token
    end
  end
end
