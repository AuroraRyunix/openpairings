defmodule PairingsEngine.PostponedGames do
  @moduledoc """
  Postponed and adjourned games: a board whose game was paired and has not
  been played yet (VCL4THP Q157-169, `docs/design-fide-mode.md` Phase 5).

  ## What a postponed game is

  In club play a game is often not played in its round - moved by agreement
  to a later evening, or adjourned - while the tournament goes on. The board
  carries `PairingsEngine.Results.postponed/0` (`"*"`): result unknown, game
  still to be played. It is not a blank. A blank is a board nobody has
  reported on and stops the next round from being paired; `"*"` is the
  arbiter saying "this one is known to be open".

  What it is worth is decided in exactly one place, the `PairingsEngine.Results`
  table, which classifies it as a draw for both players. So the crosstable,
  the tie-breaks, the pairing engine's score brackets and every export read
  the same half point, and there is no second result-to-points mapping to
  drift from the first (the shape that caused three bugs before 0.17.1).
  When the real result is entered, everything recomputes from it.

  ## What this module adds

    * which games are open (`open_games/1`), for the pages that list them
      and for anything that must not call itself final while one is;
    * the warnings, as codes (`warnings/0`). Sentences live in the web layer
      (`PairingsEngineWeb.PostponedText`), the same split
      `PairingsEngine.Compliance` keeps, so a warning can be translated and
      so a FIDE warning level can be attached to each entry later without
      touching what fires it;
    * the checks the two write paths ask before they act:
      `pairing_warnings/1` before a round is paired, `result_warnings/2`
      before a result is written over a postponed game.

  ## The warnings and their levels

  VCL4THP asks for some of these at a "Level 2" or "Level 3". The levels are
  not defined anywhere this project can read yet (`docs/design-fide-mode.md`,
  Phase 0 and Phase 4), so none is guessed here: every warning is an ordinary
  confirmation or notice, identified by an id naming its VCL question. When
  the levels exist they become one more key per entry of `@warnings`.
  """

  import Ecto.Query

  alias PairingsEngine.{Repo, Results}
  alias PairingsEngine.Tournaments.{Pairing, Round, Tournament}

  # One entry per warning. `vcl` is the VCL4THP v13 question it answers;
  # `acknowledge?` is whether the action it guards waits for the arbiter to
  # confirm it (the write path refuses with `{:needs_acknowledgement, ids}`
  # until they have), as opposed to a notice shown beside the action.
  @warnings [
    %{id: :adjourned_non_draw_result, vcl: [163], acknowledge?: true},
    %{id: :missing_results_recorded_as_adjourned, vcl: [159, 160], acknowledge?: true},
    %{id: :adjourned_older_round_open, vcl: [168], acknowledge?: true},
    %{id: :adjourned_counted_as_draw, vcl: [158, 167], acknowledge?: false},
    %{id: :adjourned_standings_not_final, vcl: [161, 169], acknowledge?: false},
    %{id: :adjourned_trf_not_final, vcl: [164, 165, 169], acknowledge?: false}
  ]

  @doc "Every warning this feature can raise, with the VCL question it answers."
  def warnings, do: @warnings

  @doc "The ids of the warnings an action waits on the arbiter to confirm."
  def acknowledgement_ids do
    for %{acknowledge?: true, id: id} <- @warnings, do: id
  end

  @doc """
  Every open postponed game in `tournament`, oldest round first, as
  `%{round: n, pairing: %Pairing{}}` with both players preloaded.
  """
  def open_games(%Tournament{id: id}), do: open_games(id)

  def open_games(tournament_id) when is_integer(tournament_id) do
    postponed = Results.postponed()

    Repo.all(
      from p in Pairing,
        join: r in Round,
        on: p.round_id == r.id,
        where: r.tournament_id == ^tournament_id and p.result == ^postponed,
        order_by: [r.number, p.board],
        preload: [:white_player, :black_player],
        select: %{round: r.number, pairing: p}
    )
  end

  @doc "How many postponed games are still open in `tournament`."
  def open_count(%Tournament{id: id}), do: open_count(id)

  def open_count(tournament_id) when is_integer(tournament_id) do
    postponed = Results.postponed()

    Repo.aggregate(
      from(p in Pairing,
        join: r in Round,
        on: p.round_id == r.id,
        where: r.tournament_id == ^tournament_id and p.result == ^postponed
      ),
      :count
    )
  end

  @doc """
  Whether anything computed from `tournament`'s results may call itself
  final: `false` while a postponed game is open, whatever round it is in.
  """
  def final?(tournament), do: open_count(tournament) == 0

  @doc """
  The warnings that apply to pairing `tournament`'s next round, as
  `%{id: atom, ...details}` maps.

    * `:missing_results_recorded_as_adjourned` - the last paired round
      still has boards with two players and no result. Pairing records them
      as postponed first (Q159) once the arbiter has confirmed it (Q160).
      Offered only when that would complete the round: a vacated seat has
      no second player to postpone a game with, and still has to be
      resolved on the board first.
    * `:adjourned_older_round_open` - a postponed game from a round before
      the last paired one is still open (Q168).
    * `:adjourned_counted_as_draw` - a postponed game in the last paired
      round; a notice that it counts as a draw for this pairing (Q158, Q167).

  Empty for a round robin, whose schedule does not depend on results, and
  before round 1. `open` is `open_games/1`'s answer when the caller already
  has it (the Pairings page lists the same games), so it is not asked twice.
  """
  def pairing_warnings(tournament, open \\ nil)

  def pairing_warnings(%Tournament{pairing_system: "round_robin"}, _open), do: []

  def pairing_warnings(%Tournament{} = tournament, open) do
    last = last_paired_round(tournament.id)

    if last == 0 do
      []
    else
      missing_warning(tournament.id, last) ++
        open_warnings(open || open_games(tournament.id), last)
    end
  end

  defp missing_warning(tournament_id, last) do
    blanks =
      Repo.all(
        from p in Pairing,
          join: r in Round,
          on: p.round_id == r.id,
          where: r.tournament_id == ^tournament_id and r.number == ^last and p.result == "",
          select: {p.white_player_id, p.black_player_id}
      )

    cond do
      blanks == [] -> []
      Enum.any?(blanks, fn {w, b} -> is_nil(w) or is_nil(b) end) -> []
      true -> [%{id: :missing_results_recorded_as_adjourned, round: last, count: length(blanks)}]
    end
  end

  defp open_warnings(open, last) do
    {older, current} = Enum.split_with(open, &(&1.round < last))

    older_warning =
      if older == [],
        do: [],
        else: [
          %{
            id: :adjourned_older_round_open,
            rounds: older |> Enum.map(& &1.round) |> Enum.uniq(),
            count: length(older)
          }
        ]

    current_warning =
      if current == [],
        do: [],
        else: [%{id: :adjourned_counted_as_draw, round: last, count: length(current)}]

    older_warning ++ current_warning
  end

  defp last_paired_round(tournament_id) do
    Repo.one(from r in Round, where: r.tournament_id == ^tournament_id, select: max(r.number)) ||
      0
  end

  @doc """
  The warnings that apply to writing `result` over the board as it is
  STORED now - read fresh, because the struct a page holds can be older
  than the database, and a stale blank must not hide a postponed game.

  One today: `:adjourned_non_draw_result` (Q163), when a postponed game gets
  a result that is not a draw for both players. Every round paired since
  counted it as a draw, and those pairings stand; the arbiter confirms that
  they know. A draw, clearing the board and re-postponing it need no
  confirmation - none of them changes a score any pairing was made with.
  """
  def result_warnings(%Pairing{id: id}, result) do
    stored = Repo.one(from p in Pairing, where: p.id == ^id, select: p.result)

    if Results.postponed?(stored) and result not in ["", nil] and not Results.postponed?(result) and
         not Results.draw_for_both?(result) do
      [:adjourned_non_draw_result]
    else
      []
    end
  end

  @doc """
  `:ok` when every warning in `warnings` (ids or `%{id: ...}` maps) that
  waits on the arbiter is in `acknowledged`, otherwise
  `{:error, {:needs_acknowledgement, ids}}` naming the ones that are not.
  Notices are never waited on.
  """
  def check_acknowledged(warnings, acknowledged) do
    missing =
      warnings
      |> Enum.map(&warning_id/1)
      |> Enum.filter(&(&1 in acknowledgement_ids()))
      |> Enum.reject(&(&1 in acknowledged))
      |> Enum.uniq()

    if missing == [], do: :ok, else: {:error, {:needs_acknowledgement, missing}}
  end

  defp warning_id(%{id: id}), do: id
  defp warning_id(id) when is_atom(id), do: id

  @doc """
  Records every two-player board of `round_number` that has no result as a
  postponed game (Q159), through `Tournaments.update_pairing_result/3` like
  every other result write. Returns `{:ok, pairing_ids}` - the boards it
  wrote, so a pairing run that then fails can put them back with
  `clear/1` - or the first write's error.
  """
  def record_missing(%Tournament{} = tournament, round_number) do
    blanks =
      Repo.all(
        from p in Pairing,
          join: r in Round,
          on: p.round_id == r.id,
          where:
            r.tournament_id == ^tournament.id and r.number == ^round_number and p.result == "" and
              not is_nil(p.white_player_id) and not is_nil(p.black_player_id)
      )

    Enum.reduce_while(blanks, {:ok, []}, fn pairing, {:ok, ids} ->
      case PairingsEngine.Tournaments.update_pairing_result(pairing, Results.postponed()) do
        {:ok, _} -> {:cont, {:ok, [pairing.id | ids]}}
        {:error, reason} -> {:halt, {:error, reason, ids}}
      end
    end)
    |> case do
      {:ok, ids} ->
        {:ok, Enum.reverse(ids)}

      # One write refused (a locked database, a hand-off landing mid-run):
      # the boards already recorded go back too, so a refusal leaves the
      # round exactly as the arbiter left it.
      {:error, reason, ids} ->
        clear(ids)
        {:error, reason}
    end
  end

  @doc """
  Puts boards `record_missing/2` postponed back to no result - the undo for
  a pairing run that failed after the missing results were recorded, so a
  refused round leaves the tournament exactly as it found it.
  """
  def clear(pairing_ids) do
    postponed = Results.postponed()

    for pairing <- Repo.all(from p in Pairing, where: p.id in ^pairing_ids),
        pairing.result == postponed do
      PairingsEngine.Tournaments.update_pairing_result(pairing, "")
    end

    :ok
  end
end
