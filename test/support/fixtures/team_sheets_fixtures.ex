defmodule PairingsEngine.TeamSheetsFixtures do
  @moduledoc """
  Team events with results already in, for the team tables and their prints:
  a four-team round robin and a four-team Swiss, two boards a match, built
  through the context functions (`TeamFixtures` plus `update_pairing_result/2`).
  """

  import Ecto.Query
  import PairingsEngine.TeamFixtures

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Tournaments.Match

  @doc "Four teams: name, and two players each with a rating."
  def four_teams, do: for(i <- 1..4, do: {"T#{i}", [2000 - i * 10, 1990 - i * 10]})

  @doc "The round's matches (byes left out), in match-number order."
  def matches_of(t, round_number) do
    round = Tournaments.get_round(t.id, round_number)

    Repo.all(
      from m in Match,
        where: m.round_id == ^round.id and not is_nil(m.team_b_id),
        order_by: m.board
    )
  end

  @doc """
  Enters `codes` (board 1 first) on `match` of `round_number`. `["1-0", "0-1"]`
  is a 2-0 win for the match's `team_a`, which has White on board 1 and Black
  on board 2.
  """
  def enter_match!(t, round_number, match, codes) do
    round = Tournaments.get_round(t.id, round_number)

    round.pairings
    |> Enum.filter(&(&1.match_id == match.id))
    |> Enum.sort_by(& &1.board)
    |> Enum.zip(codes)
    |> Enum.each(fn {pairing, code} ->
      {:ok, _} = Tournaments.update_pairing_result(pairing, code)
    end)
  end

  @doc """
  A team round robin of four, all three rounds paired. Round 1 is played
  (the first match 2-0 to its `team_a`, the second 1-1), round 2 has one board
  of its first match entered, round 3 is blank.
  """
  def played_round_robin(user_id) do
    {t, _} =
      team_round_robin(four_teams(),
        boards: 2,
        rounds_count: 3,
        user_id: user_id,
        name: "Interclub RR"
      )

    t = pair_all!(t)
    [m1, m2] = matches_of(t, 1)
    enter_match!(t, 1, m1, ["1-0", "0-1"])
    enter_match!(t, 1, m2, ["1/2-1/2", "1/2-1/2"])
    [r2m1, _] = matches_of(t, 2)
    enter_match!(t, 2, r2m1, ["1-0"])
    {t, m1}
  end

  @doc """
  A team Swiss of four, two rounds paired and played: round 1's first match
  2-0 to its `team_a`, the second 1-1; round 2 all draws.
  """
  def played_swiss(user_id) do
    {t, _} =
      team_swiss(four_teams(), boards: 2, rounds: 3, user_id: user_id, name: "Interclub Swiss")

    pair_next!(t)
    [m1, m2] = matches_of(t, 1)
    enter_match!(t, 1, m1, ["1-0", "0-1"])
    enter_match!(t, 1, m2, ["1/2-1/2", "1/2-1/2"])
    pair_next!(t)
    Enum.each(matches_of(t, 2), &enter_match!(t, 2, &1, ["1/2-1/2", "1/2-1/2"]))
    {Repo.reload!(t), m1}
  end
end
