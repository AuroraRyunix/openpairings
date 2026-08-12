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

  Every non-special pairing gets its NUMBER from one single pass, sorted
  by real board — normal, bye, and vacant alike, exactly as if none of
  them were byes/vacant (closing the gap a pulled-out special pairing
  would otherwise leave: real board 10 goes to fixed_board 1001 →
  whoever was board 11 becomes displayed board 10). This is deliberate
  and load-bearing: a board's number must never shift just because
  ANOTHER board's bye/absence status changes later in the round — an
  arbiter marking one player absent mid-round must not renumber every
  board after it while people are already seated. Special pairings are
  numbered separately, by their own lowest `fixed_board` value, and are
  labelled with the union of both sides' `fixed_board` values (one number
  normally; both, slash-joined, on the rare board where two fixed-board
  players are paired against each other).

  `with_display_boards/1`'s ROW ORDER is a separate concern from that
  numbering: normal pairings print first, then byes, then vacant seats,
  then special boards — but every row keeps the stable number described
  above, not a fresh renumbering of the reordered groups. A bye sitting
  at real board 3 still shows "3" even after it's moved to the bottom of
  the page.
  """

  @doc """
  Returns `pairings` (each preloaded with `:white_player`/`:black_player`)
  as `%{pairing: pairing, board: display_board}` maps, in final display
  order: normal boards first (ascending by real board), then byes, then
  vacant seats (each ascending by real board), then special boards
  (ascending by their own fixed_board value). `display_board` is a
  string — a plain integer for a normal/bye/vacant board (stable: see the
  moduledoc), the fixed_board value(s) for a special one.
  """
  def with_display_boards(pairings) do
    {special, non_special, labels} = split_and_label(pairings)
    {byes, rest} = Enum.split_with(non_special, &bye?/1)
    {vacant, normal} = Enum.split_with(rest, &vacant?/1)

    ordered_non_special =
      Enum.sort_by(normal, & &1.board) ++
        Enum.sort_by(byes, & &1.board) ++
        Enum.sort_by(vacant, & &1.board)

    non_special_rows =
      Enum.map(ordered_non_special, fn pairing ->
        %{pairing: pairing, board: Map.fetch!(labels, pairing.id)}
      end)

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
    {_special, _non_special, labels} = split_and_label(pairings)

    Enum.map(pairings, fn pairing ->
      board =
        if special?(pairing), do: special_label(pairing), else: Map.fetch!(labels, pairing.id)

      %{pairing: pairing, board: board}
    end)
  end

  # Splits `pairings` into `{special, non_special, labels}` — `labels` is
  # `%{pairing.id => display_board}` for every non-special pairing,
  # numbered together in ONE pass by real board order regardless of
  # bye/vacant/normal status (see the moduledoc: this is what keeps a
  # board's number stable across a later bye/absence action elsewhere in
  # the round).
  defp split_and_label(pairings) do
    {special, non_special} = Enum.split_with(pairings, &special?/1)

    labels =
      non_special
      |> Enum.sort_by(& &1.board)
      |> Enum.with_index(1)
      |> Map.new(fn {pairing, i} -> {pairing.id, Integer.to_string(i)} end)

    {special, non_special, labels}
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
