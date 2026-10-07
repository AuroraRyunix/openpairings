defmodule PairingsEngine.Repo.Migrations.DataVersionTriggerNamesNewRoundColumns do
  @moduledoc """
  Recreates `rounds_data_version_update` (see
  `DataVersionIgnoresRoundAccounts`) so it names the columns added to
  `rounds` since: `mpa_session` and `mpa_pibe` (`AddManualAlterationToRounds`)
  and `chess960_position` (`AddMiscVclColumns`). Without them, starting or
  finishing a manual pairing alteration or drawing a Chess960 position did
  not move `tournaments.data_version`, so a page could keep showing the round
  as it was.
  """
  use Ecto.Migration

  @added ~w(mpa_session mpa_pibe chess960_position)

  def up, do: create_trigger([])

  def down, do: create_trigger(@added)

  defp create_trigger(leave_out) do
    columns =
      repo().query!("PRAGMA table_info(rounds)").rows
      |> Enum.map(&Enum.at(&1, 1))
      |> Kernel.--(["explanation" | leave_out])

    execute "DROP TRIGGER IF EXISTS rounds_data_version_update"

    execute """
    CREATE TRIGGER rounds_data_version_update
    AFTER UPDATE ON rounds
    WHEN OLD."explanation" IS NEW."explanation"
      OR #{Enum.map_join(columns, "\n      OR ", &~s|OLD."#{&1}" IS NOT NEW."#{&1}"|)}
    BEGIN
      UPDATE tournaments SET data_version = random()
      WHERE id IN (NEW.tournament_id, OLD.tournament_id);
    END
    """
  end
end
