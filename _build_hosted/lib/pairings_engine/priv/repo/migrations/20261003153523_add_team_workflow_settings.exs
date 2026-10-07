defmodule PairingsEngine.Repo.Migrations.AddTeamWorkflowSettings do
  @moduledoc """
  The team-tournament workflow settings and records (docs/team-tournaments.md).

  On `tournaments`, every column defaults to what the app did before it
  existed, so an existing tournament pairs, scores and exports exactly as it
  did:

    * `team_board_colours` - "fide" (the team named first in the pairing has
      White on the odd boards, the convention of FIDE team events) or "home"
      (league style: the home team has White on the odd boards, and the
      arbiter can swap home and away before a match starts).
    * `team_pab_match_points` / `team_pab_game_points` - a team Swiss
      pairing-allocated bye's value when the regulations say otherwise
      (C.04.6 Art. 1.4); nil is a drawn match's points, as before.
    * `team_withdrawal_annul` - a team round robin: a team that withdraws
      having played fewer than half its matches has those matches taken out
      of the team standings (FIDE General Regulations for Competitions 6.6).
      Off by default.

  On `teams`, `withdrawn_from_round` - the first round a withdrawn team does
  not play; nil for every team that has not withdrawn - and
  `withdrawal_player_ids`, the players that withdrawal withdrew (a JSON
  list), so reinstating the team brings back exactly those.

  On `players`, `team_history` - the teams a player was on before a move
  between teams after they had played (outside FIDE mode only), each with
  the last round they played for it, so the TRF report still lists them
  under the team they played for (a JSON list; empty for everybody else).

  On `matches`, `double_forfeit` - neither team turned up: both lose the
  match by forfeit. False for every existing match.
  """
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      add :team_board_colours, :string, null: false, default: "fide"
      add :team_pab_match_points, :float
      add :team_pab_game_points, :float
      add :team_withdrawal_annul, :boolean, null: false, default: false
    end

    alter table(:teams) do
      add :withdrawn_from_round, :integer
      add :withdrawal_player_ids, :text, null: false, default: "[]"
    end

    alter table(:players) do
      add :team_history, :text, null: false, default: "[]"
    end

    alter table(:matches) do
      add :double_forfeit, :boolean, null: false, default: false
    end
  end
end
