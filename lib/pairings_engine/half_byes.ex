defmodule PairingsEngine.HalfByes do
  @moduledoc """
  Half-point byes (C.05:6.7.4) as this app records them: a round in a
  player's `absent_rounds` whose absence the tournament scores as a draw
  (`Standings.bye_points/4` with the tournament's absence points at the draw
  value, under its round and count caps), plus any `"requested-half"` row in
  the byes table (imports write those).

  Two rules hang on it (VCL4THP Q174/Q175): a second or later half-point bye
  needs the arbiter's explicit confirmation, and a player marked
  `no_half_bye` ("not eligible", having received conditions or free entry)
  gets none.

  A round with a typed `byes` row - imported, or picked in the player
  dialog under "Ask the bye type for each absence"
  (`PairingsEngine.ByeTypes`) - is the bye its row says, not what the
  absence value would make of it: a zero-point bye in a tournament paying
  half a point for an absence is not a half-point bye.
  """
  import Ecto.Query

  alias PairingsEngine.ByeTypes
  alias PairingsEngine.Repo
  alias PairingsEngine.Standings
  alias PairingsEngine.Tournaments.Player

  @doc """
  The rounds of `absent_rounds` (the stored text) that the tournament scores
  as half a point, ascending. The count cap works on the position among the
  player's own absences, as `Standings.bye_points_for_row/2` counts them.
  """
  def half_rounds(tournament, absent_rounds, typed \\ %{}) do
    absent_rounds
    |> to_string()
    |> Player.parse_absent_rounds()
    |> Enum.sort()
    |> Enum.with_index(1)
    |> Enum.filter(fn {round, nth} ->
      case Map.get(typed, round) do
        nil -> Standings.bye_points("absent", tournament, round, nth) == tournament.points_draw
        type -> type == "requested-half"
      end
    end)
    |> Enum.map(&elem(&1, 0))
  end

  @doc "The rounds the byes table holds a requested half-point bye for `player_id`."
  def recorded_rounds(tournament_id, player_id) do
    Repo.all(
      from(b in "byes",
        where:
          b.tournament_id == ^tournament_id and b.player_id == ^player_id and
            b.type == "requested-half",
        select: b.round
      )
    )
  end

  @doc """
  Every round `player` already has a half-point bye in: a requested one in
  the byes table, a plain absence the tournament scores as a draw (a seat
  emptied on the Pairings page), and the coming rounds of `absent_rounds`
  that will score as one. For a half-point bye given in a paired round,
  which `added_beyond_first/4` - built around the dialog's text field -
  does not see.
  """
  def taken_rounds(tournament, %Player{} = player) do
    counts = Standings.absent_counts(tournament)

    rows =
      Repo.all(
        from(b in "byes",
          where:
            b.tournament_id == ^tournament.id and b.player_id == ^player.id and
              b.type in ["requested-half", "absent"],
          select: %{type: b.type, round: b.round, player_id: b.player_id}
        )
      )
      |> Enum.filter(fn
        %{type: "requested-half"} ->
          true

        row ->
          Standings.bye_points_for_row(row, tournament, counts) == tournament.points_draw
      end)
      |> Enum.map(& &1.round)

    planned =
      half_rounds(tournament, player.absent_rounds, ByeTypes.stored(tournament.id, player.id))

    Enum.uniq(rows ++ planned)
  end

  @doc """
  The half-point bye rounds a save would ADD to `player` when `absent_rounds`
  (canonical text) replaces the stored ones, but only when that leaves the
  player with a second or later one. `[]` otherwise.
  """
  def added_beyond_first(tournament, %Player{} = player, absent_rounds, chosen \\ %{}) do
    stored = ByeTypes.stored(tournament.id, player.id)
    before = half_rounds(tournament, player.absent_rounds, stored)
    later = half_rounds(tournament, absent_rounds, Map.merge(stored, chosen))
    added = later -- before

    if added != [] and total(tournament, player, later, chosen) >= 2, do: added, else: []
  end

  # A recorded half-point bye the dialog is re-typing into something else
  # is about to stop being one, so it is not counted.
  defp total(tournament, player, rounds, chosen) do
    recorded =
      if player.id,
        do:
          tournament.id
          |> recorded_rounds(player.id)
          |> Enum.filter(&(Map.get(chosen, &1, "requested-half") == "requested-half")),
        else: []

    length(Enum.uniq(rounds ++ recorded))
  end
end
