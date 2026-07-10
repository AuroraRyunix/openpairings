defmodule PairingsEngine.Tournaments.Pairing do
  use Ecto.Schema
  import Ecto.Changeset

  # Results as shown to the arbiter; forfeits use +/- notation, byes are
  # stored as a pairing with no black player.
  @results ["", "1-0", "1/2-1/2", "0-1", "+--", "--+", "0-0", "bye"]

  schema "pairings" do
    field :board, :integer
    field :result, :string, default: ""
    field :match_id, :integer

    belongs_to :round, PairingsEngine.Tournaments.Round
    belongs_to :white_player, PairingsEngine.Tournaments.Player
    belongs_to :black_player, PairingsEngine.Tournaments.Player
  end

  def changeset(pairing, attrs) do
    pairing
    |> cast(attrs, [:board, :result, :white_player_id, :black_player_id, :match_id])
    |> validate_required([:board])
    |> validate_inclusion(:result, @results)
  end

  def results, do: @results
end
