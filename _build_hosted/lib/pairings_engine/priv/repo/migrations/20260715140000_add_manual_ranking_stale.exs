defmodule PairingsEngine.Repo.Migrations.AddManualRankingStale do
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      # True once a result changes after the arbiter's hand-set order was
      # seeded: the order is still shown (never silently discarded) but every
      # banner must say it no longer reflects the current results. Cleared by
      # reseeding or by any explicit reorder - the arbiter acting on the list
      # is itself the confirmation.
      #
      # Staleness is tournament-level state, so it lives here rather than
      # being encoded into players.manual_rank: entering a result must not
      # rewrite every player row, and an indexed rank column that also smuggles
      # a boolean in its sign is a correctness trap for every future reader.
      add :manual_ranking_stale, :boolean, default: false, null: false
    end
  end
end
