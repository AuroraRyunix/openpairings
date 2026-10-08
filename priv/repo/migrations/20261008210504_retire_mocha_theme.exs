defmodule PairingsEngine.Repo.Migrations.RetireMochaTheme do
  use Ecto.Migration

  # Mocha is gone from the palette. An account that still names it would
  # fail its own settings form the next time it saved anything, so it goes
  # back to "each device decides", which is where a removed theme leaves
  # everybody anyway.
  def up do
    execute("UPDATE users SET theme = NULL WHERE theme IN ('mocha', 'catppuccin')")
  end

  def down, do: :ok
end
