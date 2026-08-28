defmodule PairingsEngine.PairingDisplay do
  @moduledoc """
  Presentation-only board renumbering for a round's pairings, so a
  fixed-table player (`Player.fixed_board` - e.g. a wheelchair-accessible
  board, often a separate room) doesn't leave a hole in the ordinary board
  sequence.

  **Pure and read-only**: nothing here ever writes `pairing.board` - the
  real, engine-assigned board number stays exactly what JaVaFo/the pairing
  algorithm computed, in the database, forever. Results, the audit trail,
  TRF export, and every other lookup keyed on a pairing's real board
  number are completely unaffected. This only decides what LABEL to print
  next to a board and what ORDER to print rows in.

  ## The renumbering - computed once, frozen, never live again

  A pairing is "special" if either player has `fixed_board` set at the
  moment the round is paired - that check wins over everything below, so a
  fixed-table player's bye or vacated seat still sorts and labels as a
  special board, not a bye/vacant one. Among the rest, every non-special
  pairing gets its NUMBER from one single pass, sorted by real board -
  normal, bye, and vacant alike, exactly as if none of them were
  byes/vacant (closing the gap a special pairing would otherwise leave:
  real board 10 goes to fixed_board 1001 → whoever was board 11 becomes
  displayed board 10). Special pairings are labelled with the union of
  both sides' `fixed_board` values (one number normally; both, slash-
  joined, on the rare board where two fixed-board players are paired
  against each other).

  This split and numbering is computed exactly ONCE per round, by
  `compute_labels/1`, called only from
  `PairingsEngine.Tournaments.freeze_round_display_boards!/1` at the
  moment a round is created - ordinary pairing, round-robin, Keizer, or an
  import/restore. The result is written to `Pairing.display_board` /
  `Pairing.display_special` and every other function in this module reads
  those frozen columns instead of recomputing. This is deliberate and
  load-bearing, and was a real, reported bug (the 0.14.6 board-renumbering
  class, surviving here): giving a player a fixed board *after* their
  round was already paired must never retroactively renumber every board
  after theirs while people are already seated. A board's fixed_board
  status is only ever allowed to affect the display the next time that
  player's round is (re-)paired - never on the fly from an unrelated edit
  (e.g. the Players page) mid-round.

  `with_display_boards/1`'s ROW ORDER is a separate, deliberately still
  LIVE concern from that frozen numbering: normal pairings print first,
  then special boards, then byes, then vacant seats - reflecting whatever
  currently has a vacancy/bye, since reordering rows doesn't renumber
  anyone. A bye sitting at real board 3 still shows "3" even after it's
  moved to the bottom of the page.

  Why special boards sort UP among the games rather than below the byes
  (from 0.14.7 until this changed, they printed dead last, under
  everything): a special board is a board somebody is playing on - an
  accessible table is a seat, not an absence - so it belongs with the
  other games. Byes and vacated seats are the two categories where nobody
  is playing, and they belong together at the bottom. The old order put a
  live game underneath a list of people who aren't in the hall, which is
  also the opposite of what 0.14.7's own changelog entry claimed it did
  ("byes and vacant/absent seats below the special boards").
  """

  @doc """
  Computes what should be FROZEN for `pairings` (each preloaded with
  `:white_player`/`:black_player`) as
  `%{pairing.id => %{display_board: label, display_special: bool}}`.

  Called exactly once per round, by
  `PairingsEngine.Tournaments.freeze_round_display_boards!/1` - this is
  the only place in the whole application that reads `Player.fixed_board`
  for display purposes. See the moduledoc for why nothing else may.
  """
  def compute_labels(pairings) do
    {special, non_special} = Enum.split_with(pairings, &special?/1)

    non_special_labels =
      non_special
      |> Enum.sort_by(& &1.board)
      |> Enum.with_index(1)
      |> Map.new(fn {pairing, i} ->
        {pairing.id, %{display_board: Integer.to_string(i), display_special: false}}
      end)

    special_labels =
      Map.new(special, fn pairing ->
        {pairing.id, %{display_board: special_label(pairing), display_special: true}}
      end)

    Map.merge(non_special_labels, special_labels)
  end

  @doc """
  Returns `pairings` as `%{pairing: pairing, board: display_board}` maps,
  in final display order: normal boards first, then special (fixed-table)
  boards, then byes, then vacant seats - each group ascending by real
  board. `display_board` is read from each pairing's frozen
  `display_board` column (see `compute_labels/1`) - not recomputed here,
  so no reordering this function does can renumber anybody.
  """
  def with_display_boards(pairings) do
    {special, non_special} = Enum.split_with(pairings, & &1.display_special)
    {byes, rest} = Enum.split_with(non_special, &bye?/1)
    {vacant, normal} = Enum.split_with(rest, &vacant?/1)

    # Games first (ordinary boards, then the fixed tables), then the two
    # not-playing groups. See the moduledoc for why special sits with the
    # games instead of below the byes.
    ordered =
      Enum.sort_by(normal, & &1.board) ++
        Enum.sort_by(special, & &1.board) ++
        Enum.sort_by(byes, & &1.board) ++
        Enum.sort_by(vacant, & &1.board)

    Enum.map(ordered, &row/1)
  end

  @doc """
  Like `with_display_boards/1`, but keeps `pairings`' own order instead of
  reordering - for documents sorted some other way (alphabetically by
  name, say) that still need the right label next to each board, without
  physically moving special/bye/vacant rows to the end. Returns the same
  `%{pairing: pairing, board: display_board}` shape, one per input
  pairing, in the same order they were given.
  """
  def board_labels(pairings), do: Enum.map(pairings, &row/1)

  @doc """
  The frozen label for ONE pairing - the singular of `board_labels/1`, for
  a document that renders a pairing at a time (a result card, a score
  sheet) rather than building a table of rows. Same value `board_labels/1`
  would report for it, fallback included; kept as the single definition of
  "what number goes next to this game" so a per-pairing document and a
  per-round table can never drift apart.
  """
  def board_label(pairing), do: pairing.display_board || fallback_label(pairing)

  defp row(pairing), do: %{pairing: pairing, board: board_label(pairing)}

  # Defensive only: every pairing-creating and import/restore call site
  # freezes display_board via Tournaments.freeze_round_display_boards!/1,
  # so display_board should never actually be nil. If some path is ever
  # missed, fall back to this pairing's own real board number rather than
  # showing a blank - never re-derive specialness here, or the whole point
  # of freezing (never recompute live) is undone by its own fallback.
  defp fallback_label(pairing), do: Integer.to_string(pairing.board)

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

  # Both sides' fixed_board values, deduped and ascending - a pairing
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
end
