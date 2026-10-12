defmodule PairingsEngine.Repo.Migrations.AddRewrittenToBoardGames do
  use Ecto.Migration

  # The third thing a box can say about a move it did not simply see: it
  # read the move, and later read the board in a way that proved the move
  # had been another one (a pawn set down between two squares). Counted
  # beside `reconstructed` and `guessed`, which it is neither of.
  def change do
    alter table(:board_games) do
      add :rewritten, :integer, null: false, default: 0
    end
  end
end
