defmodule PairingsEngine.Chess960 do
  @moduledoc """
  Chess960 (Fischer random) starting positions, and the arbiter's draw of one
  per round (VCL4THP Q222).

  A position is a number from 0 to 959 in the standard (Scharnagl) numbering,
  the one the Guidelines of the Laws of Chess and every Chess960 program use:
  518 is the usual `RNBQKBNR`, 0 is `BBQNNRKR`. `position/1` turns a number
  into the piece order on the first rank, `number/1` back.

  The draw is uniform over the 960 and uses the operating system's random
  source (`:crypto`), with rejection so no position is likelier than another.
  A round's position is drawn once: it is part of the round, printed with
  its pairings, and drawing again until one pleases is what a draw must not
  allow.
  """

  import Ecto.Query

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Round, Tournament}

  # The five squares left after the bishops and the queen are placed: where
  # the two knights go, by the number 0..9 the numbering assigns each choice.
  @knights [
    {0, 1},
    {0, 2},
    {0, 3},
    {0, 4},
    {1, 2},
    {1, 3},
    {1, 4},
    {2, 3},
    {2, 4},
    {3, 4}
  ]

  @doc "Number of Chess960 starting positions."
  def count, do: 960

  @doc """
  The first-rank piece order of position `n` (0..959), as a string of eight
  letters from White's a-file to the h-file.

      iex> PairingsEngine.Chess960.position(518)
      "RNBQKBNR"
      iex> PairingsEngine.Chess960.position(0)
      "BBQNNRKR"
  """
  def position(n) when is_integer(n) and n >= 0 and n < 960 do
    {n2, light} = {div(n, 4), rem(n, 4)}
    {n3, dark} = {div(n2, 4), rem(n2, 4)}
    {n4, queen} = {div(n3, 6), rem(n3, 6)}

    board = %{(2 * light + 1) => "B", (2 * dark) => "B"}

    {board, free} = place(board, free(board), queen, "Q")

    {k1, k2} = Enum.at(@knights, n4)
    knight_squares = [Enum.at(free, k1), Enum.at(free, k2)]
    board = Enum.reduce(knight_squares, board, &Map.put(&2, &1, "N"))

    [r1, k, r2] = free(board)
    board = board |> Map.put(r1, "R") |> Map.put(k, "K") |> Map.put(r2, "R")

    Enum.map_join(0..7, &Map.fetch!(board, &1))
  end

  defp free(board), do: Enum.reject(0..7, &Map.has_key?(board, &1))

  defp place(board, free, index, piece) do
    square = Enum.at(free, index)
    {Map.put(board, square, piece), List.delete(free, square)}
  end

  @doc """
  The number of a first-rank piece order, or `:error` when it is not a legal
  Chess960 setup (bishops on opposite colours, the king between the rooks).
  """
  def number(order) when is_binary(order) do
    Enum.find(0..959, :error, &(position(&1) == order))
  end

  @doc "A uniformly drawn position number, 0..959."
  def draw do
    # 960 * 4369 = 4_194_240 of the 4_194_304 values of 22 bits: the
    # remainder is discarded so every position has the same chance.
    <<value::unsigned-22>> = rand_bits()

    if value < 4_194_240, do: rem(value, 960), else: draw()
  end

  defp rand_bits do
    <<bits::bitstring-size(22), _::bitstring>> = :crypto.strong_rand_bytes(3)
    bits
  end

  @doc """
  Draws the starting position of round `round_number` of `tournament`.

  Needs `chess960` on and a paired round that has none yet; a position is
  drawn once. `{:ok, round}` with `chess960_position` set, or
  `{:error, :not_enabled | :no_round | :already_drawn | :archived | ...}`.
  `draw_fun` is for tests.
  """
  def draw_for_round(%Tournament{} = tournament, round_number, draw_fun \\ &draw/0) do
    with :ok <- Tournaments.ensure_writable(tournament),
         :ok <- if(tournament.chess960, do: :ok, else: {:error, :not_enabled}),
         {:ok, round} <- fetch_round(tournament, round_number) do
      case round.chess960_position do
        nil ->
          {1, _} =
            Repo.update_all(
              from(r in Round, where: r.id == ^round.id and is_nil(r.chess960_position)),
              set: [chess960_position: draw_fun.()]
            )

          Tournaments.broadcast_tournament_change(tournament.id, :pairings)
          {:ok, Repo.get!(Round, round.id)}

        _ ->
          {:error, :already_drawn}
      end
    end
  end

  defp fetch_round(tournament, number) do
    case Repo.one(
           from r in Round, where: r.tournament_id == ^tournament.id and r.number == ^number
         ) do
      nil -> {:error, :no_round}
      round -> {:ok, round}
    end
  end

  @doc """
  What a round shows for its position: `"518 RNBQKBNR"`, or nil when none
  has been drawn.
  """
  def label(%{chess960_position: n}) when is_integer(n), do: "#{n} #{position(n)}"
  def label(_round), do: nil
end
