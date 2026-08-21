defmodule PairingsEngine.Repo.Migrations.AddPublicPagesEnabled do
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      # Whether the no-login public pages (/p/:slug/...) are served. Default
      # true so every existing tournament's already-shared link keeps working;
      # an arbiter can switch it off to take a tournament's public pages down,
      # and rotating public_slug (Tournaments.rotate_public_slug/1) invalidates
      # a leaked link without disabling the feature. Written only via
      # Tournaments.set_public_pages/2 and rotate_public_slug/1 - NOT cast by
      # changeset/2, same as public_slug and deleted_at.
      add :public_pages_enabled, :boolean, default: true, null: false
    end
  end
end
