defmodule PairingsEngineWeb.Postponed do
  @moduledoc """
  The words for postponed games, and the one banner every page that shows
  standings puts up while one is open.

  `PairingsEngine.PostponedGames` decides when a warning applies and returns
  it as a code; this module is where each code becomes a sentence, so a
  warning reads the same on every page and in both languages. The UI term is
  **postponed** (Dutch: *uitgesteld*) throughout, for adjourned games too:
  it is the word a club arbiter uses for a game that will be played later,
  and one term keeps the Pairings page, the standings and the phone from
  disagreeing about what the board is. The code names keep FIDE's
  "adjourned", because they name the VCL4THP questions they answer.
  """
  use Phoenix.Component
  use Gettext, backend: PairingsEngineWeb.Gettext

  @doc """
  The sentence for one of `PairingsEngine.PostponedGames.pairing_warnings/1`'s
  warnings, when pairing round `next_round`. A statement, never a question:
  a button that confirms several joins them and asks once
  (`pair_confirm_text/2`).
  """
  def pairing_warning_text(%{id: :missing_results_recorded_as_adjourned} = w, _next_round) do
    ngettext(
      "Round %{round} has a board without a result. It will be recorded as a postponed game, which counts provisionally for pairing until its result is entered.",
      "Round %{round} has %{count} boards without a result. They will be recorded as postponed games, which count provisionally for pairing until their results are entered.",
      w.count,
      round: w.round
    )
  end

  def pairing_warning_text(%{id: :adjourned_older_round_open} = w, next_round) do
    ngettext(
      "A postponed game from round %{rounds} is still to be played. It counts provisionally for pairing round %{next}.",
      "%{count} postponed games from rounds %{rounds} are still to be played. They count provisionally for pairing round %{next}.",
      w.count,
      rounds: Enum.join(w.rounds, ", "),
      next: next_round
    )
  end

  def pairing_warning_text(%{id: :adjourned_counted_as_draw} = w, next_round) do
    ngettext(
      "Round %{round} has a postponed game. It counts provisionally for pairing round %{next}.",
      "Round %{round} has %{count} postponed games. They count provisionally for pairing round %{next}.",
      w.count,
      round: w.round,
      next: next_round
    )
  end

  @doc """
  The confirmation a pair button asks for `warnings`, pairing `next_round`:
  one sentence per warning, then the question. nil when there is nothing to
  confirm, which leaves the button without a confirmation at all.
  """
  def pair_confirm_text([], _next_round), do: nil

  def pair_confirm_text(warnings, next_round) do
    Enum.map_join(warnings, " ", &pairing_warning_text(&1, next_round)) <>
      " " <> gettext("Pair round %{n}?", n: next_round)
  end

  @doc """
  The confirmation for giving a postponed game a result that is not a draw
  (`:adjourned_non_draw_result`, VCL4THP Q163).
  """
  def non_draw_text(round_number, board, result, pairing \\ nil)

  def non_draw_text(round_number, board, result, %{provisional_white: w, provisional_black: b})
      when w != b or (w not in [nil, "draw"] and b not in [nil, "draw"]) do
    gettext(
      "Board %{board} of round %{round} was postponed and has counted as %{white} for White and %{black} for Black. %{result} is not a draw: the scores that later rounds were paired with change, and those pairings stay as they are.",
      board: board,
      round: round_number,
      result: result,
      white: outcome_words(w),
      black: outcome_words(b)
    )
  end

  def non_draw_text(round_number, board, result, _pairing) do
    gettext(
      "Board %{board} of round %{round} was postponed and has counted as a draw for pairing. %{result} is not a draw: the scores that later rounds were paired with change, and those pairings stay as they are.",
      board: board,
      round: round_number,
      result: result
    )
  end

  defp outcome_words("win"), do: gettext("a win")
  defp outcome_words("loss"), do: gettext("a loss")
  defp outcome_words(_draw), do: gettext("a draw")

  @doc "The sentence for anything that is not final while `count` games are open."
  def not_final_text(count) do
    ngettext(
      "Not final: a postponed game is still to be played. It counts provisionally until its result is entered.",
      "Not final: %{count} postponed games are still to be played. They count provisionally until their results are entered.",
      count
    )
  end

  @doc "The TRF export's note while `count` games are open (`:adjourned_trf_not_final`)."
  def trf_not_final_text(count) do
    ngettext(
      "The TRF export is not final: a postponed game is written as an unknown result (?), counted as a draw.",
      "The TRF export is not final: %{count} postponed games are written as unknown results (?), each counted as a draw.",
      count
    )
  end

  @doc """
  What `{:needs_acknowledgement, ids}` means, for a page that reached the
  write without asking first - a stale tab, or a board another arbiter
  postponed a moment ago.
  """
  def needs_acknowledgement_text(ids) do
    reasons = Enum.map_join(ids, " ", &acknowledgement_reason/1)
    gettext("Not done - this needs your confirmation first. %{reasons}", reasons: reasons)
  end

  defp acknowledgement_reason(:adjourned_non_draw_result),
    do:
      gettext(
        "The game was postponed and counted provisionally; enter its result again to confirm."
      )

  defp acknowledgement_reason(:missing_results_recorded_as_adjourned),
    do: gettext("The last round has boards without a result.")

  defp acknowledgement_reason(:adjourned_older_round_open),
    do: gettext("A postponed game from an earlier round is still to be played.")

  defp acknowledgement_reason(:finalised_result_changed),
    do: gettext("This result was already sent in a TRF finalised for sending.")

  defp acknowledgement_reason(_other), do: ""

  @doc """
  The question before changing a result already sent in a TRF finalised for
  sending (`:finalised_result_changed`). The file that went out is not
  changed by this, and no later report sends the round again.
  """
  def finalised_changed_text(round_number, board, result) do
    gettext(
      "Board %{board} of round %{round} was already sent in a TRF finalised for sending. Changing it to %{result} changes it here only: the file that was sent keeps the old result, and the round is not sent again. Correct it with the rating officer too.",
      board: board,
      round: round_number,
      result: result
    )
  end

  @doc """
  The banner a standings view carries while `count` postponed games are open
  (`:adjourned_standings_not_final`, VCL4THP Q161 and Q169). Renders nothing
  at zero.
  """
  attr :count, :integer, required: true
  attr :id, :string, default: "postponed-not-final"

  def not_final_banner(assigns) do
    ~H"""
    <div
      :if={@count > 0}
      id={@id}
      class="card"
      role="status"
      style="display: block; margin: 12px 0; border-left: 3px solid var(--warn)"
    >
      <strong>{not_final_text(@count)}</strong>
    </div>
    """
  end
end
