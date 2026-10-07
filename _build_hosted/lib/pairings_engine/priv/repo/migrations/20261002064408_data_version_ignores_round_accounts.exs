defmodule PairingsEngine.Repo.Migrations.DataVersionIgnoresRoundAccounts do
  @moduledoc """
  `tournaments.data_version` (see `AddStandingsDataVersion`) no longer moves
  when the only thing written to a round is its engine account,
  `rounds.explanation`.

  The account is commentary - standings, the next round's pairing and the
  Pairings page are computed without it - but it is written AFTER the round
  is saved, by a background job (`PairingsEngine.ExplanationJobs`), and
  then again for each question somebody opens on the explanation page. Each
  of those writes moved the version, so every pairing threw the freshly
  computed standings away a second time, and the Pairings page could not
  tell its own "Pair round" broadcast from somebody else's write (it skips
  the reload only while the version is the one it last read).

  The trigger still fires for any update that changes any other column of
  the round, with or without its account. The columns are read from the
  table as it is when this runs; a later migration that adds a column to
  `rounds` recreates this trigger - `data_version_test.exs` fails until it
  does.
  """
  use Ecto.Migration

  def up do
    columns =
      repo().query!("PRAGMA table_info(rounds)").rows
      |> Enum.map(&Enum.at(&1, 1))
      |> Kernel.--(["explanation"])

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

  def down do
    execute "DROP TRIGGER IF EXISTS rounds_data_version_update"

    execute """
    CREATE TRIGGER rounds_data_version_update
    AFTER UPDATE ON rounds
    BEGIN
      UPDATE tournaments SET data_version = random()
      WHERE id IN (NEW.tournament_id, OLD.tournament_id);
    END
    """
  end
end
