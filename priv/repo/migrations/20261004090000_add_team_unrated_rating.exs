defmodule PairingsEngine.Repo.Migrations.AddTeamUnratedRating do
  @moduledoc """
  `tournaments.team_unrated_rating` - what a player without a rating, and a
  board nobody sits at, count as in a team's rating: 1400, the FIDE rating
  floor, for every existing row (docs/team-tournaments.md, "Team rating").
  No stored seed changes by itself.
  """
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      add :team_unrated_rating, :integer, null: false, default: 1400
    end
  end
end
