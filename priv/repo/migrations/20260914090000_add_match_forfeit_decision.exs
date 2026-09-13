defmodule PairingsEngine.Repo.Migrations.AddMatchForfeitDecision do
  @moduledoc """
  A team match forfeited by an arbiter's decision (`Tournaments.forfeit_match/3`).

    * `forfeited_to_team_id` - the team the match was awarded to; nil for
      every match decided on its boards, which is every existing row.
    * `forfeit_previous_results` - the board results as they stood before
      the decision, keyed by board number, so the decision can be withdrawn
      and the boards come back exactly as they were. It also tells a match
      in which games were played before the decision from one nobody sat
      down to. See `docs/team-tournaments.md`.
  """
  use Ecto.Migration

  def change do
    alter table(:matches) do
      add :forfeited_to_team_id, references(:teams, on_delete: :nilify_all)
      add :forfeit_previous_results, :map
    end
  end
end
