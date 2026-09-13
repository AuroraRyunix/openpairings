defmodule PairingsEngine.TeamFixtures do
  @moduledoc """
  Team round robins for tests: a tournament, teams in seeding order, rosters
  in board order, and a way to type in a round's board results by match.
  """

  alias PairingsEngine.{Repo, RoundRobin, Tournaments}
  alias PairingsEngine.Tournaments.{Match, Tournament}

  import Ecto.Query

  @doc """
  A team round robin with `teams` - a list of `{name, [player_rating, ...]}` -
  created in that order (so seeded 1..N), each roster in the order given.
  Options: `:boards` (default 2), `:user_id`, `:tiebreaks`, `:rr_cycles`,
  and any other tournament attribute.
  """
  def team_round_robin(teams, opts \\ []) do
    attrs =
      Map.merge(
        %{
          name: "Team RR",
          type: "team-roundrobin",
          pairing_system: "round_robin",
          rounds_count: 3,
          team_boards: Keyword.get(opts, :boards, 2),
          tiebreaks: Keyword.get(opts, :tiebreaks, ~w(MP GP DE BB SB)),
          rr_cycles: Keyword.get(opts, :rr_cycles, 1),
          user_id: Keyword.get(opts, :user_id)
        },
        Map.new(Keyword.drop(opts, [:boards, :tiebreaks, :rr_cycles, :user_id]))
      )

    tournament = Repo.insert!(struct(Tournament, attrs))

    created =
      for {name, ratings} <- teams do
        {:ok, team} = Tournaments.create_team(tournament, %{"name" => name})

        for {rating, i} <- Enum.with_index(ratings, 1) do
          {:ok, p} =
            Tournaments.create_player(tournament.id, %{
              "name" => "#{name} #{i}",
              "fide_rating" => "#{rating}"
            })

          {:ok, _} = Tournaments.set_player_team(tournament, p, team)
        end

        team
      end

    {Repo.reload!(tournament), created}
  end

  @doc """
  A team Swiss (C.04.6) with `teams` like `team_round_robin/2`. Options:
  `:boards` (default 2), `:rounds` (default 5), `:tiebreaks`, `:user_id`,
  and any other tournament attribute.
  """
  def team_swiss(teams, opts \\ []) do
    team_round_robin(
      teams,
      [
        type: "team-swiss",
        pairing_system: "swiss",
        rounds_count: Keyword.get(opts, :rounds, 5),
        name: "Team Swiss"
      ] ++ Keyword.drop(opts, [:rounds])
    )
  end

  @doc "Pairs the next round through the app's entry point; returns the round."
  def pair_next!(%Tournament{} = t) do
    {:ok, round} = PairingsEngine.Pairing.pair_next_round(Repo.reload!(t))
    round
  end

  @doc "Pairs the whole schedule; returns the reloaded tournament."
  def pair_all!(%Tournament{} = t) do
    {:ok, _} = RoundRobin.pair_all_rounds(t)
    Repo.reload!(t)
  end

  @doc """
  The match in `round_number` between the teams named `a` and `b` (either
  order), with its board pairings in board order.
  """
  def match_between(%Tournament{} = t, round_number, a, b) do
    round = Tournaments.get_round(t.id, round_number)
    teams = t.id |> Tournaments.list_teams() |> Map.new(&{&1.name, &1.id})
    ids = MapSet.new([teams[a], teams[b]])

    match =
      Repo.one!(
        from m in Match,
          where: m.round_id == ^round.id and not is_nil(m.team_b_id),
          where: m.team_a_id in ^MapSet.to_list(ids) and m.team_b_id in ^MapSet.to_list(ids)
      )

    boards = round.pairings |> Enum.filter(&(&1.match_id == match.id)) |> Enum.sort_by(& &1.board)
    {match, boards}
  end

  @doc """
  Enters `results` (result codes, board 1 first) on the match between `a`
  and `b` in `round_number`.
  """
  def enter!(t, round_number, a, b, results) do
    {_match, boards} = match_between(t, round_number, a, b)

    boards
    |> Enum.zip(results)
    |> Enum.each(fn {pairing, result} ->
      {:ok, _} = Tournaments.update_pairing_result(pairing, result)
    end)
  end
end
