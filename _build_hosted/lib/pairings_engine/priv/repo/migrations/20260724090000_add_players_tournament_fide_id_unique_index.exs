defmodule PairingsEngine.Repo.Migrations.AddPlayersTournamentFideIdUniqueIndex do
  use Ecto.Migration

  def change do
    # FIDE-ID uniqueness within a tournament was previously "enforced" only
    # by a racy check-then-insert on create, and not at all on update (see
    # PairingsEngine.Tournaments.create_player/2 and update_player/2) - an
    # edited fide_id could silently collide with another player's. A real
    # partial unique index (fide_id is optional, so unrated/no-FIDE-ID
    # players must stay unconstrained) is the actual guarantee; the
    # changeset's unique_constraint/2 surfaces a friendly error on either
    # write path once this exists.
    #
    # Fails loudly (raises, migration aborts) rather than silently mutating
    # anyone's data if real dev/prod rows already violate this - resolve
    # any reported conflicts by hand before re-running the migration.
    execute(
      fn ->
        case repo().query!(
               "SELECT tournament_id, fide_id, COUNT(*) c FROM players " <>
                 "WHERE fide_id IS NOT NULL GROUP BY tournament_id, fide_id HAVING c > 1"
             ) do
          %{rows: []} ->
            :ok

          %{rows: rows} ->
            details =
              Enum.map_join(rows, "; ", fn [tid, fid, c] ->
                "tournament #{tid}, fide_id #{fid} (#{c} players)"
              end)

            raise """
            Cannot add a unique index on players(tournament_id, fide_id) - \
            existing duplicate rows found: #{details}. Resolve these \
            (edit/clear the duplicate fide_id on one of each pair) before \
            re-running this migration.
            """
        end
      end,
      fn -> :ok end
    )

    create unique_index(:players, [:tournament_id, :fide_id], where: "fide_id IS NOT NULL")
  end
end
