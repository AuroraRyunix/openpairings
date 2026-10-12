defmodule PairingsEngine.BoardLink.Game do
  @moduledoc """
  What a board in the hall reported about one game
  (`PairingsEngine.BoardLink.report/3`): the moves, the clocks, the result
  the board saw.

  `game_uid` is the pairing's own identity (`pairings.game_uid`), not its row
  id: a restore point rebuilds the pairings under new ids and the same
  `game_uid`, and the game is still the game.

  `result` is the board's opinion - `"1-0"`, `"1/2-1/2"`, `"0-1"` or nil. It
  is never the tournament's result. That one is `pairings.result`, and an
  arbiter types it.

  `seq` is the box's own counter for this game. An update with a lower one
  is a late duplicate and changes nothing.

  `move_clocks` runs beside `moves`: the mover's clock in milliseconds after
  each move, or nil where the box did not say.
  """
  use Ecto.Schema

  @statuses ~w(waiting live finished)
  @results ~w(1-0 1/2-1/2 0-1)

  schema "board_games" do
    field :game_uid, :string
    field :seq, :integer, default: 0
    field :status, :string, default: "live"
    field :result, :string
    field :moves, {:array, :string}, default: []
    field :move_clocks, {:array, :integer}, default: []
    field :white_ms, :integer
    field :black_ms, :integer
    field :running, :string
    field :start_fen, :string
    field :pgn, :string
    field :reconstructed, :integer, default: 0
    field :guessed, :integer, default: 0
    field :first_reported_at, :utc_datetime
    field :reported_at, :utc_datetime
    field :finished_at, :utc_datetime

    belongs_to :tournament, PairingsEngine.Tournaments.Tournament
    belongs_to :link, PairingsEngine.BoardLink.Link

    timestamps(type: :utc_datetime)
  end

  @doc "The game states a box may report."
  def statuses, do: @statuses

  @doc "The results a board can see. A forfeit is not one: nobody played it."
  def results, do: @results
end
