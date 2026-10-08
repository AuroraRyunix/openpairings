defmodule PairingsEngine.ByeTypes do
  @moduledoc """
  "Ask the bye type for each absence" (`tournaments.ask_bye_type`, off by
  default). Off, a round a player is marked absent for ahead of its pairing
  is worth what the tournament pays an absence (`abs_value`, under its
  caps) and the pairing files it as a plain `"absent"` row. On, the player
  dialog asks which bye it is - half-point, zero-point or full-point - with
  the answer the absence value would have given already picked, and the
  answer is stored as the typed `byes` row for that round.

  A typed row is the same row a TRF import writes for a bye granted ahead
  (`TrfImport`'s `import_future_byes/4`), so everything after it already
  knows the shape: the pairing writes its absentees `on_conflict: :nothing`
  and the typed row stands; an unpairing keeps it (`Pairing`'s
  `granted_bye_ids/2`); taking the round out of `absent_rounds` drops it
  (`Tournaments`' `drop_withdrawn_future_byes/1`); the export writes it as
  its own letter (`TrfExport`'s future byes, `240` in TRF26).

  Only in an individual Swiss. A round robin pairs everybody, and a team
  event's absences are line-ups, not byes.
  """
  import Ecto.Query

  alias PairingsEngine.Repo
  alias PairingsEngine.Standings
  alias PairingsEngine.Tournaments.{Player, Tournament}

  @types ~w(requested-half requested-zero full-point)
  # The picks that pay: they stand in for a paid absence when the
  # pre-picked answer is worked out (`dialog_plan/4`).
  @paid ~w(requested-half full-point)

  @doc "The bye types the dialog offers, as stored in the `byes` table."
  def types, do: @types

  @doc "Whether `tournament` asks the bye type for each absence."
  def applies?(%{ask_bye_type: true, pairing_system: "swiss"} = tournament),
    do: not Tournament.team?(tournament)

  def applies?(_tournament), do: false

  @doc "Whether the setting can mean anything in `tournament` (shown on Settings)."
  def possible?(%{pairing_system: "swiss"} = tournament), do: not Tournament.team?(tournament)
  def possible?(_tournament), do: false

  @doc """
  The type an absence in `round` gets when nobody picks one: what the
  tournament pays for it (`Standings.bye_points/4` with `nth` the absence's
  position for the count cap), half a point or a win's worth by name, and
  anything else a zero-point bye.
  """
  def default_type(tournament, round, nth) do
    points = Standings.bye_points("absent", tournament, round, nth)

    cond do
      points == tournament.points_draw and points != tournament.points_loss -> "requested-half"
      points == tournament.points_win and points != tournament.points_loss -> "full-point"
      true -> "requested-zero"
    end
  end

  @doc """
  The typed rows a player has, `%{round => type}`, for every round (paired
  or not). Only the three types the dialog offers.
  """
  def stored(_tournament_id, nil), do: %{}

  def stored(tournament_id, player_id) do
    from(b in "byes",
      where: b.tournament_id == ^tournament_id and b.player_id == ^player_id and b.type in @types,
      select: {b.round, b.type}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  `%{round => type}` the dialog shows for the rounds of `absent_rounds`
  (canonical text) after the last paired one, before anything is picked:
  see `dialog_plan/4`. `%{}` where the setting is off.
  """
  def dialog_types(tournament, %Player{} = player, absent_rounds) do
    tournament
    |> dialog_plan(player, absent_rounds, %{})
    |> Map.new(fn {round, type, _nth} -> {round, type} end)
  end

  @doc """
  `[{round, type, nth}]`, by round, for the rounds of `absent_rounds` not
  yet paired: the type picked in the form (`picked`), else the stored one,
  else the pre-picked answer; and `nth`, which absence this is for the
  count cap when working out that answer.

  A picked bye is not an absence and the standings never count it against
  the cap. The pre-picked answer does, though - otherwise the cap would
  never change what is offered, and going past it would stop being
  something the arbiter chose. So `nth` counts the plain absences recorded
  before the round, as the standings do, plus every PAID bye before it
  (half-point or full-point; picked, stored, or about to be), each where a
  plain absence would have stood. A zero-point bye pays nothing and uses
  nothing up. `[]` where the setting is off.
  """
  def dialog_plan(tournament, %Player{} = player, absent_rounds, picked) do
    if applies?(tournament) do
      paired = Standings.rounds_paired(tournament.id)
      stored = stored(tournament.id, player.id)
      used = used_before(tournament, player.id, paired + 1, stored)

      absent_rounds
      |> to_string()
      |> Player.parse_absent_rounds()
      |> Enum.filter(&(&1 > paired))
      |> Enum.sort()
      |> Enum.map_reduce(used, fn round, used ->
        nth = used + 1

        type =
          Map.get(picked, round) || Map.get(stored, round) ||
            default_for(tournament, player, round, nth)

        {{round, type, nth}, if(type in @paid, do: used + 1, else: used)}
      end)
      |> elem(0)
    else
      []
    end
  end

  @doc """
  Which absence of the player's one in `round` would be, for the pre-picked
  answer: the plain absences and the paid byes before it, plus this one.
  For a seat emptied in a paired round.
  """
  def next_absence_nth(tournament, player_id, round),
    do: used_before(tournament, player_id, round, stored(tournament.id, player_id)) + 1

  # The plain absences recorded before `round` (`Standings.absent_counts/1`,
  # late entrants' rounds included) plus the paid byes in the byes table
  # before it.
  defp used_before(tournament, player_id, round, stored) do
    paid = Enum.count(stored, fn {r, type} -> r < round and type in @paid end)
    recorded_absences(tournament, player_id, round) + paid
  end

  @doc """
  The type pre-picked for `player`'s absence in `round` (the `nth` one):
  the absence value's, with the zero for a player who may not have a
  half-point bye.
  """
  def default_for(tournament, %Player{} = player, round, nth),
    do: eligible(default_type(tournament, round, nth), player)

  @doc "Points a bye of `type` is worth in `tournament`."
  def points(tournament, type), do: Standings.bye_points(type, tournament)

  @doc """
  Whether picking `type` for the `nth` absence, in `round`, pays more than
  the two limits on paid absences leave it: the limits cut the absence
  value there, and the pick is worth more than what is left. Said, never
  refused: going past the limits is the arbiter's call to make.
  """
  def above_limits?(tournament, round, nth, type) do
    capped = Standings.bye_points("absent", tournament, round, nth)
    uncapped = Standings.bye_points("absent", tournament)
    capped < uncapped and points(tournament, type) > capped
  end

  # A player marked not eligible for half-point byes (C.05:6.7.4) would
  # only have the pre-picked answer refused on Save; offer the zero instead.
  defp eligible("requested-half", %Player{no_half_bye: true}), do: "requested-zero"
  defp eligible(type, _player), do: type

  # The absences already used up against the count cap before `round`, as
  # the export's future byes count them (`TrfExport`'s
  # `dialog_future_byes/3`).
  defp recorded_absences(tournament, player_id, round) do
    for {{^player_id, r}, running} <- Standings.absent_counts(tournament),
        r < round,
        reduce: 0 do
      acc -> max(acc, running)
    end
  end

  @doc """
  The `"bye_types"` a form posted (`%{"5" => "requested-half"}`), as
  `%{5 => "requested-half"}`. Anything that is not a round number and one
  of `types/0` is dropped - it arrives from a browser.
  """
  def parse(%{} = params) do
    for {round, type} <- params,
        type in @types,
        {n, ""} <- [Integer.parse(to_string(round))],
        n > 0,
        into: %{},
        do: {n, type}
  end

  def parse(_params), do: %{}

  @doc """
  The bye types `attrs` (a player dialog's params) chooses, `%{}` when the
  tournament does not ask.
  """
  def chosen(tournament, attrs) do
    if applies?(tournament) do
      attrs |> Map.get("bye_types", Map.get(attrs, :bye_types)) |> parse()
    else
      %{}
    end
  end

  @doc """
  Writes `chosen` (`%{round => type}`) for `player` as typed `byes` rows,
  for the rounds that are in the player's `absent_rounds` and not yet
  paired - a paired round's bye is the Pairings page's business. A row
  already there for the round is replaced, whatever it was.
  """
  def write(%Tournament{} = tournament, %Player{} = player, chosen) do
    if applies?(tournament) and chosen != %{} and not player.absent do
      paired = Standings.rounds_paired(tournament.id)
      absent = Player.parse_absent_rounds(to_string(player.absent_rounds))

      rows =
        for {round, type} <- chosen,
            round > paired,
            round in absent,
            do: %{tournament_id: tournament.id, player_id: player.id, round: round, type: type}

      if rows != [] do
        rounds = Enum.map(rows, & &1.round)

        Repo.delete_all(from b in "byes", where: b.player_id == ^player.id and b.round in ^rounds)

        Repo.insert_all("byes", rows)
      end
    end

    :ok
  end
end
