defmodule PairingsEngine.Repo.Migrations.AddRoomsToTournaments do
  use Ecto.Migration

  # The rooms of a playing hall: a JSON list of `{"name", "boards"}`, boards
  # in `PairingsEngine.BoardRanges`' own spelling ("1-20, 35"). Empty for
  # every tournament that existed before this, which is every tournament
  # that has been getting by on one room, or on pretending to.
  def change do
    alter table(:tournaments) do
      add :rooms, {:array, :map}, null: false, default: []
    end
  end
end
