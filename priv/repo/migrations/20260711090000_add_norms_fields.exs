defmodule PairingsEngine.Repo.Migrations.AddNormsFields do
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      # Officials / pairing-system / FIDE-report metadata that doesn't
      # warrant its own column each (see PairingsEngine.Tournaments.Tournament
      # for the recognised keys). Stored as JSON text by ecto_sqlite3, same
      # mechanism already used for the :array columns below.
      add :officials, :map, null: false, default: %{}
      # FIDE "Code of event" (FA1/IA1 B6, IT4 S4) — a federation-assigned
      # event code, not always numeric, kept separate from the tournament's
      # own FIDE report ID.
      add :event_code, :string, null: false, default: ""
      # FIDE "ID of Tournament" (IT3 B2) — the numeric tournament report ID
      # assigned once the report is filed. Kept as text since it's only ever
      # round-tripped into a report cell, never computed on.
      add :fide_tournament_id, :string, null: false, default: ""
    end

    alter table(:players) do
      # Per-player title-norm judgment data for the IT4 report (title
      # claimed, norm description, medal/%, remarks, event group, federation
      # counts) — see PairingsEngine.Tournaments.Player for recognised keys.
      # Left empty for players who aren't norm candidates.
      add :norm_data, :map, null: false, default: %{}
    end
  end
end
