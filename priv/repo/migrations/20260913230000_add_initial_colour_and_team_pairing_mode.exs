defmodule PairingsEngine.Repo.Migrations.AddInitialColourAndTeamPairingMode do
  @moduledoc """
  Two per-tournament settings for Swiss pairing.

  On `tournaments`:

    * `initial_colour` - "lot" (the default), "white" or "black". C.04.3
      Art. 5.1 and C.04.6 Art. 4.1 both say the initial colour is "determined
      by drawing of lots before the pairing of the first round"; the arbiter
      can also set it. Every existing row gets "lot".
    * `initial_colour_drawn` - "white" or "black" once the lot has been drawn
      at the first pairing, nil before. Every existing row stays nil: a
      tournament that already paired round 1 is left exactly as it is (its
      engine keeps reading the colour off the rounds on the board, as it
      always has), and one that has not will draw when it does.
    * `team_pairing_mode` - for a Swiss (teams) tournament: "teams" when its
      rounds are paired team against team (C.04.6), "players" when they were
      paired player by player, nil while nothing is paired. Every team Swiss
      that already has a round was paired player by player - nothing else
      could pair one before this - so those get "players" and keep that
      path; the rest get nil and pair by teams from their first round.
  """
  use Ecto.Migration

  def up do
    alter table(:tournaments) do
      add :initial_colour, :string, null: false, default: "lot"
      add :initial_colour_drawn, :string
      add :team_pairing_mode, :string
    end

    flush()

    execute("""
    UPDATE tournaments SET team_pairing_mode = 'players'
    WHERE type = 'team-swiss'
      AND EXISTS (SELECT 1 FROM rounds r WHERE r.tournament_id = tournaments.id)
    """)
  end

  def down do
    alter table(:tournaments) do
      remove :team_pairing_mode
      remove :initial_colour_drawn
      remove :initial_colour
    end
  end
end
