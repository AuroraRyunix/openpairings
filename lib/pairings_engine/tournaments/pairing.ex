defmodule PairingsEngine.Tournaments.Pairing do
  use Ecto.Schema
  import Ecto.Changeset

  # The vocabulary of result codes, and what each one means, lives in
  # PairingsEngine.Results - one table, read here for validation and by
  # every screen that has to classify a stored result. See that module for
  # why the classification stopped being derived from point values.
  @results PairingsEngine.Results.codes()

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

    # Postponed games (`PairingsEngine.PostponedGames`). Kept out of
    # changeset/2's cast list like the display fields:
    # `Tournaments.update_pairing_result/3` writes the first three and the
    # TRF export's finalise step the last three.
    #
    #   * `provisional_white`/`provisional_black` - the outcome each side
    #     counts as while the game is postponed, frozen from the
    #     tournament's setting at the moment it was postponed.
    #   * `played_on` - when a postponed game was actually played.
    #   * `finalised_at` - the board went into a TRF marked as sent;
    #     `finalised_open` - it was an open postponed game then, written as
    #     `?`; `postponed_reported_at` - its later result was sent in the
    #     postponed-games file.
    field :provisional_white, :string
    field :postponed_by, :string
    field :provisional_black, :string
    field :played_on, :date
    field :finalised_at, :utc_datetime
    field :finalised_open, :boolean, default: false
    field :postponed_reported_at, :utc_datetime

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
