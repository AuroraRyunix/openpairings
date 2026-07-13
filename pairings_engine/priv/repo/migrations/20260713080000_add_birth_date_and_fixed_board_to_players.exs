defmodule PairingsEngine.Repo.Migrations.AddBirthDateAndFixedBoardToPlayers do
  use Ecto.Migration

  # birth_date: full date of birth (TRF player lines want YYYY/MM/DD; we only
  # stored birth_year, which forced "1975/00/00" into exports). birth_year
  # stays as the fallback for players where only the year is known.
  #
  # fixed_board: the physical table this player's games are shown at
  # (SWAR's "special table"), nil = normal board numbering.
  def change do
    alter table(:players) do
      add :birth_date, :date
      add :fixed_board, :integer
    end
  end
end
