defmodule PairingsEngine.Repo.Migrations.AddNormEventTypeToTournaments do
  @moduledoc """
  `tournaments.norm_event_type` - which kind of event the FIDE Title
  Regulations (B.01) see this tournament as, for the game-count concessions
  of 1.4.1 (b) and the federation-mix exemptions of 1.4.3 (a)-(c).
  "ordinary" for every existing row, which is exactly how norms were judged
  before the column existed.
  """
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      add :norm_event_type, :string, null: false, default: "ordinary"
    end
  end
end
