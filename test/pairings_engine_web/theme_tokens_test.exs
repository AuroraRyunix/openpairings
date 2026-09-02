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
    offenders = literal_offenders(uncommented(components()))

    assert offenders == [],
           "these colours are written into component rules instead of coming from " <>
             "a token: #{Enum.join(offenders, ", ")}. A literal cannot follow the " <>
             "theme - add it to the palette, use --warn/--danger/--success/--accent, " <>
             "or list it as literal by design."
  end

  # ---------------------------------------------------------------------------
  # Inline `style="..."` attributes in templates.
  #
  # The three tests above read `app.css` and nothing else, which is how
  # `border: 2px solid var(--color-warning, #b45309)` sat in standings_live.ex
  # for as long as it did: a hardcoded amber AND a daisyUI token, in a file the
  # stylesheet tests never opened. A style attribute is a stylesheet with worse
  # ergonomics, so it gets the same reading.
  # ---------------------------------------------------------------------------

  # `style="..."` and `style={"..."}` both appear; the second is the HEEx form.
  # Elixir interpolations are dropped rather than analysed - `#{h}px` is a
  # length, and its `#` must not be read as the start of a hex colour.
  defp inline_styles do
    Path.wildcard("lib/pairings_engine_web/**/*.ex")
    |> Enum.flat_map(fn file ->
      ~r/style=\{?"([^"]*)"/
      |> Regex.scan(File.read!(file))
      |> Enum.map(fn [_, style] -> style end)
    end)
    |> Enum.join("\n")
    |> String.replace(~r/\#\{[^}]*\}/, "")
  end

  test "inline styles in templates take their colour from the palette too" do
    offenders = literal_offenders(inline_styles())

    assert offenders == [],
           "these colours are written into inline style attributes in " <>
             "lib/pairings_engine_web: #{Enum.join(offenders, ", ")}. A template is " <>
             "not exempt - use a token, or list it as literal by design."
  end

  # ---------------------------------------------------------------------------
  # "Defined somewhere" is not the same as "follows the theme".
  # ---------------------------------------------------------------------------

  # Tokens that are legitimately the same in every theme, each with the reason
  # it is not a theme decision:
  #
  #   --tl-hue / --hist-hue  an HSL triple set per event KIND ("pairings" is
  #                          blue, "imports" is pink) on the timeline and
  #                          history rows. It identifies the kind of change,
  #                          not the surface it sits on, so it stays put.
  #   --swap-color           written onto each seat by `board_card/1` from the
  #                          player's own colour - identity, not palette.
  #   --swatch               same shape: the accent picker paints each button
  #                          with the accent it OFFERS, which by definition is
  #                          not the accent currently in force.
  #   --surface-2            a style alias, only ever read as
  #                          `var(--surface-2, var(--surface))`. It degrades to
  #                          a themed token, so it follows the theme even when
  #                          nothing defines it.
  #   --pe-bg-alt            the same, for the legacy inline-style name.
  #   --tl-parent-lane       a lane INDEX, not a colour - listed only because
  #                          it is defined nowhere at all, and an undefined
  #                          token is assumed to be a colour (see
  #                          `colour_token?/2`). Its absence is a real defect
  #                          in `.tl-fork` - `left`/`width` are invalid without
  #                          it - but a geometry one, out of this file's remit.
  #
  # Geometry that IS defined (--radius, the rail/lane/step tokens) needs no
  # entry here: it is recognised by its value and skipped automatically.
  @theme_independent ~w(--tl-hue --hist-hue --swap-color --swatch --surface-2 --pe-bg-alt
                        --tl-parent-lane)

  test "every colour token a component reads is one the themes actually override" do
    themed =
      theme_blocks()
      |> Enum.flat_map(fn {_name, body} -> tokens_in(body) end)
      |> MapSet.new()

    assert MapSet.size(themed) > 15,
           "found only #{MapSet.size(themed)} themed tokens - the theme blocks moved"

    # A `@plugin` block is daisyUI's own configuration, not a theme block. A
    # token defined ONLY there - `--color-warning`, `--color-success` - is a
    # fixed oklch in all ten themes, which is the whole bug: Nord's arctic
    # surface with daisyUI's amber sitting on it.
    values = definitions()
    inline = inline_styles()

    offenders =
      ~r/var\((--[a-z0-9-]+)/
      |> Regex.scan(uncommented(components()) <> "\n" <> inline)
      |> Enum.map(fn [_, name] -> name end)
      |> Enum.uniq()
      |> Enum.reject(&(&1 in themed))
      |> Enum.reject(&(&1 in @theme_independent))
      # Set per element from a template: identity or per-instance geometry, so
      # searched for rather than listed, and a new one needs no allowlist entry.
      |> Enum.reject(&(&1 in set_inline()))
      |> Enum.reject(&(&1 in set_from_style_attribute(inline)))
      |> Enum.filter(&colour_token?(&1, values))
      |> Enum.sort()

    assert offenders == [],
           "these tokens are read for a COLOUR by a component but no " <>
             "[data-theme] block overrides them: #{Enum.join(offenders, ", ")}. " <>
             "Whatever value they have is the value in all ten themes - define " <>
             "them per theme, switch to --warn/--danger/--success/--accent, or " <>
             "document them in @theme_independent."
  end

  # `set_inline/0` only sees a custom property that opens a style attribute
  # (`style={"--swatch: ..."}`). One further along a multi-declaration
  # attribute - `"width: ...; --pe-hover-min: ...px"` - is set per element just
  # the same, so the whole attribute is read here.
  defp set_from_style_attribute(styles) do
    ~r/(--[a-z0-9-]+)\s*:/
    |> Regex.scan(styles)
    |> MapSet.new(fn [_, name] -> name end)
  end

  # Every `--token: value` pair in the stylesheet, grouped by name. Used to ask
  # what KIND of thing a token holds, which decides whether failing to follow
  # the theme matters.
  defp definitions do
    ~r/(--[a-z0-9-]+)\s*:\s*([^;}\n]*)/
    |> Regex.scan(uncommented(@css))
    |> Enum.group_by(fn [_, name, _] -> name end, fn [_, _, value] -> String.trim(value) end)
  end

  @colour_syntax ~r/#[0-9a-f]{3,8}\b|\b(?:rgba?|hsla?|oklch|oklab|color-mix)\(|\b(?:white|black|transparent|currentcolor)\b/i

  # A token holds a colour if any definition of it looks like one. A token with
  # definitions, none of which are colours, is geometry (`--radius: 8px`,
  # `--tl-lane: 0`) and may safely be theme-independent. A token with NO
  # definition at all is the worst case, not the safe one - `var(--muted)` was
  # a typo for `--text-soft` and rendered as nothing in every theme - so it
  # counts as a colour and gets reported.
  defp colour_token?(name, values) do
    case Map.get(values, name) do
      nil -> true
      defs -> Enum.any?(defs, &Regex.match?(@colour_syntax, &1))
    end
  end

  # ---------------------------------------------------------------------------
  # Literal detection, shared by the CSS and template scans.
  # ---------------------------------------------------------------------------

  # `#rrggbb` was the only form checked, so `oklch(...)`, `hsl(...)` and
  # `rgb(...)` could name a colour in a component rule unchallenged.
  defp literal_offenders(text) do
    hexes = ~r/#[0-9a-fA-F]{6}\b/ |> Regex.scan(text) |> Enum.map(fn [hex] -> hex end)

    functions =
      ~r/\b(?:oklch|oklab|hsla?|rgba?)\([^()]*\)/i
      |> Regex.scan(text)
      |> Enum.map(fn [form] -> form end)
      # `hsl(var(--tl-hue, ...))` is a token being read, not a literal being
      # written; the fallback inside it is covered by the fallback test.
      |> Enum.reject(&String.contains?(&1, "var("))

    (hexes ++ functions)
    |> Enum.map(&normalise/1)
    |> Enum.uniq()
    |> Enum.reject(&(&1 in @literal_by_design))
    |> Enum.reject(&near_greyscale?/1)
  end

  # `rgb(46, 94, 68)` and `#2e5e44` are the same colour and must answer to the
  # same allowlist, so numeric sRGB is folded to hex before either check.
  defp normalise(form) do
    case Regex.run(~r/^rgba?\(\s*(\d+)[,\s]+\s*(\d+)[,\s]+\s*(\d+)/i, form) do
      [_, r, g, b] -> hex_of([r, g, b])
      nil -> String.downcase(form)
    end
  end

  defp hex_of(parts) do
    "#" <>
      Enum.map_join(parts, "", fn c ->
        c
        |> String.to_integer()
        |> Integer.to_string(16)
        |> String.downcase()
        |> String.pad_leading(2, "0")
      end)
  end

  # Greys, whites and blacks carry no hue to clash with, and are what shadows
  # and hairlines are made of. Each colour space says "no hue" differently:
  # sRGB by having no spread between channels, HSL by saturation, oklch by
  # chroma.
  defp near_greyscale?("#" <> hex) do
    [r, g, b] = for <<pair::binary-2 <- hex>>, do: String.to_integer(pair, 16)
    Enum.max([r, g, b]) - Enum.min([r, g, b]) <= 16
  end

  defp near_greyscale?("hsl" <> _ = form), do: nth_number(form, 1) <= 6.0
  defp near_greyscale?("okl" <> _ = form), do: nth_number(form, 1) <= 0.02
  defp near_greyscale?(_), do: false

  defp nth_number(form, index) do
    ~r/-?\d+(?:\.\d+)?/
    |> Regex.scan(form)
    |> Enum.map(fn [n] ->
      String.to_float(if String.contains?(n, "."), do: n, else: n <> ".0")
    end)
    |> Enum.at(index, 100.0)
  end
end
