defmodule PairingsEngine.BoardRanges do
  @moduledoc """
  Board numbers as an arbiter types them - `1-20, 35, 40-45` - read into
  ranges, written back out the same way, and asked whether a board is in
  them.

  Separators are commas, semicolons or spaces; a range is two numbers with
  a hyphen (or an en dash, for whoever pasted it from a document) between
  them. Overlapping and touching ranges are merged, so `1-5, 3-8, 9`
  comes back as `1-9`. An empty text is no ranges, which a filter reads as
  every board.

  A board's number is the whole number its printed label starts with:
  `12` is 12, a team board `3.1` is 3 (the match's table), and a fixed
  table shared by two fixed-board players, `1001/1002`, is both.

  A tournament's rooms are written in it (`PairingsEngine.Rooms`), and so
  are the plug-ins' board filters, so that "1-20" means one thing however
  many programs read it. The Polis program carries a copy
  (`Polis.BoardRanges`) to say what a text means before it is sent; this
  one is the one that decides.
  """

  @max 9_999

  @type range :: {pos_integer(), pos_integer()}

  @doc "Ranges from text: `{:ok, ranges}` or `{:error, {:bad | :backwards | :too_big, token}}`."
  @spec parse(String.t() | nil) :: {:ok, [range()]} | {:error, {atom(), String.t()}}
  def parse(nil), do: {:ok, []}

  def parse(text) when is_binary(text) do
    text
    |> String.replace("–", "-")
    # "1 - 20" is one range, not three tokens.
    |> String.replace(~r/\s*-\s*/, "-")
    |> String.split([",", ";", " ", "\t", "\n", "\r"], trim: true)
    |> Enum.reduce_while({:ok, []}, fn token, {:ok, acc} ->
      case token(token) do
        {:ok, range} -> {:cont, {:ok, [range | acc]}}
        {:error, reason} -> {:halt, {:error, {reason, token}}}
      end
    end)
    |> case do
      {:ok, ranges} -> {:ok, merge(ranges)}
      error -> error
    end
  end

  defp token(token) do
    case String.split(token, "-") do
      [one] ->
        with {:ok, n} <- number(one), do: {:ok, {n, n}}

      [from, to] ->
        with {:ok, a} <- number(from),
             {:ok, b} <- number(to) do
          if a <= b, do: {:ok, {a, b}}, else: {:error, :backwards}
        end

      _more ->
        {:error, :bad}
    end
  end

  defp number(text) do
    case Integer.parse(text) do
      {n, ""} when n >= 1 and n <= @max -> {:ok, n}
      {n, ""} when n > @max -> {:error, :too_big}
      _other -> {:error, :bad}
    end
  end

  defp merge(ranges) do
    ranges
    |> Enum.sort()
    |> Enum.reduce([], fn
      {a, b}, [{x, y} | rest] when a <= y + 1 -> [{x, max(b, y)} | rest]
      range, acc -> [range | acc]
    end)
    |> Enum.reverse()
  end

  @doc ~s(Ranges as text: `[{1, 20}, {35, 35}]` is "1-20, 35".)
  @spec format([range()]) :: String.t()
  def format(ranges) do
    Enum.map_join(ranges, ", ", fn
      {n, n} -> Integer.to_string(n)
      {a, b} -> "#{a}-#{b}"
    end)
  end

  @doc "Whether a board label is in `ranges`. No ranges is every board."
  @spec member?([range()], String.t() | integer()) :: boolean()
  def member?([], _label), do: true

  def member?(ranges, label) do
    label
    |> board_numbers()
    |> Enum.any?(fn n -> Enum.any?(ranges, fn {a, b} -> n >= a and n <= b end) end)
  end

  @doc """
  The first number two sets of ranges share, or nil when they share none.
  Both are expected merged, as `parse/1` returns them.
  """
  @spec first_shared([range()], [range()]) :: pos_integer() | nil
  def first_shared(a, b) do
    for({x1, y1} <- a, {x2, y2} <- b, max(x1, x2) <= min(y1, y2), do: max(x1, x2))
    |> Enum.min(fn -> nil end)
  end

  @doc ~s(The numbers a board label stands for: "12" is [12], "3.1" is [3], "1001/1002" both.)
  @spec board_numbers(String.t() | integer()) :: [integer()]
  def board_numbers(n) when is_integer(n), do: [n]

  def board_numbers(label) when is_binary(label) do
    label
    |> String.split("/")
    |> Enum.flat_map(fn part ->
      case Integer.parse(String.trim(part)) do
        {n, _rest} -> [n]
        :error -> []
      end
    end)
  end

  def board_numbers(_label), do: []
end
