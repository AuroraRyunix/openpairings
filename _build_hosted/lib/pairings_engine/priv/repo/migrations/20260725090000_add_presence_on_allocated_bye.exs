defmodule PairingsEngine.Repo.Migrations.AddPresenceOnAllocatedBye do
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      # SWAR `SW321_PreBye` (manual §5.16, file version >= v6.03), documented
      # as "Add presence points for bye games": when a 3-2-1 club turns it
      # on, a pairing-allocated bye pays `presence_value` ON TOP of
      # `bye_value` (SW321_Bye + SW321_Pre), instead of `bye_value` alone.
      # Modelled as a flag consulted by `PairingsEngine.Standings.bye_points/2`
      # rather than folded into `bye_value` at import time, so `bye_value`
      # keeps meaning exactly what the club configured as SW321_Bye and the
      # two concepts stay separately visible/editable. Default false + NOT
      # NULL: every existing and non-SWAR-3-2-1 tournament must keep scoring
      # byte-identically to before this field existed. Only
      # PairingsEngine.SwarImport sets it true (type == 3 files only).
      add :presence_on_allocated_bye, :boolean, default: false, null: false
    end
  end
end
