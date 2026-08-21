defmodule PairingsEngine.Exclusions do
  @moduledoc """
  Club / federation pairing-exclusion rules (SWAR parity #7-10) - arbiter
  policy that certain groups of players (clubmates, players sharing a
  federation) must never be paired against each other, translated into a
  set of forbidden player pairs at pairing time.

  `excluded_pairs/2` returns a `MapSet` of `{player, player}` tuples - pairs
  of the full `PairingsEngine.Tournaments.Player` struct, not ids or
  starting ranks, so each call site can map to whatever id space it needs
  without this module knowing about either:

    * `PairingsEngine.Pairing` maps each pair to the players' TRF starting
      rank (`pairing_number`) to emit JaVaFo `XXP` lines, same as an
      explicit forbidden pairing.
    * `PairingsEngine.Keizer` maps each pair to player ids to fold into its
      own `pair_key/2`-keyed forbidden set.

  Every returned pair is canonically ordered `{a, b}` with `a.id <= b.id`,
  so duplicate pairs collapse regardless of which rule (or which group)
  produced them, and so unioning the club and federation results never
  double-counts a pair excluded by both.

  A round robin's fixed schedule ignores these rules entirely by design -
  see `docs/forbidden-pairings.md`.
  """

  alias PairingsEngine.Tournaments.{Player, Tournament}

  @doc """
  Pairs of `players` excluded by `tournament`'s club and federation
  exclusion rules (`club_exclusion`/`club_exclusion_list`,
  `fed_exclusion`/`fed_exclusion_list` - see
  `PairingsEngine.Tournaments.Tournament`). Club rules and federation rules
  are independent and their results unioned: a pair excluded by both counts
  once.

  Rule semantics, identical on both axes:

    * `"none"` - no exclusions from this axis.
    * `"all"` - every pair of players sharing the same non-blank
      club/federation is excluded.
    * `"listed"` - only pairs sharing a club/federation whose name (after
      trimming and case-insensitive compare) appears in the axis's
      comma-separated list.

  A player with a blank club/federation is never excluded on that axis
  under any rule - there's no group for them to share.
  """
  @spec excluded_pairs(Tournament.t(), [Player.t()]) :: MapSet.t({Player.t(), Player.t()})
  def excluded_pairs(%Tournament{} = tournament, players) do
    club_pairs =
      pairs_for(players, tournament.club_exclusion, tournament.club_exclusion_list, & &1.club)

    fed_pairs =
      pairs_for(players, tournament.fed_exclusion, tournament.fed_exclusion_list, & &1.federation)

    MapSet.union(club_pairs, fed_pairs)
  end

  defp pairs_for(_players, "none", _list, _field_fn), do: MapSet.new()

  defp pairs_for(players, "all", _list, field_fn) do
    players |> group_by_value(field_fn) |> pairs_from_groups()
  end

  defp pairs_for(players, "listed", list, field_fn) do
    allowed = list |> normalize_list() |> MapSet.new(&String.downcase/1)

    players
    |> group_by_value(field_fn)
    |> Enum.filter(fn {value, _group} -> String.downcase(value) in allowed end)
    |> pairs_from_groups()
  end

  defp pairs_for(_players, _other_mode, _list, _field_fn), do: MapSet.new()

  # Groups players by their (trimmed) club/federation value, dropping any
  # group keyed on a blank value - blank means "no club/federation", never
  # a group to exclude within. Grouped case-insensitively (trimmed, then
  # downcased) so "Chess Club" and "chess club" are treated as the same
  # club, matching the "listed" rule's case-insensitive list compare below.
  defp group_by_value(players, field_fn) do
    players
    |> Enum.group_by(fn p ->
      p |> field_fn.() |> to_string() |> String.trim() |> String.downcase()
    end)
    |> Enum.reject(fn {value, _group} -> value == "" end)
  end

  defp pairs_from_groups(groups) do
    groups
    |> Enum.flat_map(fn {_value, group} -> unordered_pairs(group) end)
    |> MapSet.new()
  end

  # Every unordered pair within `players`, generated once each (i < j over
  # the list's own indices, not the players' ids) - quadratic in group size,
  # which is fine: exclusion groups are clubs/federations, not the whole
  # field.
  defp unordered_pairs(players) do
    indexed = Enum.with_index(players)

    for {a, i} <- indexed, {b, j} <- indexed, i < j, do: canonical(a, b)
  end

  defp canonical(%{id: a_id} = a, %{id: b_id} = b) when a_id <= b_id, do: {a, b}
  defp canonical(a, b), do: {b, a}

  @doc """
  Normalizes a comma-separated exclusion list into a list of trimmed,
  non-blank entries. Used here and by `PairingsEngine.Tournaments.Tournament`'s
  changeset (which re-joins the result back into the same comma-separated
  storage shape).
  """
  @spec normalize_list(String.t() | nil) :: [String.t()]
  def normalize_list(nil), do: []

  def normalize_list(list) when is_binary(list) do
    list
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end
