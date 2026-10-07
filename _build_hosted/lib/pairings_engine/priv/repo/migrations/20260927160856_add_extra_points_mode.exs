defmodule PairingsEngine.Repo.Migrations.AddExtraPointsMode do
  @moduledoc """
  Two kinds of extra points (docs/extra-points.md).

    * `tournaments.extra_points_mode` - "handicap" (the extra points are a
      head start: the Elo bands pay players BELOW a rating, and the points
      count - in the standings and in the pairing score - only while
      `count_extra_points` is on) or "acceleration" (SWAR's XtraPoints: the
      bands pay players AT OR ABOVE a rating, the points always go to the
      pairing engine as virtual points, and `count_extra_points` decides
      whether they also stay in the standings).
    * `rounds.virtual_points` - the extra points each player was paired with
      in that round, `%{"player id" => points}`, non-zero entries only. The
      pairing engine needs every round's value, not only the current one
      (`XXA` is a per-round history), and a player's extra points can change
      between rounds - SWAR's "remove half a point" - so what a round was
      paired with is recorded when it is paired. Nil for every round that
      existed before this column: those rounds read the player's current
      extra points instead (`PairingsEngine.Pairing.accelerations/3`).

  Existing rows: a tournament that came from SWAR and uses extra points
  becomes "acceleration", which is what SWAR did with them; every other
  tournament stays "handicap", the old meaning. "Came from SWAR" is a SWAR
  guid or SWAR's own settings, with no Elo bands of this app's own: the
  export gives a native tournament a guid too, but the SWAR import never
  writes `extra_points_bands`, so a tournament with bands set here is a
  handicap event whatever else it carries. "Uses extra points" is the
  toggle being on or any player holding some.
  """
  use Ecto.Migration

  def up do
    alter table(:tournaments) do
      add :extra_points_mode, :string, null: false, default: "handicap"
    end

    alter table(:rounds) do
      add :virtual_points, :map
    end

    flush()

    execute(backfill_sql())
  end

  @doc """
  The one statement that decides the rows already there - public so
  `test/pairings_engine/extra_points_mode_migration_test.exs` runs exactly
  this text against rows of its own.
  """
  def backfill_sql do
    """
    UPDATE tournaments
       SET extra_points_mode = 'acceleration'
     WHERE ((swar_guid IS NOT NULL AND swar_guid <> '')
            OR (swar_settings IS NOT NULL AND swar_settings NOT IN ('', '{}')))
       AND (extra_points_bands IS NULL OR extra_points_bands = '')
       AND (count_extra_points = 1
            OR EXISTS (SELECT 1 FROM players p
                        WHERE p.tournament_id = tournaments.id
                          AND p.extra_points IS NOT NULL
                          AND p.extra_points <> 0))
    """
  end

  def down do
    alter table(:rounds) do
      remove :virtual_points
    end

    alter table(:tournaments) do
      remove :extra_points_mode
    end
  end
end
