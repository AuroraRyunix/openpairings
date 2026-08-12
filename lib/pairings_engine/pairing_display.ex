defmodule PairingsEngine.PairingDisplay do
  @moduledoc """
  Presentation-only board renumbering for a round's pairings, so a
  fixed-table player (`Player.fixed_board` — e.g. a wheelchair-accessible
  board, often a separate room) doesn't leave a hole in the ordinary board
  sequence.

  **Pure and read-only**: nothing here ever writes `pairing.board` — the
  real, engine-assigned board number stays exactly what JaVaFo/the pairing
  algorithm computed, in the database, forever. Results, the audit trail,
  TRF export, and every other lookup keyed on a pairing's real board
  number are completely unaffected. This only decides what LABEL to print
  next to a board and what ORDER to print rows in.

  ## The renumbering

  A pairing is "special" if either player has `fixed_board` set. Every
  other ("normal") pairing is renumbered 1..N in its original relative
  board order — closing the gap a pulled-out special pairing would
  otherwise leave (real board 10 goes to fixed_board 1001 → whoever was
  board 11 becomes displayed board 10, and so on). Special pairings sort
  after every normal one, ordered by their own lowest `fixed_board` value,
  and are labelled with the union of both sides' `fixed_board` values (one
  number normally; both, slash-joined, on the rare board where two
  fixed-board players are paired against each other).
  """

  @doc """
  Returns `pairings` (each preloaded with `:white_player`/`:black_player`)
  as `%{pairing: pairing, board: display_board}` maps, in final display
  order: renumbered normal boards first (ascending), then special boards
  (ascending by their own fixed_board value). `display_board` is a string
  — a plain integer for a normal board, the fixed_board value(s) for a
  special one.
  """
  def with_display_boards(pairings) do
    {special, normal} = Enum.split_with(pairings, &special?/1)

    normal_rows =
      normal
      |> Enum.sort_by(& &1.board)
      |> Enum.with_index(1)
      |> Enum.map(fn {pairing, i} -> %{pairing: pairing, board: Integer.to_string(i)} end)

    special_rows =
      special
      |> Enum.map(&%{pairing: &1, board: special_label(&1), sort_key: special_sort_key(&1)})
      |> Enum.sort_by(& &1.sort_key)
      |> Enum.map(&Map.delete(&1, :sort_key))

    normal_rows ++ special_rows
  end

  @doc """
  Like `with_display_boards/1`, but keeps `pairings`' own order instead of
  reordering — for documents sorted some other way (alphabetically by
  name, say) that still need the right label next to each board, without
  physically moving special-board rows to the end. Returns the same
  `%{pairing: pairing, board: display_board}` shape, one per input
  pairing, in the same order they were given.
  """
  def board_labels(pairings) do
    normal_boards =
      pairings
      |> Enum.reject(&special?/1)
      |> Enum.sort_by(& &1.board)
      |> Enum.with_index(1)
      |> Map.new(fn {pairing, i} -> {pairing.id, Integer.to_string(i)} end)

    Enum.map(pairings, fn pairing ->
      board =
        if special?(pairing),
          do: special_label(pairing),
          else: Map.fetch!(normal_boards, pairing.id)

      %{pairing: pairing, board: board}
    end)
  end

  @doc "Whether `pairing` has at least one side with a `fixed_board` set."
  def special?(pairing) do
    pairing
    |> players()
    |> Enum.any?(&(&1.fixed_board != nil))
  end

  defp players(pairing) do
    [pairing.white_player, pairing.black_player] |> Enum.reject(&is_nil/1)
  end

  # Both sides' fixed_board values, deduped and ascending — a pairing
  # between two DIFFERENT fixed-board players (both set, disagreeing) is
  # the one case this can return more than one value for.
  defp fixed_boards(pairing) do
    pairing
    |> players()
    |> Enum.map(& &1.fixed_board)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp special_label(pairing), do: pairing |> fixed_boards() |> Enum.map_join("/", &to_string/1)

  defp special_sort_key(pairing), do: pairing |> fixed_boards() |> List.first()
end
