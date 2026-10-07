defmodule PairingsEngine.StartingNumbers do
  @moduledoc """
  The arbiter's own starting numbers for an individual round robin, set
  before round 1 is paired - by hand, or by a drawing of lots.

  FIDE's General Regulations for Competitions (C.05 6.2-6.3) give a round
  robin's first-round pairings to a drawing of lots, open to the players; the
  numbers it draws are the Berger table's numbers. Without this the numbers
  could only come from the rating order (`Pairing.ensure_pairing_numbers/2`)
  or from an imported file, so the result of a public draw had nowhere to
  go (VCL4THP Q95).

  The numbers are stored where they always were, `players.pairing_number`,
  the field a TRF or SWAR import already fills for a round robin.
  `PairingsEngine.RoundRobin` uses numbers it finds instead of computing
  them, and numbers anybody still without one after them (a later entry)
  when round 1 is paired. Once a round exists they are the schedule, and
  this module refuses to change them; unpairing back to nothing opens them
  again.

  Every write numbers the whole pool 1..N in one go - the active players
  (`Pairing.active_players/1`), the ones a first pairing would number - and
  takes the number off anybody else (withdrawn, absent for the whole event),
  so two players never share a number and nobody outside the pool is
  scheduled. "Order by rating" takes every number off: round 1 then numbers
  the field by rating exactly as it did before this existed.
  """

  import Ecto.Query

  alias PairingsEngine.Pairing, as: Engine
  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Player, Round, Tournament}

  @doc """
  Whether `tournament`'s starting numbers can be set now: an individual
  round robin (a team round robin orders its teams on the Teams page) with
  no round paired.
  """
  def editable?(%Tournament{} = tournament) do
    applies?(tournament) and
      not Repo.exists?(from r in Round, where: r.tournament_id == ^tournament.id)
  end

  @doc "Whether starting numbers are an individual round robin's to set at all."
  def applies?(%Tournament{} = tournament) do
    tournament.pairing_system == "round_robin" and not Tournament.team?(tournament)
  end

  @doc """
  The pool in starting order, as `[{player, number}]`: players who have a
  number by it, then the ones without in the order round 1 would number
  them (`Pairing.initial_order/1`), numbered on from there. Exactly the
  numbers pairing round 1 would freeze now.
  """
  def order(%Tournament{} = tournament) do
    {numbered, unnumbered} =
      tournament.id
      |> Engine.active_players()
      |> Enum.split_with(&is_integer(&1.pairing_number))

    (Enum.sort_by(numbered, &{&1.pairing_number, &1.name, &1.id}) ++
       Engine.initial_order(unnumbered))
    |> Enum.with_index(1)
  end

  @doc "True when the arbiter has set the numbers (by hand or by lot)."
  def set_by_hand?(%Tournament{} = tournament) do
    Repo.exists?(
      from p in Player,
        where: p.tournament_id == ^tournament.id and not is_nil(p.pairing_number)
    )
  end

  @doc """
  Moves `player_id` one place up or down the starting order.
  """
  def move(%Tournament{} = tournament, player_id, direction) when direction in [:up, :down] do
    ids = current_ids(tournament)

    case Enum.find_index(ids, &(&1 == player_id)) do
      nil ->
        {:error, :not_found}

      index ->
        target = if direction == :up, do: index - 1, else: index + 1
        move_to_index(tournament, ids, index, target)
    end
  end

  @doc """
  Gives `player_id` starting number `number`; the players between its old
  and new place shift by one, as when a card is moved in a deck.
  """
  def move_to(%Tournament{} = tournament, player_id, number) when is_integer(number) do
    ids = current_ids(tournament)

    case Enum.find_index(ids, &(&1 == player_id)) do
      nil -> {:error, :not_found}
      index -> move_to_index(tournament, ids, index, number - 1)
    end
  end

  defp move_to_index(tournament, ids, index, target) do
    if target < 0 or target >= length(ids) do
      {:error, :out_of_range}
    else
      {id, rest} = List.pop_at(ids, index)
      set_order(tournament, List.insert_at(rest, target, id))
    end
  end

  @doc """
  Numbers the pool by a drawing of lots. `shuffle` is injectable so a test
  decides the draw; the default is `Enum.shuffle/1`.
  """
  def draw_lots(%Tournament{} = tournament, shuffle \\ &Enum.shuffle/1) do
    set_order(tournament, shuffle.(current_ids(tournament)))
  end

  @doc """
  Takes every number off, so round 1 numbers the field by rating
  (`Pairing.ensure_pairing_numbers/2`) as it does when nobody set any.
  """
  def by_rating(%Tournament{} = tournament) do
    with :ok <- guard(tournament) do
      Repo.update_all(
        from(p in Player, where: p.tournament_id == ^tournament.id),
        set: [pairing_number: nil]
      )

      Tournaments.broadcast_tournament_change(tournament.id, :players)
      {:ok, order(tournament)}
    end
  end

  @doc """
  Numbers the pool 1..N in the order of `ids`, which must be exactly the
  pool's player ids; everybody else's number is taken off. Returns
  `{:ok, order}` (`order/1`'s shape) or `{:error, reason}`.
  """
  def set_order(%Tournament{} = tournament, ids) when is_list(ids) do
    with :ok <- guard(tournament),
         :ok <- same_pool(tournament, ids) do
      Repo.transaction(fn ->
        Repo.update_all(
          from(p in Player, where: p.tournament_id == ^tournament.id and p.id not in ^ids),
          set: [pairing_number: nil]
        )

        ids
        |> Enum.with_index(1)
        |> Enum.each(fn {id, number} ->
          Repo.update_all(from(p in Player, where: p.id == ^id), set: [pairing_number: number])
        end)
      end)

      Tournaments.broadcast_tournament_change(tournament.id, :players)
      {:ok, order(tournament)}
    end
  end

  defp current_ids(tournament), do: tournament |> order() |> Enum.map(fn {p, _n} -> p.id end)

  defp guard(tournament) do
    cond do
      refusal = Tournaments.write_refused(tournament.id) -> refusal
      not applies?(tournament) -> {:error, :not_round_robin}
      not editable?(tournament) -> {:error, :round_paired}
      true -> :ok
    end
  end

  defp same_pool(tournament, ids) do
    pool = MapSet.new(current_ids(tournament))

    if length(ids) == MapSet.size(pool) and MapSet.new(ids) == pool,
      do: :ok,
      else: {:error, :stale_order}
  end
end
