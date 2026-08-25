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
  # defaulted/ejected after making moves) - distinct from "0-0FF".
  #
  # "1/2-0"/"0-1/2" are the asymmetric result FIDE's VCL.13 explicitly
  # requires support for - an arbiter's disciplinary point adjustment on an
  # otherwise-drawn game (the TRF16 spec has no dedicated code for this; it's
  # written as "=" for the ½ side and "0" for the 0 side, see Trf's
  # @legal_result_pairs), never symmetric like every other result here.
  #
  # "+--"/"--+" are accepted for backward compatibility with historical and
  # SWAR-imported data that predates the explicit "…FF" notation; the entry
  # UI no longer offers them (see PairingsEngineWeb.PairingsLive).
  @results [
    "",
    "1-0",
    "1/2-1/2",
    "0-1",
    "1/2-0",
    "0-1/2",
    "1-0FF",
    "0-1FF",
    "0-0FF",
    "0-0",
    # Played but unrated (TRF codes W / D / L) - a game contested over the
    # board that does not reach the rating report, typically because it
    # ended before the minimum number of moves. Scores and pairs exactly
    # like its rated twin. VCL4THP Q185.
    "1-0U",
    "0-1U",
    "1/2-1/2U",
    "+--",
    "--+",
    "bye"
  ]

  schema "pairings" do
    field :board, :integer
    field :result, :string, default: ""
    field :match_id, :integer

    # The label/classification PairingDisplay prints for this board, frozen
    # once by PairingsEngine.Tournaments.freeze_round_display_boards!/1 at
    # the moment the round is paired (or re-paired) - never touched again,
    # not even by a later edit to a player's fixed_board. Deliberately kept
    # out of changeset/2's cast list: PairingDisplay.compute_labels/1 and
    # the freeze wrapper are the only legitimate writers. See
    # PairingsEngine.PairingDisplay's moduledoc for why.
    field :display_board, :string
    field :display_special, :boolean, default: false

    # Display-only "don't show me this" flag for a fully-vacated row (both
    # seats empty) - see PairingsEngine.Tournaments.set_pairing_hidden/3.
    # Kept out of changeset/2's cast list, same reasoning as display_board
    # above: one dedicated writer, guarded server-side, never a bare field
    # update from arbitrary attrs.
    field :hidden, :boolean, default: false

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
