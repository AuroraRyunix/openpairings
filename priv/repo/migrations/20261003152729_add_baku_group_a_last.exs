defmodule PairingsEngine.Repo.Migrations.AddBakuGroupALast do
  @moduledoc """
  `tournaments.baku_group_a_last`: the pairing number of the last Group-A
  player of a Baku-accelerated Swiss (FIDE C.04.7), fixed when round 1 is
  paired.

  Group A used to be worked out afresh every time - `2 * ceil(N/4)` over
  whoever held a pairing number at that moment - so a late entrant, who is
  numbered when they join, made it grow part-way through the event, and
  every TRF exported afterwards wrote the bigger Group A into every round's
  `250` records. C.04.7 1.2 decides Group A before round 1 and 1.3.2 keeps
  its last member for the rest of the event.

  The backfill gives every Baku Swiss that has a round 1 the Group A of its
  round-1 field: the players numbered up to the highest number that sat at
  a board, took a bye or was recorded absent in round 1 (late entrants are
  numbered after all of them). The one player this cannot see is somebody
  registered before round 1 with a later start round who was numbered after
  everybody who appeared in round 1 - they did count towards the size when
  round 1 was paired. A tournament whose round 1 has nobody in it at all
  (nothing derivable) keeps today's computation over the whole numbered
  roster. Rounds already paired are not touched either way.

  Reversible: `down` drops the column.
  """
  use Ecto.Migration

  def up do
    alter table(:tournaments) do
      add :baku_group_a_last, :integer
    end

    flush()

    backfill(fn sql, params -> repo().query!(sql, params) end)
  end

  def down do
    alter table(:tournaments) do
      remove :baku_group_a_last
    end
  end

  @doc """
  The backfill, given a `query!/2`-shaped function - public so
  `test/pairings_engine/baku_group_a_migration_test.exs` runs exactly this
  code against rows of its own.
  """
  def backfill(query) do
    %{rows: rows} =
      query.(
        """
        SELECT t.id FROM tournaments t
         WHERE t.acceleration = 'baku' AND t.pairing_system = 'swiss'
           AND t.baku_group_a_last IS NULL
           AND EXISTS (SELECT 1 FROM rounds r WHERE r.tournament_id = t.id AND r.number = 1)
        """,
        []
      )

    for [id] <- rows do
      case group_a_last(query, id) do
        nil -> :ok
        last -> query.("UPDATE tournaments SET baku_group_a_last = ?1 WHERE id = ?2", [last, id])
      end
    end

    :ok
  end

  defp group_a_last(query, id) do
    %{rows: [[round_one_max]]} =
      query.(
        """
        SELECT MAX(p.pairing_number) FROM players p
         WHERE p.tournament_id = ?1 AND p.pairing_number IS NOT NULL
           AND (p.id IN (SELECT g.white_player_id FROM pairings g
                           JOIN rounds r ON r.id = g.round_id
                          WHERE r.tournament_id = ?1 AND r.number = 1)
             OR p.id IN (SELECT g.black_player_id FROM pairings g
                           JOIN rounds r ON r.id = g.round_id
                          WHERE r.tournament_id = ?1 AND r.number = 1)
             OR p.id IN (SELECT b.player_id FROM byes b
                          WHERE b.tournament_id = ?1 AND b.round = 1))
        """,
        [id]
      )

    %{rows: numbers} =
      query.(
        """
        SELECT pairing_number FROM players
         WHERE tournament_id = ?1 AND pairing_number IS NOT NULL
           AND (?2 IS NULL OR pairing_number <= ?2)
         ORDER BY pairing_number
        """,
        [id, round_one_max]
      )

    case List.flatten(numbers) do
      [] -> nil
      numbers -> Enum.at(numbers, min(2 * div(length(numbers) + 3, 4), length(numbers)) - 1)
    end
  end
end
