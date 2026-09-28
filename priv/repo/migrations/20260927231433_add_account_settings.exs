defmodule PairingsEngine.Repo.Migrations.AddAccountSettings do
  use Ecto.Migration

  # The account page's own state (see `PairingsEngineWeb.UserLive.Settings`
  # and docs/account.md).
  #
  # Every new `users` column is NULLABLE and NULL means "not set": no display
  # name (the address is shown), no stored language (the browser's is used),
  # no stored theme or accent (each device keeps its own). That is also what
  # every existing row becomes, so this migration changes nothing anybody
  # sees until they choose something.
  #
  # `tournament_defaults` is a JSON map (`PairingsEngine.Accounts.TournamentDefaults`),
  # not a column per field: the set of fields a new tournament can be
  # pre-filled with will grow, and a column each would be a migration each.
  #
  # `users_tokens.user_agent` is what lets the "Where you're signed in" list
  # say which device a session belongs to. Only the browser's own
  # description, truncated - never the address it connected from.
  def change do
    alter table(:users) do
      add :display_name, :string
      add :locale, :string
      add :theme, :string
      add :accent, :string
      add :tournament_defaults, :map
    end

    alter table(:users_tokens) do
      add :user_agent, :string
    end
  end
end
