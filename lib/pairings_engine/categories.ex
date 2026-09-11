defmodule PairingsEngine.Categories do
  @moduledoc """
  One player, many categories - and the one of them that decides pairing.

  A tournament defines its own category vocabulary
  (`PairingsEngine.Tournaments.Tournament`'s `categories`). A player carries
  a SET of those names (`players.categories`): prize lists, the printed
  per-category standings tables and the Players grid all read that set, and
  a player who is both a junior and a woman is correctly in both.

  Pairing cannot work that way. `pair_by_category` runs each category as an
  independent tournament - its own engine call, its own pairing-allocated
  bye, merged into one `Round` with continuous board numbers
  (`PairingsEngine.Pairing`'s `category_groups/2` and
  `insert_category_round/3`) - so a player who appeared in three pools would
  get three opponents in one round. Exactly one category has to win, and
  `pairing_category/2` below is the only thing that decides which.

  Everything that needs "the player's single category" - the pairing
  partition, the board label on the pairing-explanation page, the SWAR
  export's one signed category index, the OpenResults snapshot's
  `players[].category` - calls this. Nothing else compares
  `player.category` to a category name directly, because two places
  answering the same question separately is how the label and the pool came
  to disagree in the first place (fixed in 0.53.0).
  """

  alias PairingsEngine.Tournaments.Player

  @doc """
  The single category that pools `player` for `pair_by_category`, or `""`
  for the "Uncategorized" pool.

  Read out loud: *the category the player was explicitly placed in, if they
  still carry it and the tournament still lists it; otherwise the first of
  their categories in the tournament's own order; otherwise none.*

  `players.category` is the explicit placement - an OVERRIDE, not "the
  player's category". Two properties fall out of honouring it only while it
  is still both a tag of the player's and a category of the tournament's:

    * it cannot drift. An override naming a category the arbiter has since
      removed from the player, or from the tournament, self-heals into the
      derived answer instead of silently pairing them somewhere the screen
      does not show.
    * it cannot be invented. The result is always `""` or a name from
      `tournament.categories`, so the pools are exactly
      `tournament.categories ++ [""]` and every player lands in precisely
      one of them - which is what makes the partition a partition.

  Derivation order is the tournament's own `categories` order, which is the
  order the arbiter sees on the Categories page. That is the same tie-break
  `PairingsEngine.PlayerStats.assign_category/4` has always used between
  rule kinds, and it is deterministic and visible rather than "whichever the
  arbiter typed first".

  Takes any map carrying `:categories` (the tournament's vocabulary), so a
  `%Tournament{}` or the trimmed maps the pairing code passes around both
  work.
  """
  @spec pairing_category(map(), Player.t()) :: String.t()
  def pairing_category(tournament, %Player{} = player) do
    listed = tournament.categories || []
    tags = player.categories || []
    override = player.category || ""

    if override != "" and override in listed and override in tags do
      override
    else
      Enum.find(listed, "", &(&1 in tags))
    end
  end

  @doc """
  `player`'s categories, in `tournament.categories` order, with anything the
  tournament no longer lists dropped.

  A stored tag list is a set and its stored order means nothing - it is
  whatever order the writer happened to use. Every display surface wants the
  same order, and the only order that means anything to an arbiter is the
  one they defined on the Categories page, so ordering happens here rather
  than five times over.

  Dropping unlisted names is the display half of the same rule
  `pairing_category/2` applies to the override: a name that is not in the
  tournament's vocabulary is not a category of this tournament, whatever a
  row still holds. It stays in the database - removing a category does not
  reach into the roster (see `CategoriesLive`'s `remove_category`) - it is
  simply not shown.
  """
  @spec listed_categories(map(), Player.t()) :: [String.t()]
  def listed_categories(tournament, %Player{} = player) do
    tags = MapSet.new(player.categories || [])
    Enum.filter(tournament.categories || [], &MapSet.member?(tags, &1))
  end

  @doc """
  `names` de-duplicated and put into the tournament's own category order,
  with anything the tournament does not list kept but sorted after the rest.

  The storage-side counterpart to `listed_categories/2`: that one is for
  display and drops unlisted names, this one is for what gets WRITTEN and
  drops nothing. A tag a tournament no longer lists is still a fact about
  the player - it can come from a `.swar` file, from a JSON backup, or from
  a category the arbiter removed after assigning it - and a bulk write that
  happened to touch the row is not the place to decide it should disappear.

  Ordering matters only so that two writes producing the same set produce
  the same list, which is what keeps a re-run of
  `Tournaments.auto_assign_categories/1` idempotent rather than reshuffling
  every row.
  """
  @spec order(map(), [String.t()]) :: [String.t()]
  def order(tournament, names) do
    listed = tournament.categories || []
    index = listed |> Enum.with_index() |> Map.new()

    names
    |> Enum.uniq()
    |> Enum.sort_by(&{Map.get(index, &1, length(listed)), &1})
  end

  @doc """
  True when `player` carries `name`.

  A one-line membership test, named because it replaces the equality
  comparisons (`player.category == category`) that used to decide which
  players a per-category prize table listed - and equality is what made a
  junior woman appear on exactly one of the two prize lists she had won.
  """
  @spec in_category?(Player.t(), String.t()) :: boolean()
  def in_category?(%Player{} = player, name) when is_binary(name) do
    name in (player.categories || [])
  end

  @doc """
  `entries` (standings entries - maps carrying `:player` and the overall
  `:rank`, in the order they are actually displayed: pass them through
  `PairingsEngine.Standings.apply_manual_ranking/2` first when the
  tournament uses manual ranking, exactly as the standings page already
  does before rendering) filtered down to the players in category `name`,
  each with a `:category_place` key added: 1..n in that same order.

  This is the ONE place an in-category place is computed - both
  `PairingsEngineWeb.StandingsLive` (the Category column's per-chip place
  and the category selector's place column) and
  `PairingsEngineWeb.PrintController`'s per-category standings tables call
  this rather than each re-deriving it.

  Entries that share the overall `:rank` share their `:category_place` too,
  the same way two entries would share `:rank` itself if this codebase's
  standings ever stopped breaking every tie with player id (it does not
  today - see `PairingsEngine.Standings.build_standings/3` - so in practice
  this densely numbers 1..n with no repeats, but the rule is stated in
  terms of `:rank` rather than "never happens" so it stays correct if that
  ever changes).
  """
  @spec category_places([map()], String.t()) :: [map()]
  def category_places(entries, name) when is_binary(name) do
    entries
    |> Enum.filter(&in_category?(&1.player, name))
    |> place_by_rank()
  end

  defp place_by_rank(entries) do
    entries
    |> Enum.map_reduce({:none, 0}, fn entry, {prev_rank, place} ->
      place = if prev_rank == entry.rank, do: place, else: place + 1
      {Map.put(entry, :category_place, place), {entry.rank, place}}
    end)
    |> elem(0)
  end

  @doc """
  True when `place` (a `:category_place` from `category_places/2`) falls
  within `tournament.category_prizes`'s configured count for category
  `name` - the "prize place" highlight on the standings page and, per
  `Tournament.category_prizes`'s own field doc, informational only: no
  prize is actually allocated anywhere from this.

  False whenever no count is set (nil/missing) or the count is `0` - the
  same "nothing configured, nothing highlighted" reading `category_prizes`'s
  own field doc describes.
  """
  @spec prize_place?(map(), String.t(), pos_integer()) :: boolean()
  def prize_place?(tournament, name, place) do
    case Map.get(tournament.category_prizes || %{}, name) do
      count when is_integer(count) and count > 0 -> place <= count
      _ -> false
    end
  end
end
