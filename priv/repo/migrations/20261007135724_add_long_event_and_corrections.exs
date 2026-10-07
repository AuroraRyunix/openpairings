defmodule PairingsEngine.Repo.Migrations.AddLongEventAndCorrections do
  @moduledoc """
  A tournament lasting more than 30 days, and what a final TRF needs to
  reflect everything that happened (VCL4THP Q210-Q217):

    * `tournaments.long_event` - the event spans more than one rating
      period, so a player may hold more than one rating during it. Off for
      every existing tournament.
    * `tournaments.tiebreak_rating_round` - which of those ratings the
      rating-based tie-breaks use: the one valid in this round. Nil is the
      first (C.07 Article 10's default).
    * `players.period_ratings` - a player's later ratings, each with the
      first round it applies to (a JSON list; empty for everybody).
    * `pairings.corrected_from` - the result a board had before it was
      corrected after a later round was paired (a Correction PIBE); nil for
      every board never corrected.
    * `forbidden_pairings.from_round` - the first round a prohibition
      applies to, when it was added after rounds were paired; nil is every
      round, as before.
  """
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      add :long_event, :boolean, null: false, default: false
      add :tiebreak_rating_round, :integer
    end

    alter table(:players) do
      add :period_ratings, :text, null: false, default: "[]"
    end

    alter table(:pairings) do
      add :corrected_from, :string
    end

    alter table(:forbidden_pairings) do
      add :from_round, :integer
    end
  end
end
