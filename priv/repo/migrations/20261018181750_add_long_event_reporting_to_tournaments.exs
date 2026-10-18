defmodule PairingsEngine.Repo.Migrations.AddLongEventReportingToTournaments do
  @moduledoc """
  `tournaments.long_event_reporting`: how a tournament lasting more than 30
  days (`long_event`) is reported for rating. "monthly" - the default, and
  every tournament that exists - reports each month's rounds on their own
  (FIDE B.02 Art. 4.1). "end" is the club championship registered with FIDE
  once and reported once, all rounds in one file, counted from its last day
  like any short tournament (Art. 9.1).
  """
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      add :long_event_reporting, :string, null: false, default: "monthly"
    end
  end
end
