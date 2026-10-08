defmodule PairingsEngine.PostponedHelpers do
  @moduledoc """
  For tests of what a report does with an open postponed game. In FIDE mode
  no TRF is made while one is open (VCL4THP Q169,
  `PostponedGames.ensure_reportable/1`); the arbiter's way on, short of
  entering the result, is to record each open game as not played in this
  event - which also takes the tournament out of FIDE mode. That is what a
  test of the sending flow has to do first now, so it does it here.
  """

  alias PairingsEngine.{PostponedGames, Repo}
  alias PairingsEngine.Tournaments.Tournament

  @doc """
  Records every open postponed game of `tournament` (a struct or an id) as
  not played in this event, and returns the tournament reloaded.
  """
  def report_open_games_not_played!(%Tournament{} = tournament) do
    for game <- PostponedGames.open_games(tournament) do
      {:ok, _} = PostponedGames.report_not_played(tournament, game.pairing.id)
    end

    Repo.reload!(tournament)
  end

  def report_open_games_not_played!(tournament_id) when is_integer(tournament_id),
    do: Tournament |> Repo.get!(tournament_id) |> report_open_games_not_played!()
end
