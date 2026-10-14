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

  The same four ways of numbering are offered where the first pairing is
  asked for (`PairingsEngineWeb.PairingsLive`) and on the Players page:

    * `:rating` - `rating_ids/1`, `Pairing.initial_order/2`: Tournament
      Rating highest first, then FIDE title, then the tournament's
      initial-order tie-break (alphabetical unless another was chosen), then
      name, then id. Total, so the same field always numbers the same way.
    * `:entered` - `entry_ids/1`: the order the players were added to the
      tournament, which is ascending `players.id` (the database hands ids
      out in insertion order; there is no other reliable entry stamp, since
      `inserted_at` has a one-second grain and an import stamps a whole file
      with the same second). A tournament rebuilt from an export file is
      entered in that file's order, which is the Players list's rating
      order, so there "as entered" and "by rating" can coincide.
    * `:lots` - `lot_ids/2`: a drawing of lots done by the program from a
      seed. The seed and the resulting order are written to the audit trail,
      and `shuffle_by_seed/2` of the entry order with that seed gives the
      same order again.
    * `:set` - the numbers already on the players (set on the Players page,
      or carried in by an imported file).
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
  them (`Pairing.initial_order/2`), numbered on from there. Exactly the
  numbers pairing round 1 would freeze now.
  """
  def order(%Tournament{} = tournament) do
    {numbered, unnumbered} =
      tournament.id
      |> Engine.active_players()
      |> Enum.split_with(&is_integer(&1.pairing_number))

    (Enum.sort_by(numbered, &{&1.pairing_number, &1.name, &1.id}) ++
       Engine.initial_order(unnumbered, tournament))
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
  Numbers the pool by the drawing `seed` gives (`lot_ids/2`), so the draw
  can be repeated from the audit trail.
  """
  def draw_lots_seeded(%Tournament{} = tournament, seed) when is_integer(seed),
    do: set_order(tournament, lot_ids(tournament, seed))

  @doc "Numbers the pool in the order the players were entered (`entry_ids/1`)."
  def by_entry(%Tournament{} = tournament), do: set_order(tournament, entry_ids(tournament))

  @doc "The pool's player ids in the order they were added to the tournament."
  def entry_ids(%Tournament{} = tournament) do
    tournament.id |> Engine.active_players() |> Enum.sort_by(& &1.id) |> Enum.map(& &1.id)
  end

  @doc """
  The pool's player ids in the order round 1 would number them by rating
  (`Pairing.initial_order/2`; ties by title, the tournament's tie-break,
  name and id).
  """
  def rating_ids(%Tournament{} = tournament) do
    tournament.id
    |> Engine.active_players()
    |> Engine.initial_order(tournament)
    |> Enum.map(& &1.id)
  end

  @doc "A fresh seed for a drawing of lots."
  def new_seed, do: :crypto.strong_rand_bytes(4) |> :binary.decode_unsigned()

  @doc """
  The entry order shuffled by `seed`: the same seed on the same field draws
  the same order, which is what lets an audit entry reproduce a draw.
  """
  def lot_ids(%Tournament{} = tournament, seed) when is_integer(seed),
    do: tournament |> entry_ids() |> shuffle_by_seed(seed)

  @doc """
  Shuffles `ids` by `seed`: every id gets a random key from a generator
  seeded with `seed`, and the list is sorted by the keys. Pure.
  """
  def shuffle_by_seed(ids, seed) when is_list(ids) and is_integer(seed) do
    {keyed, _state} =
      Enum.map_reduce(ids, :rand.seed_s(:exsss, seed), fn id, state ->
        {key, state} = :rand.uniform_s(state)
        {{key, id}, state}
      end)

    keyed |> Enum.sort() |> Enum.map(&elem(&1, 1))
  end

  @doc """
  The pool numbered by `ids` as `[{player, number}]`, without writing
  anything: what `set_order/2` would give. Ids outside the pool are dropped.
  """
  def numbered(%Tournament{} = tournament, ids) when is_list(ids) do
    by_id = tournament.id |> Engine.active_players() |> Map.new(&{&1.id, &1})

    ids
    |> Enum.flat_map(fn id -> List.wrap(Map.get(by_id, id)) end)
    |> Enum.with_index(1)
  end

  @doc """
  What the audit trail keeps of a numbering: how it was chosen, the seed if
  there was one and the resulting order (number, player id, name).
  """
  def audit_details(mode, order, seed \\ nil) when is_list(order) do
    %{
      mode: to_string(mode),
      seed: seed,
      order: Enum.map(order, fn {p, n} -> %{no: n, id: p.id, name: p.name} end)
    }
  end

  @doc """
  The numbering to preselect: `:set` when numbers are already on the
  players, else `:rating`.
  """
  def default_mode(%Tournament{} = tournament),
    do: if(set_by_hand?(tournament), do: :set, else: :rating)

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
