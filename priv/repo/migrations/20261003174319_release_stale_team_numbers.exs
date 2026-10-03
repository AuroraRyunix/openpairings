defmodule PairingsEngine.Repo.Migrations.ReleaseStaleTeamNumbers do
  @moduledoc """
  Gives back the pairing numbers a failed first pairing left on teams.

  A team event's teams are numbered when round 1 is paired, and the numbers
  are released again when the last round is unpaired. Until 0.73 a pairing
  that numbered the teams and then refused (too few teams, a team with
  nobody to field) kept the numbers although no round existed - which
  froze the Teams page's order and hid the Delete button of every team but
  the ones added afterwards. A tournament without a single round has no
  draw to keep, so its teams lose those numbers here; nothing else changes.
  """
  use Ecto.Migration

  def up do
    execute("""
    UPDATE teams SET pairing_number = NULL
    WHERE pairing_number IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM rounds r WHERE r.tournament_id = teams.tournament_id)
    """)
  end

  # Nothing to restore: the numbers stood for a draw that never happened.
  def down, do: :ok
end
