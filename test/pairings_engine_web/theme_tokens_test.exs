defmodule PairingsEngineWeb.ThemeTokensTest do
  use ExUnit.Case, async: true

  @moduledoc """
  The stylesheet, checked as data.

  Ten themes are offered, and components kept being written against a colour
  literal instead of a token - so they looked right in the two themes their
  author had open and wrong in the other eight. Nord renders `#d97706` as a
  mustard box in the middle of an arctic palette; nobody saw it, because
  nobody was running Nord.

  These read the stylesheet rather than the rendered page, so they cost
  nothing, cannot flake, and fail on the line that introduced the problem.
  """

  @css File.read!("assets/css/app.css")

  # The palette is `:root`, the `[data-theme=...]` blocks and the
  # `[data-accent=...]` overrides - everything that exists to DEFINE colour.
  # The component rules start at the first real selector after it, and those
  # must go through the tokens rather than naming colours themselves.
  @palette_end (case :binary.match(@css, "
html { background:") do
                  {at, _} -> at
                  :nomatch -> raise "the palette/component boundary moved"
                end)

  defp palette, do: binary_part(@css, 0, @palette_end)
  defp components, do: binary_part(@css, @palette_end, byte_size(@css) - @palette_end)

  # Comments explain colours by naming them, which is not the same as using
  # one. Stripped before any literal is counted.
  defp uncommented(css), do: String.replace(css, ~r|/\*.*?\*/|s, "")

  defp theme_blocks do
    ~r/\[data-theme="([a-z-]+)"\]\s*\{(.*?)\n\}/s
    |> Regex.scan(palette())
    |> Enum.map(fn [_, name, body] -> {name, body} end)
  end

  defp tokens_in(body) do
    ~r/^\s*(--[a-z0-9-]+)\s*:/m
    |> Regex.scan(body)
    |> MapSet.new(fn [_, name] -> name end)
  end

  test "every theme redefines the tokens the other themes all redefine" do
    themes = theme_blocks()
    assert length(themes) >= 9, "expected the full set of themes, found #{length(themes)}"

    # The themes are their own specification. A `[data-theme]` block sits on
    # the same element as `:root`, so anything it omits simply inherits -
    # correct for geometry (`--radius`) and for aliases only some themes
    # bother with. What is NOT correct is inheriting a COLOUR: a theme that
    # redefines the surface but forgets `--warn` puts the default palette's
    # amber on its own background, which is this bug exactly.
    #
    # So the bar is what the other themes agree on - a token eight of ten of
    # them override is one the ninth cannot afford to skip.
    threshold = div(length(themes) * 4, 5)

    required =
      themes
      |> Enum.flat_map(fn {_name, body} -> tokens_in(body) end)
      |> Enum.frequencies()
      |> Enum.filter(fn {_token, n} -> n >= threshold end)
      |> MapSet.new(fn {token, _n} -> token end)

    for token <- ~w(--warn --danger --success --accent --bg --surface --text) do
      assert token in required,
             "#{token} is not being treated as required - this test has stopped " <>
               "checking the thing it exists for"
    end

    for {name, body} <- themes do
      missing = MapSet.difference(required, tokens_in(body))

      assert MapSet.equal?(missing, MapSet.new()),
             "theme #{name} does not redefine #{inspect(MapSet.to_list(missing))}, " <>
               "so it inherits the default palette's value onto its own background"
    end
  end

  test "no rule falls back to a literal for a token that does not exist" do
    # Anywhere in the stylesheet, not just the palette: `--tl-hue` is set per
    # history-event kind on the component itself, which is a fine place for a
    # token that means "this row's colour" rather than "this theme's amber".
    defined =
      ~r/(--[a-z0-9-]+)\s*:/
      |> Regex.scan(uncommented(@css))
      |> MapSet.new(fn [_, name] -> name end)

    # `var(--x, fallback)` is a safety net only when `--x` exists. When it
    # does not, the fallback is not a fallback - it is the value, in every
    # theme, forever. `--ok`/`--ok-soft` were exactly that: referenced four
    # times, defined nowhere, so the OpenResults visibility toggles rendered
    # one fixed green whatever theme was on.
    # Only a fallback to a LITERAL is a problem. `var(--surface-2,
    # var(--surface))` degrades to another token and still follows the theme,
    # so it is a stylistic wart rather than a bug.
    for [_, name, fallback] <- Regex.scan(~r/var\((--[a-z0-9-]+),\s*([^)]*)/, uncommented(@css)),
        not String.contains?(fallback, "var(") do
      assert name in defined or name in set_inline(),
             "#{name} is used with a fallback but never defined, so the fallback " <>
               "always wins - either define it in the palette or use the token " <>
               "that exists"
    end
  end

  # Some tokens are set per element from a template rather than in the
  # stylesheet - `--swap-color` is written onto each seat by `board_card/1`,
  # because it identifies a player and is not a theme decision. Searched for
  # rather than listed here, so the list cannot drift.
  defp set_inline do
    Path.wildcard("lib/**/*.ex")
    |> Enum.flat_map(&Regex.scan(~r/"(--[a-z0-9-]+):/, File.read!(&1)))
    |> MapSet.new(fn [_, name] -> name end)
  end

  # Literal by design: the two chess seat colours (a white piece is white in
  # Nord too) and the signed-out marketing panel, which is one deliberate
  # brand look rather than a themed surface.
  @literal_by_design ~w(#f7f3e8 #1c1a15 #3f8060 #2e5e44 #1d4030 #8fe0b4)

  test "component rules take their colour from the palette, not from a literal" do
    offenders =
      ~r/#[0-9a-fA-F]{6}\b/
      |> Regex.scan(uncommented(components()))
      |> Enum.map(fn [hex] -> String.downcase(hex) end)
      |> Enum.uniq()
      |> Enum.reject(&(&1 in @literal_by_design))
      |> Enum.reject(&near_greyscale?/1)

    assert offenders == [],
           "these colours are written into component rules instead of coming from " <>
             "a token: #{Enum.join(offenders, ", ")}. A literal cannot follow the " <>
             "theme - add it to the palette, use --warn/--danger/--success/--accent, " <>
             "or list it as literal by design."
  end

  # Greys, whites and blacks carry no hue to clash with, and are what shadows
  # and hairlines are made of.
  defp near_greyscale?("#" <> hex) do
    [r, g, b] = for <<pair::binary-2 <- hex>>, do: String.to_integer(pair, 16)
    Enum.max([r, g, b]) - Enum.min([r, g, b]) <= 16
  end
end
