defmodule PairingsEngine.Repo.Migrations.TrimPastedPlayerIds do
  use Ecto.Migration

  # The changeset trims ids from now on; this does the rows it never saw.
  # Tab, CR, LF and space, at either end - what a spreadsheet paste leaves.
  # Only rows that actually change are touched, so updated_at stays honest
  # for everyone else.
  @ws "' ' || char(9) || char(10) || char(13)"

  def up do
    execute("""
    UPDATE players
    SET national_id = trim(national_id, #{@ws})
    WHERE national_id IS NOT NULL AND national_id != trim(national_id, #{@ws})
    """)
  end

  def down, do: :ok
end
