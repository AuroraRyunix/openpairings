defmodule PairingsEngineWeb.Chess960Diagram do
  @moduledoc """
  The starting position of a Chess960 round as a small SVG board, for the
  Pairings page (shown when the position badge is hovered or clicked) and the
  printed pairings.

  Only the four occupied ranks differ from game to game, so the board is drawn
  from the first-rank piece order (`PairingsEngine.Chess960.position/1`):
  White's pieces on rank 1, pawns on 2 and 7, Black's pieces mirrored on 8.

  The pieces are Unicode chess glyphs (the filled set for both sides, White's
  filled light with a dark outline), so no image files are needed and the
  diagram prints sharp. U+FE0E after each glyph asks for the text form, not
  an emoji, which the pawn otherwise gets on some systems.
  """

  alias PairingsEngine.Chess960

  @square 40
  @margin 18
  @glyphs %{
    "K" => "♚",
    "Q" => "♛",
    "R" => "♜",
    "B" => "♝",
    "N" => "♞",
    "P" => "♟"
  }

  @doc """
  The diagram of position `n` (0..959) as an SVG string. `title` is the
  accessible name (defaults to "Chess960 position <n> <order>").
  """
  def svg(n, title \\ nil) when is_integer(n) and n >= 0 and n < 960 do
    order = Chess960.position(n)
    size = @square * 8 + @margin
    title = title || "Chess960 #{n} #{order}"

    squares =
      for rank <- 1..8, file <- 0..7, into: "" do
        light? = rem(rank + file, 2) == 1
        {x, y} = origin(rank, file)

        ~s(<rect x="#{x}" y="#{y}" width="#{@square}" height="#{@square}" fill="#{if light?, do: "#f0d9b5", else: "#b58863"}"/>)
      end

    pieces =
      order
      |> String.graphemes()
      |> Enum.with_index()
      |> Enum.map_join(fn {piece, file} ->
        piece(piece, 1, file, :white) <>
          piece("P", 2, file, :white) <>
          piece("P", 7, file, :black) <> piece(piece, 8, file, :black)
      end)

    coords =
      Enum.map_join(0..7, fn file ->
        x = @margin + file * @square + div(@square, 2)

        ~s(<text x="#{x}" y="#{size - 4}" class="c960-coord" text-anchor="middle">#{<<?a + file>>}</text>)
      end) <>
        Enum.map_join(1..8, fn rank ->
          {_x, y} = origin(rank, 0)

          ~s(<text x="#{div(@margin, 2)}" y="#{y + div(@square, 2) + 4}" class="c960-coord" text-anchor="middle">#{rank}</text>)
        end)

    ~s(<svg class="c960-board" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{size} #{size}" role="img" aria-label="#{escape(title)}">) <>
      ~s(<title>#{escape(title)}</title>) <>
      squares <>
      ~s(<g font-family="'Segoe UI Symbol','Noto Sans Symbols 2','DejaVu Sans','Apple Symbols',serif" font-size="34" text-anchor="middle">) <>
      pieces <>
      "</g>" <>
      ~s(<g font-family="system-ui,sans-serif" font-size="11" fill="currentColor">) <>
      coords <> "</g></svg>"
  end

  defp origin(rank, file), do: {@margin + file * @square, (8 - rank) * @square}

  defp piece(letter, rank, file, side) do
    {x, y} = origin(rank, file)
    cx = x + div(@square, 2)
    cy = y + @square - 8

    style =
      case side do
        :white ->
          ~s(fill="#fbfaf6" stroke="#1d1b18" stroke-width="1.1" paint-order="stroke")

        :black ->
          ~s(fill="#1d1b18" stroke="#1d1b18" stroke-width="0.4")
      end

    ~s(<text x="#{cx}" y="#{cy}" #{style}>#{Map.fetch!(@glyphs, letter)}︎</text>)
  end

  defp escape(text) do
    text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end
end
