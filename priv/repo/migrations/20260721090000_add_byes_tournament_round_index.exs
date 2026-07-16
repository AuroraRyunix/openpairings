defmodule PairingsEngine.Repo.Migrations.AddByesTournamentRoundIndex do
  use Ecto.Migration

  def change do
    # Every query against "byes" filters by tournament_id, sometimes also by
    # round (PairingsEngine.Pairing.games_per_player/2,
    # PairingsEngine.Tournaments.list_byes_for_round/2,
    # PairingsEngine.Standings.byes_by_player_round/2) — only the existing
    # unique_index(:byes, [:player_id, :round]) exists, so every one of
    # those does a full table scan. A composite (tournament_id, round)
    # index serves both the tournament_id-only queries (leading-column
    # prefix) and the tournament_id+round queries.
    create index(:byes, [:tournament_id, :round])
  end
end
