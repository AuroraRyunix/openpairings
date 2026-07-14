defmodule PairingsEngine.PlayerStats do
  @moduledoc """
  Small pure helpers for SWAR-style player grid columns (age category,
  performance rating). Kept separate from `PairingsEngine.Standings` so they
  can be unit tested without building a tournament/DB fixture.
  """

  @doc """
  Belgian KBSB age category for a player born in `birth_year`, relative to
  `current_year` (defaults to today's year). Returns `""` when `birth_year`
  is `nil`.

      iex> PairingsEngine.PlayerStats.category(2019, 2026)
      "-8"
      iex> PairingsEngine.PlayerStats.category(1960, 2026)
      "S65"
  """
  def category(birth_year, current_year \\ Date.utc_today().year)

  def category(nil, _current_year), do: ""

  def category(birth_year, current_year) do
    age = current_year - birth_year

    cond do
      age < 8 -> "-8"
      age < 10 -> "-10"
      age < 12 -> "-12"
      age < 14 -> "-14"
      age < 16 -> "-16"
      age < 18 -> "-18"
      age < 20 -> "-20"
      age >= 65 -> "S65"
      age >= 50 -> "S50"
      true -> "SEN"
    end
  end

  @doc """
  Performance rating: the average rating of opponents faced in played games,
  plus 400 × (wins − losses) / games played, rounded to the nearest integer.

  `opponent_ratings` is the list of opponent ratings for each played game
  (one entry per game). Returns `nil` when no games were played (the caller
  is expected to render that as "—").

      iex> PairingsEngine.PlayerStats.performance([1800, 1700], 2, 0)
      2150
      iex> PairingsEngine.PlayerStats.performance([], 0, 0)
      nil
  """
  def performance([], _wins, _losses), do: nil

  def performance(opponent_ratings, wins, losses) do
    games_played = length(opponent_ratings)
    average = Enum.sum(opponent_ratings) / games_played
    round(average + 400 * (wins - losses) / games_played)
  end
end
