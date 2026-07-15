defmodule PairingsEngine.Repo.Migrations.AddCategoriesEnabledAndSoftDelete do
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      # Opt-in toggle: when true, the Categories tab (categories + extra
      # points admin) appears in the top bar — see CategoriesLive / layouts.
      add :categories_enabled, :boolean, default: false, null: false
      # Soft-delete timestamp for the recycle bin: nil = live, otherwise the
      # moment it was moved to the bin. Auto-purged after 3 months.
      add :deleted_at, :utc_datetime
    end

    create index(:tournaments, [:deleted_at])
  end
end
