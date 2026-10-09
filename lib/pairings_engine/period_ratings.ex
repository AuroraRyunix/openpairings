defmodule PairingsEngine.PeriodRatings do
  @moduledoc """
  A tournament lasting more than 30 days (VCL4THP Q210-Q216,
  `Tournament.long_event`): it spans more than one rating period, so a
  player may hold more than one rating during it.

  A player's first rating stays where it always was (`fide_rating`,
  `national_rating`); each later one is an entry of `Player.period_ratings`
  with the first round it applies to. `at_round/3` gives the player as they
  stood in a round - the struct with that round's ratings in the two rating
  fields - so every reader that takes a player (`Player.rating/1`, the TRF
  rows) reads the right one without knowing about periods.

  Where it is used:

    * the rating-based tie-breaks use one rating per player, the one valid
      in `tiebreak_round/1`: the first by default (C.07 Article 10), or the
      round the arbiter chose (`tiebreak_rating_round`);
    * the expected score (We, W-We) of each game uses both players' ratings
      in that game's round;
    * a TRF of chosen rounds writes, in each `001` line, the FIDE rating
      valid in the file's first round: a long event is reported to FIDE
      period by period, each with that period's rating.

  Nothing changes while `long_event` is off: `at_round/3` returns the player
  untouched.
  """

  alias PairingsEngine.Tournaments.Tournament

  @max_rating 4000

  @doc """
  `text` ("5:1850, 9:1872" - round, colon, FIDE rating) as a sorted
  `period_ratings` list, or `:error`. Blank is the empty list.
  """
  def parse(text) when is_binary(text) do
    text
    |> String.split([",", ";", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while([], fn token, acc ->
      with [round, rating] <- String.split(token, ":", parts: 2),
           {round, ""} <- Integer.parse(String.trim(round)),
           {rating, ""} <- Integer.parse(String.trim(rating)) do
        {:cont, [%{"from_round" => round, "fide_rating" => rating} | acc]}
      else
        _ -> {:halt, :error}
      end
    end)
    |> case do
      :error -> :error
      list -> list |> Enum.reverse() |> normalize()
    end
  end

  @doc """
  Checks and orders a `period_ratings` list (string or atom keys, as a JSON
  import brings it): rounds from 2 on, ratings 0-#{@max_rating}, one entry
  per round (the last given wins), sorted by round.
  """
  def normalize(list) when is_list(list) do
    list
    |> Enum.reduce_while([], fn entry, acc ->
      case entry(entry) do
        {:ok, e} -> {:cont, [e | acc]}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      :error ->
        :error

      entries ->
        {
          :ok,
          # `entries` is in reverse, so the last one given per round is kept.
          entries
          |> Enum.uniq_by(& &1["from_round"])
          |> Enum.sort_by(& &1["from_round"])
        }
    end
  end

  def normalize(_other), do: :error

  defp entry(%{} = e) do
    round = int(Map.get(e, "from_round", Map.get(e, :from_round)))
    fide = int(Map.get(e, "fide_rating", Map.get(e, :fide_rating)))
    national = int(Map.get(e, "national_rating", Map.get(e, :national_rating)))

    cond do
      not (is_integer(round) and round >= 2 and round <= Tournament.max_rounds()) ->
        :error

      not rating?(fide) ->
        :error

      not (is_nil(national) or rating?(national)) ->
        :error

      is_nil(national) ->
        {:ok, %{"from_round" => round, "fide_rating" => fide}}

      true ->
        {:ok, %{"from_round" => round, "fide_rating" => fide, "national_rating" => national}}
    end
  end

  defp entry(_other), do: :error

  defp rating?(n), do: is_integer(n) and n >= 0 and n <= @max_rating

  defp int(n) when is_integer(n), do: n

  defp int(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {n, ""} -> n
      _ -> :invalid
    end
  end

  defp int(nil), do: nil
  defp int(_other), do: :invalid

  @doc "A `period_ratings` list as the form writes it: \"5:1850, 9:1872\"."
  def format(list) when is_list(list) do
    Enum.map_join(list, ", ", &"#{&1["from_round"]}:#{&1["fide_rating"]}")
  end

  def format(_other), do: ""

  @doc """
  `player` as they stood in `round`: the rating fields hold the ratings
  valid then - the last `period_ratings` entry whose round is reached, or
  the first rating before any. With a tournament, only while it is a long
  event (`long_event`); otherwise the player is returned untouched.
  """
  def at_round(player, round, %{long_event: true}), do: at_round(player, round)
  def at_round(player, _round, _tournament), do: player

  def at_round(%{period_ratings: [_ | _] = list} = player, round) when is_integer(round) do
    case list |> Enum.filter(&(&1["from_round"] <= round)) |> List.last() do
      nil ->
        player

      entry ->
        %{
          player
          | fide_rating: entry["fide_rating"],
            national_rating: Map.get(entry, "national_rating", player.national_rating)
        }
    end
  end

  def at_round(player, _round), do: player

  @doc """
  FIDE's expected score (We, rating regulations Table 8.1.2) of `player`
  over `games` (finished games, each with `:round`, `:opponent_id` and
  `:points`), and the points scored in the games it counts, as
  `{we, w}`. A game counts when both players are rated in its round - for a
  long event each with the rating valid in that round (VCL4THP Q213).
  `we` is nil when no game counts, as `PlayerStats.we/2`'s is.
  """
  def expected_score(player, games, players_by_id, tournament) do
    alias PairingsEngine.PlayerStats
    alias PairingsEngine.Tournaments.Player

    counted =
      for game <- games,
          opponent = Map.get(players_by_id, game.opponent_id),
          not is_nil(opponent),
          own = player |> at_round(game.round, tournament) |> Player.rating(),
          opp = opponent |> at_round(game.round, tournament) |> Player.rating(),
          own > 0 and opp > 0,
          do: {PlayerStats.expected_score(own - opp), game.points}

    case counted do
      [] ->
        {nil, nil}

      _ ->
        {counted |> Enum.map(&elem(&1, 0)) |> Enum.sum() |> Float.round(2),
         counted |> Enum.map(&elem(&1, 1)) |> Enum.sum()}
    end
  end

  @doc """
  The round whose ratings the rating-based tie-breaks use as each player's
  one rating: the one the arbiter chose for a long event, otherwise 1 - the
  first rating (C.07 Article 10). With `per_round_tiebreaks?/1` on, the
  chosen round is ignored: the opponents' ratings come round by round, and
  the one rating left (RTNG, who counts as unrated) is the first.
  """
  def tiebreak_round(%{long_event: true, tiebreak_rating_per_round: true}), do: 1

  def tiebreak_round(%{long_event: true, tiebreak_rating_round: r}) when is_integer(r) and r > 0,
    do: r

  def tiebreak_round(_tournament), do: 1

  @doc """
  Whether the rating-based tie-breaks count each opponent at the rating
  they held in the round the game was played (VCL4THP Q214): a long event
  whose arbiter ticked it. C.07 Article 10's note makes the first rating
  the rule "unless the specific regulations of the tournament state
  otherwise"; this is the otherwise, so it is never the default.
  """
  def per_round_tiebreaks?(%{long_event: true, tiebreak_rating_per_round: true}), do: true
  def per_round_tiebreaks?(_tournament), do: false

  @doc """
  What the rating-based tie-breaks of `tournament` count each opponent at,
  as `:per_round`, `{:round, n}` or `:first`.
  """
  def tiebreak_rating_basis(tournament) do
    cond do
      per_round_tiebreaks?(tournament) -> :per_round
      tiebreak_round(tournament) > 1 -> {:round, tiebreak_round(tournament)}
      true -> :first
    end
  end

  @doc """
  Whether `tournament`'s dates span more than 30 days - the round dates
  when it has them, else its start and end dates. The settings page
  suggests the long-event flag then (VCL4THP Q210).
  """
  def spans_over_30_days?(tournament), do: (span_days(tournament) || 0) > 30

  @doc "Days from the first to the last of `tournament`'s dates, nil without two."
  def span_days(tournament) do
    dates =
      [Map.get(tournament, :start_date), Map.get(tournament, :end_date)]
      |> Kernel.++(Map.get(tournament, :round_dates) || [])
      |> Enum.flat_map(&date/1)

    case dates do
      [_, _ | _] -> Date.diff(Enum.max(dates, Date), Enum.min(dates, Date))
      _ -> nil
    end
  end

  defp date(value) when is_binary(value) do
    case value |> String.trim() |> String.replace("/", "-") |> Date.from_iso8601() do
      {:ok, d} -> [d]
      _ -> []
    end
  end

  defp date(%Date{} = d), do: [d]
  defp date(_other), do: []
end
