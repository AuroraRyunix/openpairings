defmodule PairingsEngine.RestrictionCheck do
  @moduledoc """
  What a tournament's forbidden pairs and pairing rules do to the round
  about to be paired, before anybody presses Pair: how many games they rule
  out, who is left with nobody to play, and whether the round can be paired
  at all once the games already played are added to them.

  The last question is a perfect-matching one, and Ainalrami already answers
  it for team pairing (`Ainalrami.TeamPairing.Matching.feasible?/2`, a
  greedy pass with an exact memoised search behind it). The same oracle is
  asked here over the players, with "allowed" meaning not played before (a
  forfeited board is not a game) and not ruled out by a hard prohibition in
  that round. It knows nothing about
  colours, so "pairable" is a necessary condition and not a promise - but
  "not pairable" is a proof: no engine can pair that round, and the arbiter
  would rather hear it now than from the Pair button. An odd field leaves
  one player out (the bye), and is pairable when some player can be.

  Wishes (soft) never rule anything out, so they are not counted here.
  """

  import Ecto.Query

  alias Ainalrami.TeamPairing.Matching
  alias PairingsEngine.{Exclusions, Repo, Tournaments}
  alias PairingsEngine.Tournaments.{Pairing, Round, Tournament}

  # Past this many players the oracle is not asked (the counts still are):
  # a field this size with no legal round is not a thing restrictions make.
  @max_oracle_players 160

  @typedoc """
    * `:round` - the round looked at (the next to pair), nil when every round
      is paired.
    * `:players` - the players who can be paired in it.
    * `:possible` - games the field could have, `n(n-1)/2`.
    * `:forbidden` - of those, the ones a hard prohibition rules out.
    * `:isolated` - players every opponent is closed to (prohibitions plus
      games already played).
    * `:pairable` - `true`, `false`, or `:unknown` (too big to ask, or the
      oracle gave up).
  """
  @type t :: %{
          round: pos_integer() | nil,
          players: non_neg_integer(),
          possible: non_neg_integer(),
          forbidden: non_neg_integer(),
          isolated: [map()],
          pairable: boolean() | :unknown
        }

  @doc "The check for `tournament`'s next round - see the moduledoc."
  @spec next_round(Tournament.t()) :: t()
  def next_round(%Tournament{} = tournament) do
    paired = PairingsEngine.Pairing.paired_rounds_count(tournament.id)
    round = paired + 1

    if tournament.rounds_count && round > tournament.rounds_count do
      %{round: nil, players: 0, possible: 0, forbidden: 0, isolated: [], pairable: true}
    else
      players = PairingsEngine.Pairing.eligible_players(tournament.id, round)
      check(tournament, players, round)
    end
  end

  @doc false
  def check(tournament, players, round) do
    forbidden = forbidden_keys(tournament, players, round)
    met = met_keys(tournament.id)
    closed = MapSet.union(forbidden, met)
    n = length(players)

    allowed =
      Map.new(players, fn p ->
        {p.id,
         for(q <- players, q.id != p.id, not MapSet.member?(closed, key(p.id, q.id)), do: q.id)}
      end)

    %{
      round: round,
      players: n,
      possible: div(n * (n - 1), 2),
      forbidden: MapSet.size(forbidden),
      isolated: if(n > 1, do: Enum.filter(players, &(allowed[&1.id] == [])), else: []),
      pairable: pairable(players, allowed)
    }
  end

  defp forbidden_keys(tournament, players, round) do
    in_field = MapSet.new(players, & &1.id)

    explicit =
      tournament.id
      |> Tournaments.list_forbidden_pairings()
      |> Enum.reject(& &1.soft)
      |> Enum.filter(
        &(MapSet.member?(in_field, &1.player_a_id) and MapSet.member?(in_field, &1.player_b_id))
      )
      |> Enum.filter(&(is_nil(&1.from_round) or &1.from_round <= round))
      |> MapSet.new(&key(&1.player_a_id, &1.player_b_id))

    rules =
      tournament.id
      |> Tournaments.list_pairing_rules()
      |> Exclusions.hard_pairs(players, round, tournament.rounds_count)
      |> MapSet.new(fn {a, b} -> key(a.id, b.id) end)

    MapSet.union(explicit, rules)
  end

  # Met means played. A forfeited board leaves the two free to be paired
  # again (C.04.2 3.5), and the engine does pair them; counting it here made
  # "not pairable" - which the moduledoc sells as a proof - true of rounds
  # the Pair button then paired.
  defp met_keys(tournament_id) do
    Repo.all(
      from p in Pairing,
        join: r in Round,
        on: p.round_id == r.id,
        where:
          r.tournament_id == ^tournament_id and not is_nil(p.white_player_id) and
            not is_nil(p.black_player_id),
        select: {p.white_player_id, p.black_player_id, p.result}
    )
    |> Enum.reject(fn {_a, _b, result} -> PairingsEngine.Results.forfeit?(result) end)
    |> MapSet.new(fn {a, b, _result} -> key(a, b) end)
  end

  defp key(a, b) when a <= b, do: {a, b}
  defp key(a, b), do: {b, a}

  defp pairable(players, _allowed) when length(players) < 2, do: true
  defp pairable(players, _allowed) when length(players) > @max_oracle_players, do: :unknown

  defp pairable(players, allowed) do
    index = players |> Enum.with_index() |> Map.new(fn {p, i} -> {p.id, i} end)

    adj =
      Map.new(players, fn p ->
        {index[p.id],
         Enum.reduce(allowed[p.id], 0, fn q, acc -> Bitwise.bor(acc, Bitwise.bsl(1, index[q])) end)}
      end)

    full = Bitwise.bsl(1, length(players)) - 1

    try do
      if rem(length(players), 2) == 0 do
        Matching.feasible?(full, adj)
      else
        Enum.any?(0..(length(players) - 1), fn i ->
          Matching.feasible?(Bitwise.band(full, Bitwise.bnot(Bitwise.bsl(1, i))), adj)
        end)
      end
    rescue
      Matching.LimitError -> :unknown
    end
  end
end
