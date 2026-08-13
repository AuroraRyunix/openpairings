defmodule PairingsEngine.History do
  @moduledoc """
  Derived, presentation-agnostic data behind the History page's two graphs.

  Kept out of the LiveView so the arithmetic is testable on its own, and
  returns plain numbers and ids — no SVG, no coordinates, no colours. Layout
  is the view's job (see `PairingsEngineWeb.HistoryLive`).
  """

  import Ecto.Query

  alias PairingsEngine.{Keizer, Repo, Standings}
  alias PairingsEngine.Tournaments.{Pairing, Round, Tournament}

  @typedoc "One player's position after one round."
  @type point :: %{round: pos_integer(), rank: pos_integer(), points: float()}

  @typedoc "One player's whole run through the tournament."
  @type series :: %{
          player_id: integer(),
          name: String.t(),
          final_rank: pos_integer(),
          points: [point()]
        }

  @doc """
  How every player's rank moved round by round — the data behind the bump
  chart.

  Returns `{rounds, series}` where `rounds` is the list of round numbers
  covered (`[]` when nothing is paired yet) and `series` is one entry per
  player, ordered by final rank so the caller can colour/label deterministically.

  Each round is computed with `Standings.standings/2`'s `through_round:`
  option, which is the same code path the tournament used at the time — so a
  past round shows the figures actually on the board then, not a
  retrospective recomputation. Keizer tournaments go through
  `Keizer.standings/2` instead, matching `Standings.player_scores_before_round/2`.

  A player who joined late (or was absent) simply has no point for the rounds
  they weren't ranked in; the caller draws a gap rather than inventing a
  position.
  """
  @spec standings_evolution(Tournament.t()) :: {[pos_integer()], [series()]}
  def standings_evolution(%Tournament{} = tournament) do
    case paired_round_numbers(tournament.id) do
      [] ->
        {[], []}

      rounds ->
        per_round = Map.new(rounds, &{&1, round_entries(tournament, &1)})
        final_round = List.last(rounds)

        series =
          per_round
          |> Map.fetch!(final_round)
          |> Enum.map(fn final_entry ->
            %{
              player_id: final_entry.player.id,
              name: final_entry.player.name,
              final_rank: final_entry.rank,
              points: points_for(per_round, rounds, final_entry.player.id)
            }
          end)
          |> Enum.sort_by(& &1.final_rank)

        {rounds, series}
    end
  end

  defp round_entries(tournament, round_number) do
    if tournament.pairing_system == "keizer" do
      Keizer.standings(tournament, through_round: round_number)
    else
      Standings.standings(tournament, through_round: round_number)
    end
  end

  defp points_for(per_round, rounds, player_id) do
    rounds
    |> Enum.flat_map(fn round ->
      per_round
      |> Map.fetch!(round)
      |> Enum.find(&(&1.player.id == player_id))
      |> case do
        nil -> []
        entry -> [%{round: round, rank: entry.rank, points: entry.points}]
      end
    end)
  end

  @typedoc "A player node in the pairing network."
  @type node_entry :: %{player_id: integer(), name: String.t(), games: non_neg_integer()}

  @typedoc """
  One edge — a game actually played between two seated players. `rounds` is
  every round the pair met in (more than one for a match-format rematch or a
  double round robin).
  """
  @type edge :: %{a: integer(), b: integer(), rounds: [pos_integer()], count: pos_integer()}

  @doc """
  Who played whom across the whole tournament — the data behind the network
  graph.

  Returns `%{nodes: [...], edges: [...]}`. Only pairings with *both* seats
  filled become edges: a bye or a vacated seat is not a game between two
  players and would otherwise draw an edge to nothing.

  Edges are undirected and deduplicated — a pair that met twice comes back as
  one edge with `count: 2` and both round numbers — because the graph's
  question is "who has met whom", which colour is a separate concern.

  Nodes carry a `games` count so the view can size them without recounting.
  """
  @spec pairing_network(Tournament.t()) :: %{nodes: [node_entry()], edges: [edge()]}
  def pairing_network(%Tournament{} = tournament) do
    games =
      Repo.all(
        from p in Pairing,
          join: r in Round,
          on: p.round_id == r.id,
          where:
            r.tournament_id == ^tournament.id and not is_nil(p.white_player_id) and
              not is_nil(p.black_player_id),
          select: %{
            white: p.white_player_id,
            black: p.black_player_id,
            round: r.number
          }
      )

    edges =
      games
      # Undirected: order the pair consistently so the two colours of the same
      # meeting collapse onto one edge.
      |> Enum.group_by(fn g -> Enum.sort([g.white, g.black]) end)
      |> Enum.map(fn {[a, b], meetings} ->
        %{
          a: a,
          b: b,
          rounds: meetings |> Enum.map(& &1.round) |> Enum.sort(),
          count: length(meetings)
        }
      end)
      |> Enum.sort_by(&{&1.a, &1.b})

    names = player_names(tournament.id)

    game_counts =
      Enum.reduce(games, %{}, fn g, acc ->
        acc
        |> Map.update(g.white, 1, &(&1 + 1))
        |> Map.update(g.black, 1, &(&1 + 1))
      end)

    nodes =
      game_counts
      |> Enum.map(fn {player_id, games_played} ->
        %{
          player_id: player_id,
          name: Map.get(names, player_id, "#"),
          games: games_played
        }
      end)
      # Stable order so the view's circular layout doesn't reshuffle between
      # renders; by name so the ring reads alphabetically.
      |> Enum.sort_by(&{&1.name, &1.player_id})

    %{nodes: nodes, edges: edges}
  end

  defp player_names(tournament_id) do
    Repo.all(
      from p in PairingsEngine.Tournaments.Player,
        where: p.tournament_id == ^tournament_id,
        select: {p.id, p.name}
    )
    |> Map.new()
  end

  # Rounds that actually have at least one pairing — an empty round shouldn't
  # become a column on the chart. `group_by` rather than `distinct:`, which
  # SQLite rejects when combined with an order_by ("DISTINCT with multiple
  # columns is not supported").
  defp paired_round_numbers(tournament_id) do
    Repo.all(
      from r in Round,
        join: p in Pairing,
        on: p.round_id == r.id,
        where: r.tournament_id == ^tournament_id,
        group_by: r.number,
        order_by: r.number,
        select: r.number
    )
  end
end
