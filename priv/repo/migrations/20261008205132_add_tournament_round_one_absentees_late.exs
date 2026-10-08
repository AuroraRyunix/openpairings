defmodule PairingsEngine.Repo.Migrations.AddTournamentRoundOneAbsenteesLate do
  @moduledoc """
  `tournaments.round_one_absentees_late` - whether a Swiss treats a player
  absent from round 1 as a late entry (C.04.2 2.4): no pairing number at
  round 1, numbered on arrival under `late_entry_numbering`.

  Every row that exists gets `false`: those tournaments numbered their
  round-1 absentees with the field, and renumbering an event under way
  because the software learned a rule is not a favour to anybody. The app
  sets it on the tournaments it creates from now on
  (`Tournaments.create_tournament/1,2`). Baku events did this already and
  keep doing it whatever the column says.
  """
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      add :round_one_absentees_late, :boolean, null: false, default: false
    end
  end
end
