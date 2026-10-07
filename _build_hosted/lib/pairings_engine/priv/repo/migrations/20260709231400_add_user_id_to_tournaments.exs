defmodule PairingsEngine.Repo.Migrations.AddUserIdToTournaments do
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      # Nullable: existing dev tournaments stay unowned (simply invisible to
      # everyone once ownership-scoped listing lands).
      add :user_id, references(:users, on_delete: :delete_all)
    end

    create index(:tournaments, [:user_id])
  end
end
