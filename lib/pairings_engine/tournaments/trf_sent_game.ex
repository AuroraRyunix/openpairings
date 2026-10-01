defmodule PairingsEngine.Tournaments.TrfSentGame do
  @moduledoc """
  One game (or bye) that went to the federation in a TRF marked as sent. See
  the migration and `PairingsEngine.PostponedGames` for why it is kept apart
  from the pairings it describes: a restore replaces those, never this.
  """
  use Ecto.Schema

  schema "trf_sent_games" do
    field :round, :integer
    field :white_key, :string
    field :black_key, :string
    field :kind, :string
    field :sent_as, :string
    field :sent_at, :utc_datetime
    # The board's `game_uid` (nil for a record older than it whose game
    # could not be told apart), and where the record came from: `"sent"`
    # from this installation, otherwise a copy of the tournament that sent
    # it (`"handoff"`, `"import"`, `"copy"`). One `"sent"` record per game
    # per kind is a unique index - the guard against two sends racing.
    field :game_uid, :string
    field :origin, :string, default: "sent"

    belongs_to :tournament, PairingsEngine.Tournaments.Tournament
  end
end
