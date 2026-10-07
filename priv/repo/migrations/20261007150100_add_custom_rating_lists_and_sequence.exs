defmodule PairingsEngine.Repo.Migrations.AddCustomRatingListsAndSequence do
  @moduledoc """
  Custom rating lists, the per-tournament rating-list sequence and the switch
  for the automatic consistency check.

    * `custom_rating_lists` / `custom_rating_entries` - rating lists an
      administrator loads from a CSV file. Machine-wide, like the FIDE and
      national lists.
    * `tournaments.rating_list_sequence` - the ordered lists that supply a
      player's rating when adding or refreshing (`NULL`: the default for the
      tournament's rate of play).
    * `tournaments.rating_checks_enabled` - whether the automatic consistency
      notice is shown (the manual Refresh always works).
  """
  use Ecto.Migration

  def change do
    create table(:custom_rating_lists) do
      add :name, :string, null: false
      add :entry_count, :integer, null: false, default: 0
      timestamps(type: :utc_datetime)
    end

    create unique_index(:custom_rating_lists, ["lower(name)"],
             name: :custom_rating_lists_name_index
           )

    create table(:custom_rating_entries) do
      add :list_id, references(:custom_rating_lists, on_delete: :delete_all), null: false
      add :ext_id, :string, null: false
      add :name, :string, null: false
      add :rating, :integer
      add :federation, :string, null: false, default: ""
      add :title, :string, null: false, default: ""
      add :birth_year, :integer
      add :fide_id, :integer
    end

    create unique_index(:custom_rating_entries, [:list_id, :ext_id])
    create index(:custom_rating_entries, [:list_id, :fide_id])

    alter table(:tournaments) do
      add :rating_list_sequence, {:array, :string}
      add :rating_checks_enabled, :boolean, null: false, default: true
    end
  end
end
