defmodule PairingsEngine.Repo.Migrations.AddAskByeTypeToTournaments do
  @moduledoc """
  `tournaments.ask_bye_type`: "Ask the bye type for each absence". On, the
  player dialog asks for a round marked absent ahead of its pairing whether
  it is a half-point, zero-point or full-point bye, and stores the answer
  as the typed `byes` row (`PairingsEngine.ByeTypes`). Off - the default,
  and every tournament that exists - the absence value decides, as before.
  """
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      add :ask_bye_type, :boolean, null: false, default: false
    end
  end
end
