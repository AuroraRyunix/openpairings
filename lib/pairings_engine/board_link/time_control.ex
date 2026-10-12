defmodule PairingsEngine.BoardLink.TimeControl do
  @moduledoc """
  A tournament's rate of play, read out of the descriptor the settings page
  stores (`PairingsEngine.RateOfPlay`, e.g.
  `"90min/40moves+30min/end+30sec/move from move 1"`) into numbers a clock
  and a PGN header can use.

  Best effort, and it says when it gave up: a descriptor typed by hand, a
  delay clock, anything this does not recognise comes back as `nil` rather
  than as a guess. A wrong `[TimeControl]` is worse than none.
  """

  @type t :: %{
          periods: [%{moves: pos_integer() | nil, seconds: pos_integer()}],
          increment_seconds: non_neg_integer(),
          increment_from_move: pos_integer()
        }

  @doc "The descriptor as periods and an increment, or nil."
  @spec parse(term()) :: t() | nil
  def parse(text) when is_binary(text) do
    parts = text |> String.trim() |> String.split("+", trim: true) |> Enum.map(&String.trim/1)

    {periods, increments} = Enum.split_with(parts, &(not String.contains?(&1, "sec")))

    with [_ | _] <- periods,
         {:ok, periods} <- all(periods, &period/1),
         {:ok, increment} <- increment(increments) do
      Map.put(increment, :periods, periods)
    else
      _unreadable -> nil
    end
  end

  def parse(_other), do: nil

  defp all(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, acc ++ [value]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp period(text) do
    case Regex.run(~r/\A(\d{1,4})min\/(?:(\d{1,3})moves|end)\z/, text) do
      [_, minutes] -> {:ok, %{moves: nil, seconds: String.to_integer(minutes) * 60}}
      [_, minutes, moves] -> {:ok, %{moves: String.to_integer(moves), seconds: seconds(minutes)}}
      nil -> :error
    end
  end

  defp seconds(minutes), do: String.to_integer(minutes) * 60

  defp increment([]), do: {:ok, %{increment_seconds: 0, increment_from_move: 1}}

  defp increment([text]) do
    case Regex.run(~r/\A(\d{1,3})sec\/move from move (\d{1,3})\z/, text) do
      [_, seconds, from] ->
        {:ok,
         %{
           increment_seconds: String.to_integer(seconds),
           increment_from_move: max(String.to_integer(from), 1)
         }}

      nil ->
        :error
    end
  end

  defp increment(_several), do: :error

  @doc """
  The PGN `TimeControl` value (`"40/5400+30:1800+30"`), or nil when the
  descriptor is unreadable or says something the tag cannot: an increment
  that starts at a move other than the first move of a period.
  """
  @spec pgn(term()) :: String.t() | nil
  def pgn(text) do
    with %{periods: periods, increment_seconds: seconds, increment_from_move: from} <-
           parse(text),
         {:ok, starts} <- period_starts(periods),
         index when is_integer(index) <- Enum.find_index(starts, &(&1 == from)) do
      periods
      |> Enum.with_index()
      |> Enum.map_join(":", fn {period, i} ->
        base = if period.moves, do: "#{period.moves}/#{period.seconds}", else: "#{period.seconds}"
        if seconds > 0 and i >= index, do: "#{base}+#{seconds}", else: base
      end)
    else
      _inexpressible -> nil
    end
  end

  # The move each period starts at: 1, then one past the moves before it.
  # Only the last period may run to the end of the game.
  defp period_starts(periods) do
    {starts, _next} =
      Enum.map_reduce(periods, 1, fn period, start -> {start, start + (period.moves || 0)} end)

    if periods |> Enum.drop(-1) |> Enum.all?(& &1.moves), do: {:ok, starts}, else: :error
  end
end
