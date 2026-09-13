defmodule PairingsEngine.Tournaments.Match do
  @moduledoc """
  One team match in a round: `team_a` against `team_b`, played over the
  round's board pairings that carry this match's id.

  `board` is the MATCH number within the round (the table group), not a
  chess board. The chess boards are the `pairings` rows, numbered
  continuously across the round: match `m` owns boards
  `(m - 1) * team_boards + 1 .. m * team_boards`, so the round's existing
  board list, result entry and printing keep working unchanged.

  `team_a` is the team the schedule named first. It has White on board 1 and
  on every odd board; see `PairingsEngine.TeamRoundRobin` for the convention.

  A match with no `team_b` is the round's bye: in an odd-sized team round
  robin no boards and no points, in a team Swiss the pairing-allocated bye.

  `forfeited_to_team_id` is set when the arbiter forfeited the match by
  decision (`Tournaments.forfeit_match/3`), and `forfeit_previous_results`
  keeps the board results from before that decision, keyed by board number,
  so it can be withdrawn. Both nil for a match decided on its boards.
  """
  use Ecto.Schema

  schema "matches" do
    field :board, :integer
    field :forfeit_previous_results, :map

    belongs_to :round, PairingsEngine.Tournaments.Round
    belongs_to :team_a, PairingsEngine.Tournaments.Team
    belongs_to :team_b, PairingsEngine.Tournaments.Team
    belongs_to :forfeited_to_team, PairingsEngine.Tournaments.Team
  end
end
