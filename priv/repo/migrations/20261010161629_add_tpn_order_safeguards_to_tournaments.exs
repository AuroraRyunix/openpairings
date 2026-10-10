defmodule PairingsEngine.Repo.Migrations.AddTpnOrderSafeguardsToTournaments do
  @moduledoc """
  Three columns for a Swiss whose pairing numbers stopped following the
  ratings without anybody being told (C.04.2 2.2-2.4).

    * `tournaments.pairing_numbers_origin` - who put the numbers there when
      it was not the pairing: `"import"` (a TRF or SWAR file's own numbers)
      or `"exchange"` (an arbiter's TPN exchange). Null means the pairing
      issued them, and those are the only ones unpairing the last round
      takes back. Existing rows that came from a file - they carry a TRF
      import record or a SWAR guid - are marked `"import"`; the rest stay
      null, an exchange made before this existed being impossible to tell
      from the audit-free side of the database.
    * `tournaments.tpn_order_accepted` - the players out of place the
      arbiter chose to pair with anyway (their ids, sorted, comma-joined),
      so the question is asked once per set and not once per round.
    * `tournaments.late_entry_notice_dismissed` - the "late entrants are
      numbered at the end here" notice, answered.
  """
  use Ecto.Migration

  def up do
    alter table(:tournaments) do
      add :pairing_numbers_origin, :string
      add :tpn_order_accepted, :text
      add :late_entry_notice_dismissed, :boolean, null: false, default: false
    end

    flush()

    execute("""
    UPDATE tournaments SET pairing_numbers_origin = 'import'
    WHERE import_findings IS NOT NULL OR (swar_guid IS NOT NULL AND swar_guid != '')
    """)
  end

  def down do
    alter table(:tournaments) do
      remove :pairing_numbers_origin
      remove :tpn_order_accepted
      remove :late_entry_notice_dismissed
    end
  end
end
