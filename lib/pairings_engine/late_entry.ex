defmodule PairingsEngine.LateEntry do
  @moduledoc """
  Rounds before a late entrant joins, counted as absences.

  A player's `start_round` is the first round they are in the tournament.
  Nothing is stored for the rounds before it: `Pairing` leaves them out of
  those rounds and writes no `byes` row for them. What such a round is WORTH
  is the tournament's `late_entry_absences` setting:

    * **On, in a tournament that pays points for an absence** (`abs_value`
      > 0, Swiss, individual - `applies?/1`): every round before
      `start_round` is a plain absence, exactly like a registered player
      marked absent for it. It is scored at `abs_value` under the same two
      caps (`abs_jusque`, and the `abs_nbfois` allowance it uses up),
      treated for tie-breaks as `absent_counts_as_vur` says, and counts in
      the score the next round is paired on. This is what SWAR does: a
      player added after rounds were paired gets an absent round record for
      each of them (`JoueurInit`, Joueur.cpp:581-596, `Table = TABLE_ABSENT`)
      and `GetPoints` pays those at `AbsValue` with the `AbsJusque` /
      `AbsNbFois` caps (Utils.cpp:1254-1257 via `GetSpecialAbsValue`,
      1159-1170, whose `GetNbAbsence` counts them, 1102-1118).
    * **Otherwise** - off, or a tournament paying nothing for an absence
      (every FIDE-style event): the round is worth nothing, as C.07 16.1.2
      reads it, and it is not an absence.

  ## Derived, not stored

  The absences are worked out whenever a score is read, from the rounds
  that exist and each player's `start_round`, and never written as `byes`
  rows - so changing the setting, `abs_value` or a player's `start_round`
  rescores the tournament at once, a backup carries only what was entered,
  and there is nothing to keep in step. A round in which the player has a
  board or a `byes` row of their own is theirs, not one of these.

  Every place a score or a round's result is derived asks this module:
  `Standings` (and through it the crosstable, player card, printed lists,
  tie-breaks and the OpenResults standings), the absence counts the caps
  are measured with (`Standings.absent_counts/1`), the pairing input and
  TRF export (`Pairing`'s shared history), the OpenResults round lists
  (`Snapshot`), the SWAR export and SWAR's results pages.

  Keizer is not covered: its ladder pays an excused absence a third of the
  player's own value, never `abs_value`, and already scores a round before
  `start_round` as not joined (`Keizer.score_round/5`). A round robin's
  schedule has no late entrants. Both are left alone by `applies?/1`.
  """

  use Gettext, backend: PairingsEngineWeb.Gettext

  import Ecto.Query

  alias PairingsEngine.Repo
  alias PairingsEngine.Standings
  alias PairingsEngine.Tournaments.{Pairing, Player, Round, Tournament}

  @doc """
  Whether rounds before a player's `start_round` count as absences in
  `tournament`: the setting is on, an absence pays points (`abs_value` >
  0), and it is an individual Swiss tournament.
  """
  def applies?(%{late_entry_absences: false}), do: false

  def applies?(%{abs_value: value, pairing_system: "swiss"} = tournament)
      when is_number(value) and value > 0,
      do: not Tournament.team?(tournament)

  def applies?(_tournament), do: false

  @doc "The player's first round (1 when unset)."
  def start_round(%{start_round: start}) when is_integer(start) and start > 1, do: start
  def start_round(_player), do: 1

  @doc """
  The absences `tournament` owes its late entrants, as `byes`-row-shaped
  maps (`%{player_id:, round:, type: "absent", late_entry: true}`), from
  data the caller already holds:

    * `players` - anything with `:id` and `:start_round`;
    * `round_numbers` - the rounds that exist (paired, with or without
      results);
    * `taken` - a `MapSet` of `{player_id, round}` already holding a board
      or a `byes` row, which are the player's own and never replaced.

  `[]` whenever `applies?/1` is false.
  """
  def absences(tournament, players, round_numbers, taken) do
    if applies?(tournament) do
      for player <- players,
          start = start_round(player),
          start > 1,
          round <- round_numbers,
          round < start,
          not MapSet.member?(taken, {player.id, round}),
          do: %{player_id: player.id, round: round, type: "absent", late_entry: true}
    else
      []
    end
  end

  @doc """
  `absences/4` for the whole of `tournament`, read from the database -
  for a caller without the rounds in hand. `through_round: n` stops at
  round `n`. Costs nothing but the setting check when it does not apply,
  and one small query when nobody joined late.
  """
  def absences(tournament, opts \\ []) do
    through = Keyword.get(opts, :through_round)

    with true <- applies?(tournament),
         [_ | _] = late <- late_players(tournament.id) do
      numbers = round_numbers(tournament.id, through)
      absences(tournament, late, numbers, taken(tournament.id, late))
    else
      _ -> []
    end
  end

  @doc """
  `absences/2` for one round, in the shape `Tournaments.list_byes_for_round/2`
  returns (each with its `:player` preloaded), for the pages that list a
  round's absences.
  """
  def absences_for_round(tournament, round_number) do
    rows =
      Enum.filter(absences(tournament, through_round: round_number), &(&1.round == round_number))

    case rows do
      [] ->
        []

      rows ->
        players = Map.new(late_players(tournament.id), &{&1.id, &1})
        Enum.map(rows, &Map.put(&1, :player, Map.fetch!(players, &1.player_id)))
    end
  end

  defp late_players(tournament_id) do
    Repo.all(from p in Player, where: p.tournament_id == ^tournament_id and p.start_round > 1)
  end

  defp round_numbers(tournament_id, through) do
    query = from r in Round, where: r.tournament_id == ^tournament_id, select: r.number

    query = if through, do: from(r in query, where: r.number <= ^through), else: query

    Repo.all(query)
  end

  # Every round in which one of `players` already sits at a board or has a
  # `byes` row of their own.
  defp taken(tournament_id, players) do
    ids = Enum.map(players, & &1.id)

    seats =
      Repo.all(
        from p in Pairing,
          join: r in Round,
          on: r.id == p.round_id,
          where:
            r.tournament_id == ^tournament_id and
              (p.white_player_id in ^ids or p.black_player_id in ^ids),
          select: {r.number, p.white_player_id, p.black_player_id}
      )
      |> Enum.flat_map(fn {n, w, b} -> [{w, n}, {b, n}] end)

    byes =
      Repo.all(
        from b in "byes",
          where: b.tournament_id == ^tournament_id and b.player_id in ^ids,
          select: {b.player_id, b.round}
      )

    MapSet.new(seats ++ byes)
  end

  @doc """
  `{player_id, round}` for every board seat and `byes` row in `rounds`
  (preloaded with `:pairings`) and `byes` - the `taken` set `absences/4`
  wants, for a caller that has read both already.
  """
  def taken_from(rounds, byes) do
    seats =
      for round <- rounds,
          pairing <- round.pairings,
          id <- [pairing.white_player_id, pairing.black_player_id],
          not is_nil(id),
          do: {id, round.number}

    MapSet.new(seats ++ Enum.map(byes, &{&1.player_id, &1.round}))
  end

  @doc """
  For a player who starts in round 1: how many of the tournament's first
  rounds they have nothing at all in - no board, no `byes` row. `0` for
  anyone else.

  Nobody present when a round was paired ends up with nothing in it (an
  active player is paired, anybody else gets a `byes` row), so a run of
  empty rounds at the start is almost always a player added after they
  were paired - before the Players page could say so. The dialog offers
  the round after them as the player's start round; it is never set
  without the organiser.
  """
  def unrecorded_leading_rounds(%{start_round: start}, _tournament_id)
      when is_integer(start) and start > 1,
      do: 0

  def unrecorded_leading_rounds(%{id: player_id}, tournament_id) do
    numbers =
      Repo.all(
        from r in Round,
          where: r.tournament_id == ^tournament_id,
          order_by: r.number,
          select: r.number
      )

    taken = taken(tournament_id, [%{id: player_id}])

    numbers
    |> Enum.with_index(1)
    |> Enum.take_while(fn {number, expected} ->
      number == expected and not MapSet.member?(taken, {player_id, number})
    end)
    |> length()
  end

  ## ---------- what the organiser is told ----------

  @doc """
  One line for the organiser about a player joining in `start` - what the
  rounds before it count as, worked out with the caps - or `nil` when the
  player starts in round 1.

  With the absences on: "Rounds 1-3 count as absences: 1.5 points, no
  absences left." Otherwise: "Rounds 1-3 are before this player joins and
  score nothing." When `absent_rounds` (the player's own "absent at the
  rounds" text) names a round before `start`, a sentence says what happens
  to it, so an entry that no longer does anything is never silently eaten.
  """
  def note(tournament, start, absent_rounds \\ "")

  def note(tournament, start, absent_rounds) when is_integer(start) and start > 1 do
    before = Enum.to_list(1..(start - 1))
    early = Enum.filter(Player.parse_absent_rounds(absent_rounds || ""), &(&1 < start))

    [rounds_sentence(tournament, before), early_absence_sentence(tournament, early)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  def note(_tournament, _start, _absent_rounds), do: nil

  defp rounds_sentence(tournament, before) do
    span = span(before)
    count = length(before)

    if applies?(tournament) do
      {points, _used} =
        Enum.reduce(before, {0.0, 0}, fn round, {sum, used} ->
          used = used + 1
          {sum + Standings.bye_points("absent", tournament, round, used), used}
        end)

      [
        ngettext(
          "Round %{rounds} counts as an absence: %{points}",
          "Rounds %{rounds} count as absences: %{points}",
          count,
          rounds: span,
          points: points_text(points)
        ),
        allowance_text(tournament, count)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")
      |> Kernel.<>(".")
    else
      ngettext(
        "Round %{rounds} is before this player joins and scores nothing.",
        "Rounds %{rounds} are before this player joins and score nothing.",
        count,
        rounds: span
      )
    end
  end

  defp early_absence_sentence(_tournament, []), do: nil

  defp early_absence_sentence(tournament, early) do
    if applies?(tournament) do
      gettext("The absence entered for round %{rounds} is already one of them.",
        rounds: Enum.join(early, ", ")
      )
    else
      gettext(
        "The absence entered for round %{rounds} is before this player joins, so it is not counted.",
        rounds: Enum.join(early, ", ")
      )
    end
  end

  # How much of the `abs_nbfois` allowance the rounds before joining leave;
  # nothing to say when the tournament does not limit it.
  defp allowance_text(%{abs_nbfois: cap}, used) when is_integer(cap) do
    case cap - used do
      left when left <= 0 -> gettext("no absences left")
      left -> ngettext("1 absence left", "%{count} absences left", left)
    end
  end

  defp allowance_text(_tournament, _used), do: nil

  defp points_text(points) do
    ngettext("%{points} point", "%{points} points", if(points == 1.0, do: 1, else: 2),
      points: format_points(points)
    )
  end

  defp format_points(points) when points == trunc(points), do: Integer.to_string(trunc(points))
  defp format_points(points), do: :erlang.float_to_binary(points * 1.0, [:compact, decimals: 2])

  defp span([round]), do: Integer.to_string(round)
  defp span([first | _] = rounds), do: "#{first}-#{List.last(rounds)}"
end
