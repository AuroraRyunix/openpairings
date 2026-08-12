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

  A pairing is "special" if either player has `fixed_board` set — that
  check wins over everything below, so a fixed-table player's bye or
  vacated seat still sorts and labels as a special board, not a bye/vacant
  one. Among the rest, a pairing is a "bye" if `result == "bye"` (an
  awarded pairing-allocated bye — an empty black seat), and "vacant" if
  exactly one seat is empty and it ISN'T a bye (a player pulled out
  mid-round via "Mark absent", see the vacancy model in
  `PairingsEngineWeb.PairingsLive`'s moduledoc). Everything else is a
  "normal" pairing: both seats filled, in progress or with a real result.

  Normal, bye, and vacant pairings are renumbered together as one
  contiguous 1..N sequence — normal ones first (closing the gap a
  pulled-out special pairing would otherwise leave: real board 10 goes to
  fixed_board 1001 → whoever was board 11 becomes displayed board 10),
  then byes, then vacant seats, each group sorted by its own real board
  number. Special pairings sort after all of those, ordered by their own
  lowest `fixed_board` value, and are labelled with the union of both
  sides' `fixed_board` values (one number normally; both, slash-joined, on
  the rare board where two fixed-board players are paired against each
  other).
  """

  @doc """
  Returns `pairings` (each preloaded with `:white_player`/`:black_player`)
  as `%{pairing: pairing, board: display_board}` maps, in final display
  order: renumbered normal boards first (ascending), then byes, then
  vacant seats (each ascending by real board), then special boards
  (ascending by their own fixed_board value). `display_board` is a string
  — a plain integer for a normal/bye/vacant board, the fixed_board
  value(s) for a special one.
  """
  def with_display_boards(pairings) do
    {special, ordered_non_special} = split_and_order(pairings)

    non_special_rows =
      ordered_non_special
      |> Enum.with_index(1)
      |> Enum.map(fn {pairing, i} -> %{pairing: pairing, board: Integer.to_string(i)} end)

    special_rows =
      special
      |> Enum.map(&%{pairing: &1, board: special_label(&1), sort_key: special_sort_key(&1)})
      |> Enum.sort_by(& &1.sort_key)
      |> Enum.map(&Map.delete(&1, :sort_key))

    non_special_rows ++ special_rows
  end

  @doc """
  Like `with_display_boards/1`, but keeps `pairings`' own order instead of
  reordering — for documents sorted some other way (alphabetically by
  name, say) that still need the right label next to each board, without
  physically moving special/bye/vacant rows to the end. Returns the same
  `%{pairing: pairing, board: display_board}` shape, one per input
  pairing, in the same order they were given.
  """
  def board_labels(pairings) do
    {_special, ordered_non_special} = split_and_order(pairings)

    non_special_boards =
      ordered_non_special
      |> Enum.with_index(1)
      |> Map.new(fn {pairing, i} -> {pairing.id, Integer.to_string(i)} end)

    Enum.map(pairings, fn pairing ->
      board =
        if special?(pairing),
          do: special_label(pairing),
          else: Map.fetch!(non_special_boards, pairing.id)

      %{pairing: pairing, board: board}
    end)
  end

  # Splits `pairings` into `{special, ordered_non_special}` — the second
  # element already in final numbering order (normal, then byes, then
  # vacant, each sorted by real board) so both public functions just
  # `Enum.with_index/2` it for the shared 1..N sequence.
  defp split_and_order(pairings) do
    {special, rest} = Enum.split_with(pairings, &special?/1)
    {byes, rest} = Enum.split_with(rest, &bye?/1)
    {vacant, normal} = Enum.split_with(rest, &vacant?/1)

    ordered =
      Enum.sort_by(normal, & &1.board) ++
        Enum.sort_by(byes, & &1.board) ++
        Enum.sort_by(vacant, & &1.board)

    {special, ordered}
  end

  defp bye?(pairing), do: pairing.result == "bye"

  defp vacant?(pairing), do: pairing.white_player == nil or pairing.black_player == nil

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
