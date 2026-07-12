defmodule PairingsEngine.Tournaments.Pairing do
  use Ecto.Schema
  import Ecto.Changeset

  # Results as shown to the arbiter. Byes are stored as a pairing with no
  # black player.
  #
  # Forfeits are explicit "…FF" results (never played, FIDE Art. 16):
  #   "1-0FF" white wins by forfeit, "0-1FF" black wins by forfeit,
  #   "0-0FF" double forfeit (neither played).
  # Plain "0-0" is a PLAYED game where both players lose (e.g. both
  # defaulted/ejected after making moves) — distinct from "0-0FF".
  #
  # "+--"/"--+" are accepted for backward compatibility with historical and
  # SWAR-imported data that predates the explicit "…FF" notation; the entry
  # UI no longer offers them (see PairingsEngineWeb.PairingsLive).
  @results [
    "",
    "1-0",
    "1/2-1/2",
    "0-1",
    "1-0FF",
    "0-1FF",
    "0-0FF",
    "0-0",
    "+--",
    "--+",
    "bye"
  ]

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
