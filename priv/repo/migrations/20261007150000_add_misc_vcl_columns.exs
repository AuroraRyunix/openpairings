defmodule PairingsEngine.Repo.Migrations.AddMiscVclColumns do
  @moduledoc """
  `tournaments.tiebreak_unrated_method` - how a player without a rating is
  counted in the rating-based tie-breaks ("fixed": the stored rating, nothing
  when it is empty; "lowest": the lowest rating in the field; "average": the
  average rating of the rated players), `tournaments.lots_seed` - the seed of
  the one drawing of lots a tournament has, `tournaments.chess960` - whether
  the arbiter draws a Chess960 starting position per round,
  `rounds.chess960_position` - the position (0..959) drawn for the round, and
  `players.external_tiebreak` - a tie-break value calculated outside the
  program. Every existing tournament behaves as before.
  """
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      add :tiebreak_unrated_method, :string, null: false, default: "fixed"
      add :lots_seed, :integer
      add :chess960, :boolean, null: false, default: false
    end

    alter table(:rounds) do
      add :chess960_position, :integer
    end

    alter table(:players) do
      add :external_tiebreak, :float
    end
  end
end
