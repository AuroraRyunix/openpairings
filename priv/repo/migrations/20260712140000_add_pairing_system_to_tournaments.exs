defmodule PairingsEngine.Repo.Migrations.AddPairingSystemToTournaments do
  use Ecto.Migration

  # Introduces the per-tournament pairing-engine selector: which engine
  # `PairingsEngine.Pairing.pair_next_round/1` dispatches to (see that
  # module and `PairingsEngine.RoundRobin` / `PairingsEngine.Keizer`).
  # Deliberately independent of the existing `tournaments.type` column
  # (individual/team + FIDE report classification, used for TRF export and
  # default tiebreaks) - `pairing_system` only controls which pairing
  # engine actually runs.
  def change do
    alter table(:tournaments) do
      add :pairing_system, :string, null: false, default: "swiss"
      # Round-robin only: 1 = single cycle (Berger), 2 = double (each pair
      # meets twice, colours reversed).
      add :rr_cycles, :integer, null: false, default: 1
      # Keizer only: the "top" cutoff value players play down to. Nil means
      # automatic (2 x player count) - computed by PairingsEngine.Keizer
      # once it exists, not stored until an organiser overrides it.
      add :keizer_top_value, :integer
    end
  end
end
