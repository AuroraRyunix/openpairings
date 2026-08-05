defmodule PairingsEngine.Repo.Migrations.AddAbsentCountsAsVur do
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      # Whether a `byes`-table "absent" row (SWAR's plain no-show, distinct
      # from a requested bye or a forfeit) is treated as a voluntary
      # unplayed round for tiebreak purposes (FIDE C.07 Art. 16 — trailing
      # occurrences get downgraded to a draw for opponents' Buchholz/SB, and
      # it becomes eligible for the Art. 16.5.1 Cut-1 priority). FIDE's own
      # rules have no "absent" concept at all, so the strict/default
      # reading is off: an absence always counts at its configured award
      # value, the same treatment as a forfeit loss. Opt-in, not the
      # default — see PairingsEngine.Standings.add_bye_records/3.
      add :absent_counts_as_vur, :boolean, default: false, null: false
    end
  end
end
