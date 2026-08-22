defmodule PairingsEngine.RoundExplanation do
  @moduledoc """
  Reads back what the pairing engine reported about a round, stored on
  `rounds.explanation` at pairing time by `PairingsEngine.Pairing`.

  Everything here is presentation of a RECORD. Nothing is recomputed, and
  nothing consults current standings: the point of storing the engine's own
  account is that it says what was decided at the moment it was decided,
  which a later derivation cannot recover once results are in or an arbiter
  has moved somebody.

  That same property is why `divergence/2` exists. A round can be edited
  after the engine paired it (`pairing.players_swapped`,
  `pairing.player_substituted`, `pairing.seat_filled`, ...), and a stored
  account that silently disagreed with the boards on screen would be worse
  than no account at all. So the pairs are compared, and the page is told to
  say so.
  """

  @doc """
  The stored account, with player ids resolved to players, or nil when the
  round has none (every JaVaFo round, and every round paired before the
  column existed).
  """
  def for_round(%{explanation: nil}, _players), do: nil

  def for_round(%{explanation: %{"sections" => sections}}, players) do
    by_id = Map.new(players, &{&1.id, &1})

    sections
    |> Enum.map(fn section ->
      %{
        category: section["category"],
        brackets: Enum.map(section["brackets"], &bracket(&1, by_id))
      }
    end)
    |> Enum.reject(&(&1.brackets == []))
    |> case do
      [] -> nil
      resolved -> resolved
    end
  end

  def for_round(_round, _players), do: nil

  defp bracket(bracket, by_id) do
    %{
      group: bracket["group"],
      mdps: names(bracket["mdps"], by_id),
      residents: names(bracket["residents"], by_id),
      floats: names(bracket["floats"], by_id),
      pairs:
        Enum.map(bracket["pairs"] || [], fn [a, b] -> {player(a, by_id), player(b, by_id)} end),
      edge_count: bracket["edge_count"],
      edges: Enum.map(bracket["edges"] || [], &edge(&1, by_id)),
      rungs: Enum.map(bracket["rungs"] || [], &{&1["label"], &1["value"]})
    }
  end

  # A round paired before per-board attribution existed simply has no
  # "edges" key, and the panel falls back to bracket totals alone.
  defp edge(edge, by_id) do
    [a, b] = edge["players"]

    %{
      white: player(a, by_id),
      black: player(b, by_id),
      float?: edge["kind"] == "float",
      rungs: Enum.map(edge["rungs"] || [], &{&1["label"], &1["value"]})
    }
  end

  defp names(ids, by_id),
    do: (ids || []) |> Enum.map(&player(&1, by_id)) |> Enum.reject(&is_nil/1)

  defp player(nil, _by_id), do: nil
  defp player(id, by_id), do: Map.get(by_id, id)

  @doc """
  Whether the round on the board still matches the one the engine explained.

  Compares WHO PLAYS WHOM and nothing else. A colour swap reseats a board
  without changing the pairing decision, so it is not divergence and must
  not be reported as such - the brackets, floats and criteria all still
  describe what happened.

  Takes the round with `:pairings` preloaded. Returns `:unchanged`,
  `:no_record` when nothing was stored, or `{:changed, count}` with the
  number of explained pairs that are no longer on a board.
  """
  def divergence(%{explanation: %{"sections" => sections}, pairings: pairings})
      when is_list(pairings) do
    explained =
      sections
      |> Enum.flat_map(& &1["brackets"])
      |> Enum.flat_map(& &1["pairs"])
      |> Enum.map(&pair_key/1)
      |> MapSet.new()

    seated =
      pairings
      |> Enum.map(&pair_key([&1.white_player_id, &1.black_player_id]))
      |> MapSet.new()

    case MapSet.size(MapSet.difference(explained, seated)) do
      0 -> :unchanged
      n -> {:changed, n}
    end
  end

  def divergence(_round), do: :no_record

  defp pair_key(ids) do
    ids |> Enum.reject(&is_nil/1) |> Enum.sort() |> List.to_tuple()
  end
end
