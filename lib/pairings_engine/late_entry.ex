defmodule PairingsEngine.LateEntry do
  @moduledoc """
  Rounds before a late entrant joins, counted as absences.

  A player's join round is the first round they are in the tournament.
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

  ## The join round: set, or worked out

  A `start_round` above 1 is the organiser's word and always wins. A player
  whose `start_round` is 1 - every player added before "Joins in round"
  existed, and every accepted registration - has their join round worked
  out when it is read, never written (`effective_start_round/4`), in an
  individual Swiss event (`derives?/1`):

    * rows (a board, or a `byes` row of any kind) in round 1: round 1, as
      stored - nothing changes for anyone who was there from the start;
    * no row in rounds 1..k and one in round k + 1: round k + 1, the first
      round they have anything in;
    * no row at all yet: the next round to be paired, if they can be paired
      (status active, not forfeited) - a player added after round 3 joins
      in round 4. A withdrawn or forfeited player with nothing anywhere
      stays at round 1: they never joined, and their rounds score nothing,
      as before.

  Nobody present when a round was paired ends up with nothing in it (an
  active player is paired, and anyone else gets a `byes` row), so a run of
  empty rounds at the start can only be a player who was not there yet.
  Pairing ELIGIBILITY keeps reading the stored value
  (`Pairing.not_yet_started?/2`): a player with `start_round` 1 and no rows
  is paired in the next round, which is exactly the round this works out.
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

  @doc "The player's STORED first round (1 when unset) - see `effective_start_round/4`."
  def start_round(%{start_round: start}) when is_integer(start) and start > 1, do: start
  def start_round(_player), do: 1

  @doc """
  Whether a player's join round is worked out from their rounds when it is
  not set (see the moduledoc): an individual Swiss event. Keizer reads the
  stored value its own way, a round robin has no late entrants, and a team
  event's players are placed by their team.
  """
  def derives?(%{pairing_system: "swiss"} = tournament), do: not Tournament.team?(tournament)
  def derives?(_tournament), do: false

  @doc """
  The round `player` joined, for scoring, exports and display: the stored
  `start_round` when it is above 1, otherwise worked out from their rows
  (moduledoc). `round_numbers` are the rounds that exist (any order); `taken`
  is every `{player_id, round}` with a board or a `byes` row - ALL of the
  player's rounds, even when `round_numbers` stops early, so a player whose
  first game is after the cut-off is still read as having one.

  Returns `{round, how}` - `how` is `:set` (the stored value, including 1),
  `:first_game` or `:next_round`.
  """
  def effective_start_round(player, round_numbers, taken, seated \\ nil) do
    case start_round(player) do
      start when start > 1 ->
        {start, :set}

      1 ->
        leading = leading_empty_rounds(player.id, round_numbers, taken)
        seated = seated || MapSet.new(taken, &elem(&1, 0))

        cond do
          leading == 0 -> {1, :set}
          MapSet.member?(seated, player.id) -> {leading + 1, :first_game}
          pairable?(player) -> {leading + 1, :next_round}
          true -> {1, :set}
        end
    end
  end

  # How many of rounds 1, 2, 3 ... (as long as they exist, in order) the
  # player has nothing in.
  defp leading_empty_rounds(player_id, round_numbers, taken) do
    round_numbers
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.with_index(1)
    |> Enum.take_while(fn {number, expected} ->
      number == expected and not MapSet.member?(taken, {player_id, number})
    end)
    |> length()
  end

  # Could the next pairing seat them? The same test `Pairing.active_players/1`
  # and its absent twin make (a whole-event absentee is not paired but gets
  # a row every round, so is in the tournament all the same).
  defp pairable?(player),
    do: Map.get(player, :status, "active") == "active" and Map.get(player, :forfeit) != true

  @doc """
  The absences `tournament` owes its late entrants, as `byes`-row-shaped
  maps (`%{player_id:, round:, type: "absent", late_entry: true}`), from
  data the caller already holds:

    * `players` - anything with `:id` and `:start_round` (and `:status` /
      `:forfeit`, which a player with nothing recorded is judged by);
    * `round_numbers` - the rounds to score (paired, with or without
      results) - all of them, or those up to a cut-off;
    * `taken` - a `MapSet` of `{player_id, round}` already holding a board
      or a `byes` row, which are the player's own and never replaced. All
      rounds', not only those in `round_numbers`: it is also what an unset
      join round is worked out from (`effective_start_round/4`).

  `[]` whenever `applies?/1` is false.
  """
  def absences(tournament, players, round_numbers, taken) do
    if applies?(tournament) do
      seated = MapSet.new(taken, &elem(&1, 0))

      for player <- players,
          {start, _how} = effective_start_round(player, round_numbers, taken, seated),
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
  round `n`; `player_id: id` looks at that one player only. Costs nothing
  but the setting check when it does not apply, and one small query when
  nobody can have joined late (everyone has something in round 1).
  """
  def absences(tournament, opts \\ []) do
    through = Keyword.get(opts, :through_round)

    with true <- applies?(tournament),
         {[_ | _] = late, numbers, taken} <- late_field(tournament, opts[:player_id]) do
      numbers = if through, do: Enum.filter(numbers, &(&1 <= through)), else: numbers
      absences(tournament, late, numbers, taken)
    else
      _ -> []
    end
  end

  @doc """
  Every player of `tournament` who joins after round 1, as
  `%{player_id => {round, how}}` (`effective_start_round/4`) - a set round
  above 1, or one worked out in an individual Swiss event. For the pages
  and files that say when a player joined; the scores go through
  `absences/2`.
  """
  def effective_start_rounds(tournament, opts \\ []) do
    {players, numbers, taken} = late_field(tournament, opts[:player_id])
    seated = MapSet.new(taken, &elem(&1, 0))
    derive? = derives?(tournament)

    for player <- players,
        {start, how} =
          if(derive?,
            do: effective_start_round(player, numbers, taken, seated),
            else: {start_round(player), :set}
          ),
        start > 1,
        into: %{},
        do: {player.id, {start, how}}
  end

  @doc """
  For the player dialog: the join round worked out for `player` when their
  stored `start_round` is 1 - `{round, :first_game | :next_round}` - or
  `nil` when there is nothing to work out (set above 1, round 1 after all,
  or not an individual Swiss event).
  """
  def derived_start_round(tournament, %{id: player_id} = player) do
    if derives?(tournament) and start_round(player) == 1 do
      case tournament |> effective_start_rounds(player_id: player_id) |> Map.get(player_id) do
        {round, how} when how in [:first_game, :next_round] -> {round, how}
        _ -> nil
      end
    end
  end

  @doc """
  `players` with `start_round` replaced by the round each joined
  (`effective_start_rounds/2`) - a copy for a file or a page that SHOWS the
  join round, such as the players export. Never saved.
  """
  def with_effective_start_rounds(players, tournament) do
    starts = effective_start_rounds(tournament)

    Enum.map(players, fn p ->
      case Map.get(starts, p.id) do
        {start, _how} -> %{p | start_round: start}
        nil -> p
      end
    end)
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
        ids = rows |> Enum.map(& &1.player_id) |> Enum.uniq()
        players = Map.new(Repo.all(from p in Player, where: p.id in ^ids), &{&1.id, &1})
        Enum.map(rows, &Map.put(&1, :player, Map.fetch!(players, &1.player_id)))
    end
  end

  # The players who can be joining after round 1 - a set start round above
  # 1, or nothing at all in round 1 - with the rounds that exist and every
  # round they hold something in. Everyone who was there from round 1 is
  # left out by the query itself, so an ordinary tournament pays for one
  # query and nothing else.
  defp late_field(tournament, only) do
    tid = tournament.id

    seated_in_1 =
      from pr in Pairing,
        join: r in Round,
        on: r.id == pr.round_id,
        where:
          r.tournament_id == ^tid and r.number == 1 and
            (pr.white_player_id == parent_as(:player).id or
               pr.black_player_id == parent_as(:player).id),
        select: 1

    row_in_1 =
      from b in "byes",
        where: b.tournament_id == ^tid and b.round == 1 and b.player_id == parent_as(:player).id,
        select: 1

    query =
      from p in Player,
        as: :player,
        where:
          p.tournament_id == ^tid and
            (p.start_round > 1 or
               (not exists(subquery(seated_in_1)) and not exists(subquery(row_in_1))))

    query = if only, do: from(p in query, where: p.id == ^only), else: query

    case Repo.all(query) do
      [] -> {[], [], MapSet.new()}
      players -> {players, round_numbers(tid), taken(tid, players)}
    end
  end

  defp round_numbers(tournament_id) do
    Repo.all(
      from r in Round,
        where: r.tournament_id == ^tournament_id,
        order_by: r.number,
        select: r.number
    )
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
