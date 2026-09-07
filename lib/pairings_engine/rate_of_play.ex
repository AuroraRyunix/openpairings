defmodule PairingsEngine.RateOfPlay do
  @moduledoc """
  The rate-of-play (time-control cadence) preset catalogue, keyed by the
  tournament's `standard` classification - Standard / Rapid / Blitz.

  Single source of truth for both the "New tournament" form
  (`PairingsEngineWeb.TournamentsLive`) and the Options settings page
  (`PairingsEngineWeb.SettingsOptionsLive`), so the two never drift apart and
  the create form offers the same rich, cadence-appropriate list the settings
  page does. The lists follow the FIDE-style descriptors SWAR's own Cadence
  field uses (e.g. `"90min/40moves+30min/end+30sec/move from move 1"`).

  The `standard` value is the tournament's own classification; anything other
  than `"rapid"`/`"blitz"` (including `""`/`nil`) falls back to the Standard
  list, matching how the rest of the app defaults `standard`.
  """

  @standard_options [
    {"standard", "Standard"},
    {"rapid", "Rapid"},
    {"blitz", "Blitz"}
  ]

  @standard [
    "90min/40moves+30min/end+30sec/move from move 1",
    "100min/40moves+50min/20moves+15min/end+30sec/move from move 1",
    "100min/end+30sec/move from move 1",
    "105min/40moves+15min/end",
    "120min/40moves+15min/end+30sec/move from move 40",
    "120min/40moves+30min/end",
    "120min/10moves+30min/end+30sec/move from move 40",
    "120min/end",
    "120min/end+10sec/move from move 40",
    "120min/end+30sec/move from move 1",
    "120min/end+30sec/move from move 40",
    "150min/end",
    "90min/40moves+15min/end+30sec/move from move 1",
    "90min/end",
    "90min/end+10sec/move from move 1",
    "90min/end+30sec/move from move 1",
    "90min/end+30sec DELAY /move from move 1",
    "75min/end+30sec/move from move 1",
    "65min/end",
    "60min/end",
    "60min/end+30sec/move from move 1",
    "40min/end+30sec/move from move 1",
    "30min/end+30sec/move from move 1"
  ]

  @rapid [
    "15min/end+10sec/move from move 1",
    "15min/end",
    "15min/end+5sec/move from move 1",
    "15min/end+15sec/move from move 1",
    "25min/end+10sec/move from move 1",
    "25min/end+15sec/move from move 1",
    "25min/end+5sec/move from move 1",
    "25min/end",
    "20min/end",
    "20min/end+10sec/move from move 1",
    "20min/end+15sec/move from move 1",
    "20min/end+5sec/move from move 1",
    "30min/end",
    "30min/end+10sec/move from move 1",
    "30min/end+20sec/move from move 1",
    "10min/end+5sec/move from move 1",
    "10min/end+10sec/move from move 1",
    "10min/end+15sec/move from move 1",
    "10min/end+2sec/move from move 1",
    "10min/end+5sec DELAY /move from move 1",
    "12min/end",
    "12min/end+3sec/move from move 1",
    "12min/end+5sec/move from move 1",
    "12min/end+10sec/move from move 1",
    "13min/end+3sec/move from move 1",
    "13min/end+5sec/move from move 1",
    "11min/end",
    "40min/end+10sec/move from move 1",
    "45min/end",
    "59min/end",
    "8min/end+4sec/move from move 1"
  ]

  @blitz [
    "5min/end+3sec/move from move 1",
    "5min/end+2sec/move from move 1",
    "5min/end",
    "5min/end+3sec DELAY /move from move 1",
    "3min/end+2sec/move from move 1",
    "3min/end+3sec/move from move 1",
    "4min/end+2sec/move from move 1",
    "4min/end+3sec/move from move 1",
    "6min/end+2sec/move from move 1",
    "6min/end+3sec/move from move 1",
    "7min/end+2sec/move from move 1",
    "7min/end+3sec/move from move 1",
    "8min/end+2sec/move from move 1",
    "8min/end+3sec/move from move 1",
    "10min/end"
  ]

  @doc "The `{value, label}` pairs for the Standard / Rapid / Blitz classification select."
  def standard_options, do: @standard_options

  @doc """
  The ordered list of preset cadences for `standard` - the Rapid list for
  `"rapid"`, the Blitz list for `"blitz"`, otherwise the Standard list.
  """
  def list_for("rapid"), do: @rapid
  def list_for("blitz"), do: @blitz
  def list_for(_standard), do: @standard

  @doc """
  The options to render in a rate-of-play `<select>` for `standard`: a leading
  blank (`""`, shown as "- none -") plus `list_for/1`. If `current` is a
  non-blank value that isn't one of the presets for this classification (a
  custom cadence, or one carried over from a different classification), it is
  prepended so the select still shows the saved value rather than silently
  dropping it.
  """
  def select_options(standard, current) do
    list = list_for(standard)

    if current not in [nil, ""] and current not in list do
      [current, "" | list]
    else
      ["" | list]
    end
  end

  @doc """
  The tournament's rate of play as TRF26's `222` line encodes it, or `nil`
  where the wording cannot be encoded.

  The grammar is `d[:d]`, each `d` a period `[moves/]seconds[+increment]`:
  `90min/40moves+30min/end+30sec/move from move 1` is `40/5400+30:1800+30`,
  `150min/end` is `9000`, `5min/end+2sec/move from move 1` is `300+2`.

  An increment is a property of a period, so "from move N" is encoded only
  when N is 1 or the first move of a period (or the move before it, which
  is how this catalogue words "after the first time control"). A Bronstein
  DELAY, and any wording this catalogue does not use, come back as `nil`
  and the line is left out: `222` is mandatory for rating, and a wrong one
  is worse than a missing one.
  """
  @spec trf26_code(String.t() | nil) :: String.t() | nil
  def trf26_code(nil), do: nil

  def trf26_code(text) when is_binary(text) do
    with false <- text =~ ~r/delay/i,
         {:ok, periods, increment} <- split_rate(String.trim(text)),
         {:ok, encoded} <- encode_periods(periods, increment) do
      Enum.join(encoded, ":")
    else
      _ -> nil
    end
  end

  # "90min/40moves+30min/end+30sec/move from move 1": the periods, and the
  # increment if the last part is one.
  defp split_rate(text) do
    parts = text |> String.split("+") |> Enum.map(&String.trim/1)

    {increment, periods} =
      case parse_increment(List.last(parts)) do
        nil -> {nil, parts}
        increment -> {increment, Enum.drop(parts, -1)}
      end

    with {:ok, periods} <- parse_periods(periods), do: {:ok, periods, increment}
  end

  defp parse_increment(part) do
    case Regex.run(~r/^(\d+)sec\/move(?:\s+from\s+move\s+(\d+))?$/i, part) do
      [_, seconds] -> {String.to_integer(seconds), 1}
      [_, seconds, from] -> {String.to_integer(seconds), String.to_integer(from)}
      nil -> nil
    end
  end

  # A period is "Nmin/Mmoves" or, last and only last, "Nmin/end".
  defp parse_periods([]), do: :error

  defp parse_periods(parts) do
    periods =
      Enum.map(parts, fn part ->
        cond do
          match = Regex.run(~r/^(\d+)min\/(\d+)moves$/i, part) ->
            [_, minutes, moves] = match
            {String.to_integer(moves), String.to_integer(minutes) * 60}

          match = Regex.run(~r/^(\d+)min\/end$/i, part) ->
            [_, minutes] = match
            {:end, String.to_integer(minutes) * 60}

          true ->
            :error
        end
      end)

    {earlier, [last]} = Enum.split(periods, -1)

    if :error in periods or match?({:end, _}, last) == false or
         Enum.any?(earlier, &match?({:end, _}, &1)) do
      :error
    else
      {:ok, periods}
    end
  end

  defp encode_periods(periods, increment) do
    starts =
      periods
      |> Enum.scan(1, fn
        {moves, _seconds}, start when is_integer(moves) -> start + moves
        {:end, _seconds}, start -> start
      end)
      |> then(&[1 | Enum.drop(&1, -1)])

    with {:ok, from_period} <- increment_period(increment, starts) do
      encoded =
        periods
        |> Enum.with_index()
        |> Enum.map(fn {period, i} ->
          plus =
            case increment do
              {seconds, _from} when i >= from_period -> "+#{seconds}"
              _ -> ""
            end

          case period do
            {:end, seconds} -> "#{seconds}#{plus}"
            {moves, seconds} -> "#{moves}/#{seconds}#{plus}"
          end
        end)

      {:ok, encoded}
    end
  end

  # Which period the increment starts in: none, all, or one that begins at
  # (or right after) the named move.
  defp increment_period(nil, _starts), do: {:ok, :none}
  defp increment_period({_seconds, from}, _starts) when from <= 1, do: {:ok, 0}

  defp increment_period({_seconds, from}, starts) do
    case Enum.find_index(starts, &(&1 in [from, from + 1])) do
      nil -> :error
      index -> {:ok, index}
    end
  end
end
