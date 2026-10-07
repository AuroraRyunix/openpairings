defmodule PairingsEngine.Repo.Migrations.AddKeycloakSubToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # The stable Keycloak subject (OIDC `sub` claim) for a user who has ever
      # signed in via 02cloud SSO. Nil for accounts created through normal
      # registration/magic-link that have never used SSO. Deliberately not the
      # email, which can change on either side and isn't a stable identity key.
      add :keycloak_sub, :string
    end

    create unique_index(:users, [:keycloak_sub])
  end
end
