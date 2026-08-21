defmodule PairingsEngine.Repo.Migrations.AddPairByCategory do
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      # Native per-category Swiss pairing (SWAR-parity #24) - each category
      # (tournament.categories) gets its own independent JaVaFo run, merged
      # into one combined Round. See PairingsEngine.Pairing's per-category
      # pairing logic (pair_category_groups/3 and friends) and
      # PairingsEngine.Tournaments.Tournament's changeset validations.
      add :pair_by_category, :boolean, default: false, null: false
    end
  end
end
