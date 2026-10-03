defmodule PairingsEngine.Repo.Migrations.AddTeamLineupsAndRating do
  @moduledoc """
  Team events without players, and the team rating that seeds them
  (docs/team-tournaments.md, "Line-ups optional" and "Team rating").

  On `tournaments`:

    * `team_lineups` - "required" (a team plays only with players on its
      roster, as before; every existing row) or "optional" (a team plays
      whether or not it has players: every match gets all its boards, empty
      seats included, and results go on the boards or on the match);
    * `team_rating_method` - how a team's rating is worked out for seeding:
      "olympiad" (the Olympiad Pairing Rules' average of the highest-rated
      players), "first_boards", "roster" or "manual". Seeding matters only
      before round 1 and no stored seed is touched here, so "olympiad" for
      every row reorders nothing already set;
    * `teams_ordered_by_hand` - the arbiter has moved a team by hand, so
      pairing round 1 keeps the order instead of seeding by rating. Set for
      every tournament that already has teams: their order, whatever made
      it, is kept exactly as it is.

  On `teams`, `rating_override` - a rating typed for the team (nil for every
  existing team) - and `absent_rounds`, the rounds the team as a whole does
  not play (a JSON list, empty for every existing team).

  On `matches`, `match_score_a` / `match_score_b` - a match decided by its
  score alone, the score as entered (nil for every existing match).
  """
  use Ecto.Migration

  def up do
    alter table(:tournaments) do
      add :team_lineups, :string, null: false, default: "required"
      add :team_rating_method, :string, null: false, default: "olympiad"
      add :teams_ordered_by_hand, :boolean, null: false, default: false
    end

    alter table(:teams) do
      add :rating_override, :integer
      add :absent_rounds, :text, null: false, default: "[]"
    end

    alter table(:matches) do
      add :match_score_a, :float
      add :match_score_b, :float
    end

    flush()

    execute """
    UPDATE tournaments SET teams_ordered_by_hand = 1
    WHERE id IN (SELECT DISTINCT tournament_id FROM teams)
    """
  end

  def down do
    alter table(:matches) do
      remove :match_score_a
      remove :match_score_b
    end

    alter table(:teams) do
      remove :rating_override
      remove :absent_rounds
    end

    alter table(:tournaments) do
      remove :team_lineups
      remove :team_rating_method
      remove :teams_ordered_by_hand
    end
  end
end
