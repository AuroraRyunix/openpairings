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
  use PairingsEngineWeb, :verified_routes

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
  one sentence per warning, then the open postponed games by name
  (`open_games/1`'s answer, `provisional_players_text/1`), then the
  question. nil when there is nothing to confirm, which leaves the button
  without a confirmation at all.
  """
  def pair_confirm_text(warnings, next_round, open_games \\ [])

  def pair_confirm_text([], _next_round, _open_games), do: nil

  def pair_confirm_text(warnings, next_round, open_games) do
    [
      Enum.map_join(warnings, " ", &pairing_warning_text(&1, next_round)),
      provisional_players_text(open_games),
      gettext("Pair round %{n}?", n: next_round)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  @doc """
  The open postponed games by name, for the pair confirmation: whoever is
  in one is paired on a provisional score. nil when there are none.
  """
  def provisional_players_text([]), do: nil

  def provisional_players_text(open_games) do
    ngettext(
      "Still to be played: %{games}. Both players are paired on a provisional score, which changes once the result is entered.",
      "Still to be played: %{games}. Their players are paired on a provisional score, which changes once the results are entered.",
      length(open_games),
      games: Enum.map_join(open_games, "; ", &game_text/1)
    )
  end

  @doc """
  One postponed game as a line of text: "Round 3, board 2: Alice - Carol".
  The board is the frozen label the pairing sheet prints.
  """
  def game_text(%{round: round, pairing: p}) do
    gettext("Round %{round}, board %{board}: %{white} - %{black}",
      round: round,
      board: p.display_board || p.board,
      white: player_name(p.white_player),
      black: player_name(p.black_player)
    )
  end

  defp player_name(nil), do: "?"
  defp player_name(player), do: player.name

  @doc "A date as this app prints one to an arbiter: 05-10-2026."
  def date_text(%Date{} = date), do: Calendar.strftime(date, "%d-%m-%Y")

  @doc "When a postponed game will be played, as the players agreed it."
  def agreed_text(nil), do: gettext("no date agreed yet")
  def agreed_text(%Date{} = date), do: gettext("to be played on %{date}", date: date_text(date))

  @doc """
  A month as a rating period is named: "October 2026". The month names are
  translated here rather than taken from the calendar, which only knows
  English.
  """
  def month_text(%Date{year: year, month: month}) do
    gettext("%{month} %{year}", month: month_name(month), year: year)
  end

  defp month_name(1), do: gettext("January")
  defp month_name(2), do: gettext("February")
  defp month_name(3), do: gettext("March")
  defp month_name(4), do: gettext("April")
  defp month_name(5), do: gettext("May")
  defp month_name(6), do: gettext("June")
  defp month_name(7), do: gettext("July")
  defp month_name(8), do: gettext("August")
  defp month_name(9), do: gettext("September")
  defp month_name(10), do: gettext("October")
  defp month_name(11), do: gettext("November")
  defp month_name(12), do: gettext("December")

  @doc """
  One entry of a game's agreed-date history (`Pairing.agreed_date_log`), as
  `{change, when_and_who}`: "05-10-2026 → 12-10-2026" and
  "27-09-2026 14:03 UTC, jan@example.org".
  """
  def date_log_parts(entry) do
    change =
      gettext("%{from} → %{to}", from: log_date(entry["from"]), to: log_date(entry["to"]))

    at =
      case DateTime.from_iso8601(entry["at"] || "") do
        {:ok, dt, _offset} -> Calendar.strftime(dt, "%d-%m-%Y %H:%M UTC")
        _ -> nil
      end

    {change, [at, entry["by"]] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(", ")}
  end

  defp log_date(nil), do: gettext("no date")

  defp log_date(iso) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> date_text(date)
      _ -> iso
    end
  end

  @doc "What a pending mark says: \"1 pending\"."
  def pending_text(count), do: ngettext("%{count} pending", "%{count} pending", count)

  @doc """
  A team match's postponed boards, after its score: "3.5 - 2.5, 1 board
  pending". The score is provisional until they are played - the postponed
  boards count as the draws they stand for.
  """
  def boards_pending_text(count),
    do: ngettext("%{count} board pending", "%{count} boards pending", count)

  @doc """
  The mark beside a player or team with a postponed game still to be
  played, so a provisional place is not read as a final one. Renders nothing
  at zero.
  """
  attr :count, :integer, required: true
  attr :id, :string, required: true
  attr :boards, :boolean, default: false, doc: "count boards (a team) rather than games"

  def pending_chip(assigns) do
    ~H"""
    <span
      :if={@count > 0}
      id={@id}
      class="pending-chip"
      title={
        if @boards,
          do:
            ngettext(
              "%{count} board still to be played in a postponed game - this place is provisional",
              "%{count} boards still to be played in postponed games - this place is provisional",
              @count
            ),
          else:
            ngettext(
              "%{count} postponed game still to be played - this place is provisional",
              "%{count} postponed games still to be played - this place is provisional",
              @count
            )
      }
    >
      {if @boards, do: boards_pending_text(@count), else: pending_text(@count)}
    </span>
    """
  end

  @doc """
  The guard in front of anything that reads as the end of the event - final
  standings, prize lists, closing the tournament: how many postponed games
  are still unplayed, each a link to the round where its result is entered.
  Renders nothing when every game is in.
  """
  attr :tournament, :map, required: true
  attr :games, :list, required: true, doc: "`PostponedGames.open_games/1`"
  attr :id, :string, default: "postponed-unplayed"
  attr :note, :string, default: nil

  def unplayed_guard(assigns) do
    ~H"""
    <div :if={@games != []} id={@id} class="card postponed-guard" role="status">
      <strong class="postponed-guard-title">
        {ngettext(
          "%{count} postponed game still unplayed",
          "%{count} postponed games still unplayed",
          length(@games)
        )}
      </strong>
      <p :if={@note} class="hint postponed-guard-note">{@note}</p>
      <.game_links tournament={@tournament} games={@games} id={@id} />
    </div>
    """
  end

  attr :tournament, :map, required: true
  attr :games, :list, required: true
  attr :id, :string, required: true

  defp game_links(assigns) do
    ~H"""
    <ul class="postponed-links">
      <li :for={game <- @games}>
        <.link
          id={"#{@id}-game-#{game.pairing.id}"}
          navigate={~p"/t/#{@tournament.id}/pairings?round=#{game.round}"}
        >
          {game_text(game)}
        </.link>
        <span :if={game.pairing.agreed_date} class="hint">
          · {agreed_text(game.pairing.agreed_date)}
        </span>
      </li>
    </ul>
    """
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
  The warning beside sending while players share a name and have no FIDE ID
  (`:sent_games_ambiguous_players`, from
  `PairingsEngine.PostponedGames.ambiguous_players/1`). It blocks nothing.
  """
  def ambiguous_players_text(ambiguous) do
    gettext(
      "The record of sent games cannot tell apart players who have no FIDE ID and the same name: %{names}. A restore or a hand-off return may put their sent games on the wrong board. Give them a FIDE ID or names that differ before sending.",
      names: ambiguous_names(ambiguous)
    )
  end

  @doc """
  The same warning after a restore or a hand-off return re-applied the sent
  marks, for the ambiguous players who have a sent game
  (`PairingsEngine.PostponedGames.ambiguous_sent_players/1`).
  """
  def ambiguous_sent_text(ambiguous) do
    gettext(
      "The sent marks were put back, but the record of sent games cannot tell apart players who have no FIDE ID and the same name: %{names}. Check their games in the rounds already sent.",
      names: ambiguous_names(ambiguous)
    )
  end

  @doc "The names in an ambiguity warning, as the audit trail stores them too."
  def ambiguous_names(ambiguous) do
    Enum.map_join(ambiguous, ", ", fn
      %{names: [name | _], count: count} ->
        gettext("%{name} (%{count} players)", name: name, count: count)

      name when is_binary(name) ->
        name
    end)
  end

  @doc """
  The banner a standings view carries while `count` postponed games are open
  (`:adjourned_standings_not_final`, VCL4THP Q161 and Q169). Renders nothing
  at zero.
  """
  attr :count, :integer, required: true
  attr :id, :string, default: "postponed-not-final"
  attr :tournament, :map, default: nil
  attr :games, :list, default: [], doc: "the open games, listed as links when given"

  def not_final_banner(assigns) do
    ~H"""
    <div :if={@count > 0} id={@id} class="card postponed-guard" role="status">
      <strong>{not_final_text(@count)}</strong>
      <.game_links :if={@tournament && @games != []} tournament={@tournament} games={@games} id={@id} />
    </div>
    """
  end
end
