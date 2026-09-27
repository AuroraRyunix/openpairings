defmodule PairingsEngine.Repo.Migrations.AddSwarCompleteSettings do
  @moduledoc """
  Two tournament columns for a complete SWAR import and export
  (docs/swar-import.md, "Import and export: what goes where").

    * `categories_ranked_separately` - each category is ranked on its own:
      its own places from 1, and the tie-break groups (direct encounter
      above all) stop at the category. SWAR's "separate categories"
      (`CatSepares`) setting. Off for every existing row, so no standings
      move.
    * `swar_settings` - the SWAR file's own settings that have no
      OpenPairings counterpart (the rating SWAR pairs by, the first table
      number, the homologation round ranges, SWAR's XtraPoints band table,
      its exact tournament type and tie-break list, ...), kept as the file
      had them so an export can write them back. Written by the SWAR import
      only, read by the SWAR export only; empty for every existing row.

  Additive and defaulted, so reversible and safe on existing data.
  """
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      add :categories_ranked_separately, :boolean, null: false, default: false
      add :swar_settings, :map, null: false, default: %{}
    end
  end
end
