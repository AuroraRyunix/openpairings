defmodule PairingsEngine.Repo.Migrations.AddCategoryRules do
  use Ecto.Migration

  # Optional threshold rule behind an existing category name - see
  # Tournament's `category_rules` field doc. Empty by default: a category
  # with no entry here is exactly what it always was, a plain hand-assigned
  # name, so no existing tournament's categories behave any differently.
  def change do
    alter table(:tournaments) do
      add :category_rules, :map, null: false, default: %{}
    end
  end
end
