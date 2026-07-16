defmodule PairingsEngine.Repo.Migrations.AddRrMatchFormat do
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      # Round-robin "match format": round N/N+1 are the same pairing,
      # colours reversed, played back-to-back — see the field's doc
      # comment on PairingsEngine.Tournaments.Tournament and
      # PairingsEngine.RoundRobin.match_schedule/2. Distinct from, and
      # currently mutually exclusive with, rr_cycles == 2.
      add :rr_match_format, :boolean, default: false, null: false
    end
  end
end
