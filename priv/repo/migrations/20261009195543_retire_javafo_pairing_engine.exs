defmodule PairingsEngine.Repo.Migrations.RetireJavafoPairingEngine do
  @moduledoc """
  Retires `tournaments.pairing_engine`: Ainalrami is the only Swiss engine
  now, and a column with one permitted value is a column that asks a
  question nobody gets to answer.

  ## The tournaments that still said "javafo"

  Before the column goes, every individual Swiss tournament still set to
  JaVaFo gets one `tournament.pairing_engine_retired` row in its audit log,
  written by nobody (`user_id` NULL, which the Audit page shows as
  "System"). A tournament under way when this runs pairs its next round by
  Ainalrami - the 2026 edition of C.04.3 instead of the 2017 one its earlier
  rounds were paired by - and the arbiter did not choose that, so the trail
  says when it happened and how many rounds were already on the board.

  It is deliberately NOT a FIDE-compliance departure, and nothing here
  touches `fide_compliance_lost_round`: the switch is not an arbiter's act,
  and the rules it switches to are the ones in force. Round robin, Keizer
  and team events never read the column, so they get no row - a note that
  something changed which changed nothing would be noise.

  ## Down

  Puts the column back and re-reads which tournaments said "javafo" out of
  the audit rows `up/0` wrote, then removes those rows. The tournaments that
  were never logged (the ones that never read the column) come back as
  "ainalrami", which is as inert for them as "javafo" was.
  """
  use Ecto.Migration

  def up do
    execute """
    INSERT INTO audit_logs (tournament_id, user_id, action, details, inserted_at)
    SELECT t.id,
           NULL,
           'tournament.pairing_engine_retired',
           json_object(
             'from', 'javafo',
             'to', 'ainalrami',
             'rounds_paired', (SELECT COUNT(*) FROM rounds r WHERE r.tournament_id = t.id)
           ),
           strftime('%Y-%m-%dT%H:%M:%S', 'now')
    FROM tournaments t
    WHERE t.pairing_engine = 'javafo'
      AND t.pairing_system = 'swiss'
      AND t.type NOT IN ('team-swiss', 'team-roundrobin')
    """

    alter table(:tournaments) do
      remove :pairing_engine
    end
  end

  def down do
    alter table(:tournaments) do
      add :pairing_engine, :string, null: false, default: "ainalrami"
    end

    execute """
    UPDATE tournaments SET pairing_engine = 'javafo'
    WHERE id IN (SELECT tournament_id FROM audit_logs
                 WHERE action = 'tournament.pairing_engine_retired')
    """

    execute "DELETE FROM audit_logs WHERE action = 'tournament.pairing_engine_retired'"
  end
end
