defmodule PairingsEngine.Repo.Migrations.AddPlayerCategories do
  use Ecto.Migration

  # Several categories per player. `players.category` stays exactly where it
  # is and is never rewritten by this migration - its MEANING narrows from
  # "the player's category" to "the pairing-pool override", and for every row
  # that exists today the two are the same value.
  #
  # `:text` with an explicit `"[]"` default rather than
  # `{:array, :string}, default: []`: the SQLite adapter maps an array onto a
  # plain TEXT column holding JSON either way
  # (`Ecto.Adapters.SQLite3.DataType`), so writing it out says what the
  # column actually holds and makes the default literal unambiguous. The
  # schema still declares `{:array, :string}` and the adapter's JSON loader
  # does the decoding.
  def up do
    alter table(:players) do
      add :categories, :text, null: false, default: "[]"
    end

    # Backfilled here, not in a follow-up task. A window in which every
    # player has an empty tag list is a window in which a prize list is
    # wrong, and this app is deployed to arbiters who run events while it
    # upgrades. `json_array()` rather than string concatenation so a category
    # name containing a quote cannot produce invalid JSON.
    execute """
    UPDATE players
       SET categories = json_array(category)
     WHERE category IS NOT NULL AND category <> ''
    """
  end

  def down do
    alter table(:players) do
      remove :categories
    end
  end
end
