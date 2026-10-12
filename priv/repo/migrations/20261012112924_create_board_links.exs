defmodule PairingsEngine.Repo.Migrations.CreateBoardLinks do
  @moduledoc """
  The link with a hall box that reads electronic boards
  (`PairingsEngine.BoardLink`, docs/board-link-api.md).

  `board_links` - one row per connect code. A code is for one tournament or
  for one tournament group, never both and never neither. Only a SHA-256 of
  the secret is kept: the box presents the secret, this side has nothing to
  hand back, so there is nothing to keep readable. The rest of the row is
  what the box said about itself the last time it called.

  `board_games` - what a board reported about one game: moves, clocks, the
  result the board saw. Keyed by `pairings.game_uid`, not by the pairing's
  row id and not by a foreign key: a restore point rebuilds every pairing
  under a new id and the same `game_uid`, and a game that was played is not
  less played for that. A game whose pairing is gone for good is an orphan
  nothing reads; it leaves with the tournament.

  `tournaments.openresults_relay_key` - the results site's relay key for
  this tournament, typed in once so the box receives it over the link. It
  has to be readable: it is handed on, not checked.
  """
  use Ecto.Migration

  def change do
    create table(:board_links) do
      add :tournament_id, references(:tournaments, on_delete: :delete_all)
      add :group_id, references(:tournament_groups, on_delete: :delete_all)
      add :created_by_id, references(:users, on_delete: :nilify_all)
      add :secret_hash, :string, null: false
      add :secret_hint, :string, null: false
      add :last_seen_at, :utc_datetime
      add :box_name, :string
      add :box_version, :string
      add :box_boards, :map

      timestamps(type: :utc_datetime)
    end

    create unique_index(:board_links, [:secret_hash])
    create index(:board_links, [:tournament_id])
    create index(:board_links, [:group_id])

    create table(:board_games) do
      add :tournament_id, references(:tournaments, on_delete: :delete_all), null: false
      add :game_uid, :string, null: false
      add :seq, :integer, null: false, default: 0
      add :status, :string, null: false, default: "live"
      add :result, :string
      add :moves, {:array, :string}, null: false, default: []
      add :move_clocks, {:array, :integer}, null: false, default: []
      add :white_ms, :integer
      add :black_ms, :integer
      add :running, :string
      add :start_fen, :string
      add :pgn, :text
      add :reconstructed, :integer, null: false, default: 0
      add :guessed, :integer, null: false, default: 0
      add :link_id, references(:board_links, on_delete: :nilify_all)
      add :first_reported_at, :utc_datetime
      add :reported_at, :utc_datetime
      add :finished_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:board_games, [:tournament_id, :game_uid])

    alter table(:tournaments) do
      add :openresults_relay_key, :string
    end
  end
end
