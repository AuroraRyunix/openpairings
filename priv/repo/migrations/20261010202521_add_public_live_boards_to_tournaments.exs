defmodule PairingsEngine.Repo.Migrations.AddPublicLiveBoardsToTournaments do
  @moduledoc """
  `tournaments.public_live_boards` - the arbiter's word that this tournament
  has live boards (a relay in the hall sending the moves to the results
  site). Off for every existing tournament: nobody had a way to say yes
  before today, so nobody did.
  """
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      add :public_live_boards, :boolean, null: false, default: false
    end
  end
end
