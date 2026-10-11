defmodule PairingsEngine.Repo.Migrations.AddTeamForfeitBoardPoints do
  @moduledoc """
  `tournaments.team_forfeit_board_points`: what a match awarded as a whole -
  forfeited by decision before a game was played, or against a team out of
  the round - pays the winner in game points.

    * "seated" - a point per board the winner filled. What the app has
      always done, and the default for every existing and new tournament.
    * "full" - the full board count, whatever the winner seated. For leagues
      whose regulations fix the score of a team forfeit (8-0 on eight
      boards), which is most of the ones that bother to write it down.
  """
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      add :team_forfeit_board_points, :string, null: false, default: "seated"
    end
  end
end
