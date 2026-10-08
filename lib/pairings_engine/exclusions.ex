defmodule PairingsEngine.Exclusions do
  @moduledoc """
  Pairing rules (`PairingsEngine.Tournaments.PairingRule`) turned into the
  players they keep apart - "same club", "same federation", "these five" -
  for one round, from the players as they are now.

  Pure: rules and players in, groups and pairs out. Nothing here reads the
  database, so the pairing, Keizer, the TRF writer and the Options page's
  counts all expand a rule the same way.

  A group is the set of players a rule keeps apart from EACH OTHER: one per
  club with two or more members for a club rule, one per federation, the
  rule's own members for a group rule. Hard rules reach the engines as
  pairs (`hard_pairs/4`, written as `XXP`); soft ones as whole groups
  (`soft_groups/4`), the shape Ainalrami's `:soft_pairs` option takes.

  Clubs and federations are compared trimmed and case-insensitively, and a
  blank club or federation is never a group - "no club" is not a club.
  """

  alias PairingsEngine.Tournaments.{PairingRule, Player}

  @doc """
  Whether `rule` holds in `round` of a tournament of `rounds_count` rounds.
  A rule added once rounds were paired (`from_round`) never holds before it.
  """
  @spec applies?(PairingRule.t() | map(), pos_integer(), non_neg_integer() | nil) :: boolean()
  def applies?(rule, round, rounds_count) do
    case rounds(rule, rounds_count) do
      nil -> false
      {first, last} -> round >= first and (is_nil(last) or round <= last)
    end
  end

  @doc """
  The rounds `rule` holds for, as `{first, last}` - `last` nil for "to the
  end" - or nil when it holds for none (a "last 3 rounds" rule added after
  the last round was paired). `rounds_count` is the tournament's number of
  rounds, which "last N" counts back from.
  """
  def rounds(rule, rounds_count) do
    {first, last} =
      case rule.window do
        "first" -> {1, rule.window_rounds}
        "last" -> {max((rounds_count || 0) - (rule.window_rounds || 0) + 1, 1), rounds_count}
        "range" -> {rule.window_from, rule.window_to}
        _ -> {1, nil}
      end

    first = max(first || 1, rule.from_round || 1)

    if is_integer(last) and last < first, do: nil, else: {first, last}
  end

  @doc """
  The groups of `players` that `rule` keeps apart, each a list of two or
  more players. Ignores the rule's rounds - see `applies?/3`.
  """
  @spec groups(PairingRule.t() | map(), [Player.t()]) :: [[Player.t()]]
  def groups(%{kind: "club"} = rule, players), do: value_groups(players, & &1.club, rule.names)

  def groups(%{kind: "federation"} = rule, players),
    do: value_groups(players, & &1.federation, rule.names)

  def groups(%{kind: "group", player_ids: ids}, players) do
    wanted = MapSet.new(ids || [])

    case Enum.filter(players, &MapSet.member?(wanted, &1.id)) do
      [_, _ | _] = members -> [members]
      _ -> []
    end
  end

  def groups(_rule, _players), do: []

  @doc """
  Every pair of `players` a HARD rule of `rules` keeps apart in `round`, as
  `{player, player}` tuples ordered by id, each pair once however many
  rules name it. `round` nil means every round any rule holds for - what a
  count "how many pairs do these rules forbid" wants.
  """
  @spec hard_pairs([map()], [Player.t()], pos_integer() | nil, non_neg_integer() | nil) ::
          MapSet.t({Player.t(), Player.t()})
  def hard_pairs(rules, players, round, rounds_count) do
    rules
    |> Enum.reject(& &1.soft)
    |> Enum.filter(&(is_nil(round) or applies?(&1, round, rounds_count)))
    |> Enum.flat_map(&groups(&1, players))
    |> Enum.flat_map(&unordered_pairs/1)
    |> MapSet.new()
  end

  @doc """
  The groups of player ids the SOFT rules of `rules` ask to keep apart in
  `round` - Ainalrami's `:soft_pairs` takes groups as they are.
  """
  @spec soft_groups([map()], [Player.t()], pos_integer(), non_neg_integer() | nil) :: [
          [integer()]
        ]
  def soft_groups(rules, players, round, rounds_count) do
    rules
    |> Enum.filter(& &1.soft)
    |> Enum.filter(&applies?(&1, round, rounds_count))
    |> Enum.flat_map(&groups(&1, players))
    |> Enum.map(fn group -> Enum.map(group, & &1.id) end)
  end

  @doc """
  What `rule` does to `players` now: `%{pairs: n, groups: n}` - the pairs it
  keeps apart and the clubs, federations or groups they come from. What
  the Options page shows beside each rule.
  """
  def effect(rule, players) do
    groups = groups(rule, players)

    %{
      groups: length(groups),
      pairs: Enum.reduce(groups, 0, fn g, acc -> acc + div(length(g) * (length(g) - 1), 2) end)
    }
  end

  @doc """
  `players` grouped by club - one list per non-blank club with at least two
  members.
  """
  @spec club_groups([Player.t()]) :: [[Player.t()]]
  def club_groups(players), do: value_groups(players, & &1.club, [])

  @doc """
  A rule in plain ASCII English, the way a `### Prohibition` line names it:
  "same club", "same federation (BEL, NED), if possible, last 2 rounds".
  Group members are not named here - the TRF line lists them by number.
  """
  def describe(rule) do
    what =
      case rule.kind do
        "club" -> "same club" <> names_suffix(rule.names)
        "federation" -> "same federation" <> names_suffix(rule.names)
        _ -> "group"
      end

    [what, if(rule.soft, do: "if possible"), window_text(rule)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(", ")
  end

  defp names_suffix([_ | _] = names) do
    ascii = names |> Enum.map(&ascii/1) |> Enum.reject(&(&1 == ""))
    if ascii == [], do: "", else: " (" <> Enum.join(ascii, ", ") <> ")"
  end

  defp names_suffix(_), do: ""

  # The `###` lines are ASCII; a club called "Échiquier" becomes
  # "Echiquier" rather than a byte the checker chokes on.
  defp ascii(name) do
    name
    |> String.normalize(:nfd)
    |> String.replace(~r/[^\x20-\x7E]/u, "")
    |> String.trim()
  end

  defp window_text(%{window: "first", window_rounds: n}), do: "first #{n} rounds"
  defp window_text(%{window: "last", window_rounds: n}), do: "last #{n} rounds"
  defp window_text(%{window: "range", window_from: a, window_to: b}), do: "rounds #{a}-#{b}"
  defp window_text(_rule), do: nil

  @doc """
  Normalizes a comma-separated list into trimmed, non-blank entries.
  """
  @spec normalize_list(String.t() | nil) :: [String.t()]
  def normalize_list(nil), do: []

  def normalize_list(list) when is_binary(list) do
    list
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # Groups by the trimmed, downcased value; blank is never a group, and a
  # group of one keeps nobody apart. `names` non-empty keeps the listed
  # values only.
  defp value_groups(players, field_fn, names) do
    allowed = MapSet.new(names || [], &(&1 |> String.trim() |> String.downcase()))

    players
    |> Enum.group_by(fn p ->
      p |> field_fn.() |> to_string() |> String.trim() |> String.downcase()
    end)
    |> Enum.reject(fn {value, _} -> value == "" end)
    |> Enum.filter(fn {value, _} -> MapSet.size(allowed) == 0 or value in allowed end)
    |> Enum.sort_by(fn {value, _} -> value end)
    |> Enum.map(fn {_, group} -> Enum.sort_by(group, & &1.id) end)
    |> Enum.filter(&(length(&1) >= 2))
  end

  defp unordered_pairs(players) do
    indexed = Enum.with_index(players)
    for {a, i} <- indexed, {b, j} <- indexed, i < j, do: canonical(a, b)
  end

  defp canonical(%{id: a_id} = a, %{id: b_id} = b) when a_id <= b_id, do: {a, b}
  defp canonical(a, b), do: {b, a}
end
