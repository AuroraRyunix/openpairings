defmodule PairingsEngine.Repo.Migrations.AddStandingsDataVersion do
  @moduledoc """
  `tournaments.data_version`: a value that changes, in the same transaction,
  with every write to the rows standings are computed from - the players,
  the rounds, their pairings, the byes. `PairingsEngine.StandingsCache` keys
  computed standings by it, so a cached table can never outlive the data it
  was computed from.

  Kept by triggers rather than by the code that writes, because the code
  that writes is everywhere: the Tournaments context, the pairing engines,
  every import, restore, the mobile result entry, raw `update_all`s. A
  trigger cannot be forgotten by the next write path somebody adds.

  A random 64-bit value rather than a counter. A counter bumped inside a
  transaction that is then rolled back comes back to a value it already
  had, with different data behind it the next time; a random value does
  not come back. The same holds across a tournament deleted and another
  created with its id. Nothing compares versions for order - only for
  equality.

  The tournament's own settings are not covered here on purpose: standings
  are computed from the `%Tournament{}` handed in, not from its row, and
  the cache keys by that struct as well.
  """
  use Ecto.Migration

  @child_tables ~w(players rounds byes)

  def up do
    alter table(:tournaments) do
      add :data_version, :integer, null: false, default: 0
    end

    execute "UPDATE tournaments SET data_version = random()"

    execute """
    CREATE TRIGGER tournaments_data_version_insert
    AFTER INSERT ON tournaments
    BEGIN
      UPDATE tournaments SET data_version = random() WHERE id = NEW.id;
    END
    """

    for table <- @child_tables do
      execute """
      CREATE TRIGGER #{table}_data_version_insert
      AFTER INSERT ON #{table}
      BEGIN
        UPDATE tournaments SET data_version = random() WHERE id = NEW.tournament_id;
      END
      """

      execute """
      CREATE TRIGGER #{table}_data_version_update
      AFTER UPDATE ON #{table}
      BEGIN
        UPDATE tournaments SET data_version = random()
        WHERE id IN (NEW.tournament_id, OLD.tournament_id);
      END
      """

      execute """
      CREATE TRIGGER #{table}_data_version_delete
      AFTER DELETE ON #{table}
      BEGIN
        UPDATE tournaments SET data_version = random() WHERE id = OLD.tournament_id;
      END
      """
    end

    # A pairing has no tournament of its own; its round does. A pairing
    # deleted along with its round finds no round any more, and the round's
    # own trigger has already changed the version.
    for {event, ref} <- [{"INSERT", "NEW"}, {"UPDATE", "NEW"}, {"DELETE", "OLD"}] do
      execute """
      CREATE TRIGGER pairings_data_version_#{String.downcase(event)}
      AFTER #{event} ON pairings
      BEGIN
        UPDATE tournaments SET data_version = random()
        WHERE id IN (SELECT tournament_id FROM rounds WHERE id = #{ref}.round_id)#{if event == "UPDATE", do: "\n           OR id IN (SELECT tournament_id FROM rounds WHERE id = OLD.round_id)", else: ""};
      END
      """
    end
  end

  def down do
    for table <- @child_tables ++ ["pairings"], event <- ~w(insert update delete) do
      execute "DROP TRIGGER IF EXISTS #{table}_data_version_#{event}"
    end

    execute "DROP TRIGGER IF EXISTS tournaments_data_version_insert"

    alter table(:tournaments) do
      remove :data_version
    end
  end
end
