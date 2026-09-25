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

    belongs_to :tournament, PairingsEngine.Tournaments.Tournament
  end
end
