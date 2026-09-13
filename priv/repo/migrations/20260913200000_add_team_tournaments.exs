defmodule PairingsEngine.Repo.Migrations.AddTeamTournaments do
  @moduledoc """
  What a team round robin needs on top of the scaffolding
  `20260709170320_create_core_tables.exs` already laid down (`teams`,
  `players.team_id`/`board_order`, `matches`, `pairings.match_id`). See
  `docs/team-tournaments.md`.

  On `teams`:

    * `short_name` - the label a pairing sheet has room for.
    * `seed` - the arbiter's order of the teams before the draw is frozen.
      Every existing row gets its id, which is creation order: nothing wrote
      teams before this, so there is nothing else to preserve.
    * `pairing_number` - the team's TPN (C.04.6 Art. 1.1), frozen when round 1
      is paired, exactly as `players.pairing_number` is for individuals.

  On `tournaments`:

    * `team_boards` - boards per match. 4 is the common club and league
      size, and it is only ever read for a team tournament.
    * `team_match_points_win/draw/loss` - C.07 Art. 11.1.1's match points,
      2/1/0 by default because that is what FIDE team events use; leagues
      that score 3/1/0 or 1/0.5/0 change them.

  Every new column has a default, so no individual tournament reads anything
  different after this runs.
  """
  use Ecto.Migration

  def up do
    alter table(:teams) do
      add :short_name, :string, null: false, default: ""
      add :seed, :integer
      add :pairing_number, :integer
    end

    alter table(:tournaments) do
      add :team_boards, :integer, null: false, default: 4
      add :team_match_points_win, :float, null: false, default: 2.0
      add :team_match_points_draw, :float, null: false, default: 1.0
      add :team_match_points_loss, :float, null: false, default: 0.0
    end

    flush()

    execute("UPDATE teams SET seed = id WHERE seed IS NULL")

    create_if_not_exists index(:matches, [:round_id])
    create_if_not_exists index(:pairings, [:match_id])
  end

  def down do
    drop_if_exists index(:pairings, [:match_id])
    drop_if_exists index(:matches, [:round_id])

    alter table(:tournaments) do
      remove :team_match_points_loss
      remove :team_match_points_draw
      remove :team_match_points_win
      remove :team_boards
    end

    alter table(:teams) do
      remove :pairing_number
      remove :seed
      remove :short_name
    end
  end
end
