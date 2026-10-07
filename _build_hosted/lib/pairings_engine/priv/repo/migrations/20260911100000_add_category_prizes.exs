defmodule PairingsEngine.Repo.Migrations.AddCategoryPrizes do
  use Ecto.Migration

  # Optional prize count per category (name => integer), separate from
  # `category_rules` on purpose - see the field's own doc comment in
  # `PairingsEngine.Tournaments.Tournament`. No backfill needed: an empty
  # map means exactly what it always will for a tournament nobody has set a
  # prize count on yet.
  #
  # `:text` with an explicit `"{}"` default, same reasoning as
  # `category_rules`/`officials`/every other JSON-shaped map column on this
  # table: SQLite has no native map type, and writing out the literal the
  # adapter actually stores says so rather than leaving it implicit in
  # `{:map, default: %{}}` alone.
  def change do
    alter table(:tournaments) do
      add :category_prizes, :text, null: false, default: "{}"
    end
  end
end
