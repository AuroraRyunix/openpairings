defmodule PairingsEngine.Repo.Migrations.CreateTrfSentGames do
  @moduledoc """
  The record of what went to the federation in a TRF marked as sent
  (`PairingsEngine.PostponedGames`, "the sent-games record").

  The marks on `pairings` (`finalised_at`, `finalised_open`,
  `postponed_reported_at`) live with the tournament's contents, and a
  snapshot restore or a hand-off return replaces those contents wholesale.
  What was sent is not content: it is a fact about a file that has left the
  building, and rolling the tournament back must not forget it, or the same
  round could be sent a second time. So it is kept here, beside the audit
  trail, which a restore does not touch either; one row per game (or bye)
  per file it went out in.

    * `round` - the round number the game was paired in.
    * `white_key` / `black_key` - who played, as the file names them: FIDE
      ID, or the name when there is none (`PostponedGames.player_key/1`).
      Player rows are recreated by a restore, so their ids cannot be used.
    * `kind` - `"report"` (the round's own report) or `"postponed"` (the
      postponed-games file).
    * `sent_as` - the result the file carried: `"?"` for a game still open
      then, otherwise the stored result code.

  A new table, dropped on rollback; nothing existing changes.
  """
  use Ecto.Migration

  def change do
    create table(:trf_sent_games) do
      add :tournament_id, references(:tournaments, on_delete: :delete_all), null: false
      add :round, :integer, null: false
      add :white_key, :string
      add :black_key, :string
      add :kind, :string, null: false
      add :sent_as, :string, null: false
      add :sent_at, :utc_datetime, null: false
    end

    create index(:trf_sent_games, [:tournament_id, :round])
  end
end
