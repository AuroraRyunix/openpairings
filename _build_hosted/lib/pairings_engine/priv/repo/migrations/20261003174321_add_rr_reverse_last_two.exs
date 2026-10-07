defmodule PairingsEngine.Repo.Migrations.AddRrReverseLastTwo do
  @moduledoc """
  `tournaments.rr_reverse_last_two`: a double round robin plays the last
  two rounds of its first cycle in reverse order - FIDE C.05 Annex 1's
  recommendation, so nobody has the same colour three times running across
  the cycle boundary (FIDE_DOUBLEROUNDROBIN in TRF26's type table).

  False for every existing tournament, so a round robin already under way
  keeps exactly the schedule it was paired from.
  """
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      add :rr_reverse_last_two, :boolean, null: false, default: false
    end
  end
end
