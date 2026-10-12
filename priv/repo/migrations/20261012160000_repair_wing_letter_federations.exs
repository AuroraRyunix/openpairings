defmodule PairingsEngine.Repo.Migrations.RepairWingLetterFederations do
  use Ecto.Migration

  require Logger

  # The Belgian player list's `Fed` column is the member's wing inside
  # Belgium (V, F, D), not a country. From 2026-09-30 the player lookup and
  # the registration review copied it into a player's `federation`, which
  # is a FIDE country code everywhere else.
  #
  # Players with exactly such a letter AND a national ID get the federation
  # the local FIDE list has for their FIDE ID, else blank. Pending
  # registrations get the same inside their stored payload. Plain SQL on
  # purpose: a migration must not call code that may change. Safe with an
  # empty FIDE list (the subquery finds nothing, the field goes blank) and
  # safe to run twice (nothing matches the second time).
  def up do
    {players_sql, registrations_sql} = statements()

    players = repo().query!(players_sql)
    Logger.info("RepairWingLetterFederations: #{players.num_rows} player(s) repaired")

    registrations = repo().query!(registrations_sql)
    Logger.info("RepairWingLetterFederations: #{registrations.num_rows} registration(s) repaired")
  end

  def down, do: :ok

  @doc false
  # The two statements, apart from `up/0` so a test can run them without a
  # migration runner.
  def statements do
    {"""
     UPDATE players
        SET federation = COALESCE(
              NULLIF((SELECT f.federation FROM fide_players f WHERE f.fide_id = players.fide_id), ''),
              '')
      WHERE UPPER(TRIM(federation)) IN ('V', 'F', 'D')
        AND TRIM(COALESCE(national_id, '')) <> ''
     """,
     """
     UPDATE openresults_registrations
        SET payload = json_set(
              payload,
              '$.player.federation',
              COALESCE(
                (SELECT f.federation FROM fide_players f
                  WHERE f.fide_id = CAST(json_extract(openresults_registrations.payload, '$.player.fide_id') AS INTEGER)),
                ''))
      WHERE json_valid(payload)
        AND UPPER(TRIM(COALESCE(json_extract(payload, '$.player.federation'), ''))) IN ('V', 'F', 'D')
        AND TRIM(COALESCE(json_extract(payload, '$.player.national_id'), '')) <> ''
     """}
  end
end
