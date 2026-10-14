defmodule PairingsEngineWeb.ThemeContrast do
  @moduledoc """
  Colour contrast computed from stylesheets with the WCAG 2.2 formula - not
  judged by eye. Shared by `PairingsEngineWeb.ContrastTest`, which holds the
  built-in themes to it, and `mix pairings.theme_check`, which holds a theme
  pack to the very same pairings before anybody installs it.

  Every colour is a token. A theme is `:root` (Light) or a
  `[data-theme="<id>"]` block over it; an accent replaces the accent tokens
  on top of whichever theme is on. Two checks run over every palette:

    * `pairing_failures/1` - the pairings the design system is built from:
      text on each ground, the accent on its own tint, the ink on each filled
      colour and its hover, the focus ring and the edge of a field; and
    * `rule_failures/2` - every rule in the stylesheet that sets a text
      colour and a background together, with `color-mix()` and translucent
      fills laid over the ground they sit on.

  Plus the sign-in panel (`hero_failures/2`), whose gradient follows the
  accent.
  """

  @accents ~w(green blue teal violet rose slate indigo cyan fuchsia)

  # {what it is, foreground, ground, the ratio it needs}. A ground is a token,
  # or {tint, ground} for a translucent tint laid on one.
  @pairings [
    # Text: 4.5:1 (WCAG 1.4.3).
    {"body text on the page", "text", "bg", 4.5},
    {"body text in a card", "text", "surface", 4.5},
    {"body text in a striped or raised row", "text", "surface-alt", 4.5},
    {"body text in a hovered row", "text", "surface-hover", 4.5},
    {"body text on the accent tint", "text", {"accent-soft", "surface"}, 4.5},
    {"secondary text on the page", "text-soft", "bg", 4.5},
    {"secondary text in a card", "text-soft", "surface", 4.5},
    {"secondary text in a striped row", "text-soft", "surface-alt", 4.5},
    {"secondary text in a hovered row", "text-soft", "surface-hover", 4.5},
    {"secondary text on the accent tint: the sign-in notice, a band's meta", "text-soft",
     {"accent-soft", "surface"}, 4.5},
    {"links and the current tab on the page", "accent", "bg", 4.5},
    {"links in a card", "accent", "surface", 4.5},
    {"a badge, the current tab: the accent on its own tint", "accent", {"accent-soft", "surface"},
     4.5},
    {"the accent on its own tint, on the page", "accent", {"accent-soft", "bg"}, 4.5},
    {"a primary button", "accent-ink", "accent", 4.5},
    {"a primary button, hovered", "accent-ink", "accent-hover", 4.5},
    {"errors on the page", "danger", "bg", 4.5},
    {"errors in a card", "danger", "surface", 4.5},
    {"a danger button", "danger-ink", "danger", 4.5},
    {"a danger button, hovered", "danger-ink", "danger-hover", 4.5},
    {"success text", "success", "surface", 4.5},
    {"success on its tint", "success", {"success-soft", "surface"}, 4.5},
    {"warnings", "warn", "surface", 4.5},
    {"warnings in a striped row", "warn", "surface-alt", 4.5},
    {"a warning on its tint", "warn", {"warn-soft", "surface"}, 4.5},
    {"information", "info", "surface", 4.5},
    {"information on its tint", "info", {"info-soft", "surface"}, 4.5},
    # Non-text: 3:1 (WCAG 1.4.11).
    {"the focus ring on the page", "accent", "bg", 3.0},
    {"the focus ring in a card", "accent", "surface", 3.0},
    {"the edge of a field", "text-soft", "surface", 3.0},
    {"the edge of a field on the page", "text-soft", "bg", 3.0},
    {"a status dot: live", "success", "surface", 3.0},
    {"a status dot: sending", "warn", "surface", 3.0},
    {"a status dot: offline", "danger", "surface", 3.0}
  ]

  # The rules whose ground is not where most of them sit (a card, or the page
  # around it). Measured on the ground they actually have.
  @grounds %{
    # Only ever inside a settings card.
    ".state-pill" => ["surface"],
    ".state-pill.is-on" => ["surface"],
    # Inside `.tl-diff`, which is `--surface-alt`.
    ".tl-val.before" => ["surface-alt"],
    ".tl-val.after" => ["surface-alt"]
  }

  # On the sign-in panel's gradient, which follows the accent - measured by
  # `hero_failures/2` instead.
  @on_the_hero [".auth-hero-cta-btn"]

  @doc "The accents the picker offers, the default first."
  def accents, do: @accents

  @doc "The token pairings and the ratio each needs."
  def pairings, do: @pairings

  @doc "A stylesheet with its comments removed."
  def strip_comments(css), do: Regex.replace(~r{/\*.*?\*/}s, css, "")

  @doc "Every innermost `selector { body }` in `css`, as `[selector, body]`."
  def rules(css), do: Regex.scan(~r/([^{}]+)\{([^{}]*)\}/, css, capture: :all_but_first)

  # ---------------------------------------------------------------------------
  # The checks

  @doc """
  Every pairing below its ratio, as a sentence each, for the given
  `%{{theme, accent} => palette}`.
  """
  def pairing_failures(palettes) do
    for {{theme, accent}, palette} <- palettes,
        {what, fg, ground, needed} <- @pairings,
        back = ground(palette, ground),
        palette[fg] != nil and back != nil,
        ratio = ratio(over(palette[fg], back), back),
        ratio < needed do
      "#{theme} theme, #{accent} accent: #{what} (--#{fg} on #{describe(ground)}) is " <>
        "#{Float.round(ratio, 2)}:1, needs #{needed}:1"
    end
    |> Enum.sort()
  end

  @doc """
  `{rules measured, failures}`: every rule in `css` that sets both a text
  colour and a background, measured in every palette over the ground it
  sits on.
  """
  def rule_failures(css, palettes) do
    measured =
      for [selector, body] <- rules(css),
          selector = selector |> String.trim() |> String.replace(~r/\s+/, " "),
          selector not in @on_the_hero,
          [color] <- [Regex.run(~r/(?:^|[;{\s])color:\s*([^;]+);/, body, capture: :all_but_first)],
          [background] <- [
            Regex.run(~r/(?:^|[;{\s])background(?:-color)?:\s*([^;]+);/, body,
              capture: :all_but_first
            )
          ],
          do: {selector, color, background}

    failures =
      for {selector, color, background} <- measured,
          {{theme, accent}, palette} <- palettes,
          ground <- Map.get(@grounds, selector, ["surface", "bg"]),
          back = colour(palette, background),
          fore = colour(palette, color),
          back != nil and fore != nil,
          back = over(back, palette[ground]),
          ratio = ratio(over(fore, back), back),
          ratio < 4.5,
          uniq: true do
        "#{selector} - #{theme} theme, #{accent} accent, over --#{ground}: #{Float.round(ratio, 2)}:1"
      end

    {length(measured), failures}
  end

  @doc """
  The sign-in panel: every line of text on its gradient, in every palette,
  against all three gradient stops, bare and with the corner glow laid on.
  """
  def hero_failures(css, palettes) do
    lines = [".auth-hero", ".auth-hero-sub", ".auth-features li", ".auth-hero-cta"]
    colours = for selector <- lines, into: %{}, do: {selector, rule_value(css, selector, "color")}
    glow = hero_glow(css)
    button_back = rule_value(css, ".auth-hero-cta-btn", "background")
    button_hover = rule_value(css, ".auth-hero-cta-btn:hover", "background")
    button_text = rule_value(css, ".auth-hero-cta-btn", "color")

    for {{theme, accent}, palette} <- palettes,
        hero = hero_palette(css, theme, palette),
        stop <- [:a, :b, :c],
        lit <- [false, true],
        ground = hero_ground(hero, stop, lit, glow),
        {what, expr, back, needed} <-
          Enum.map(lines, &{&1, colours[&1], ground, 4.5}) ++
            [
              {".auth-hero-cta-btn", button_text, over(colour(hero, button_back), ground), 4.5},
              {".auth-hero-cta-btn:hover", button_text, over(colour(hero, button_hover), ground),
               4.5},
              {".auth-features li svg", "var(--hero-ink)", ground, 3.0}
            ],
        fore = colour(hero, expr),
        ratio = ratio(over(fore, back), back),
        ratio < needed,
        uniq: true do
      "#{theme} theme, #{accent} accent, #{what} on the #{stop} stop#{if lit, do: " with the glow"}: " <>
        "#{Float.round(ratio, 2)}:1, needs #{needed}:1"
    end
  end

  @doc "The corner glow's colour expression on the sign-in panel."
  def hero_glow(css) do
    [glow] =
      Regex.run(
        ~r/\.auth-hero::before\s*\{[^}]*?radial-gradient\(circle,\s*(color-mix\([^;]*?\)),\s*transparent/s,
        css,
        capture: :all_but_first
      )

    glow
  end

  @doc """
  Everything `mix pairings.theme_check` reports for a pack: the pairings,
  the rules (the app's and the pack's, in the pack's palettes) and the
  sign-in panel, in every accent. `[]` is a pass.
  """
  def pack_failures(core_css, pack_css, id, dark?) do
    css = strip_comments(core_css) <> "\n" <> strip_comments(pack_css)
    palettes = palettes(css, [id], @accents, if(dark?, do: [id], else: []))

    cond do
      not Map.has_key?(themes(css), id) ->
        ["no [data-theme=\"#{id}\"] { ... } block of tokens in theme.css"]

      true ->
        {_, rule_failures} = rule_failures(css, palettes)
        pairing_failures(palettes) ++ rule_failures ++ hero_failures(css, palettes)
    end
  end

  # The value of one declaration in the rule with exactly this selector.
  @doc false
  def rule_value(css, selector, property) do
    [body] =
      for [sel, body] <- rules(css),
          String.trim(sel) |> String.replace(~r/\s+/, " ") == selector,
          body =~ ~r/(?:^|[;{\s])#{property}:/,
          do: body

    [value] =
      Regex.run(~r/(?:^|[;{\s])#{property}:\s*([^;]+);/, body, capture: :all_but_first)

    String.trim(value)
  end

  @doc """
  The panel's own tokens as written: `:root`'s `--hero-*`, overridden by the
  theme's block.
  """
  def hero_raw(css, theme) do
    [root] = Regex.run(~r/(?:^|\n):root\s*\{([^}]*)\}/, css, capture: :all_but_first)

    for body <- [root | theme_bodies(css, theme)],
        [name, value] <- Regex.scan(~r/--(hero-[\w]+):\s*([^;]+);/, body, capture: :all_but_first),
        reduce: %{},
        do: (acc -> Map.put(acc, name, String.trim(value)))
  end

  @doc "The palette plus the panel's own tokens, resolved."
  def hero_palette(css, theme, palette) do
    raw = hero_raw(css, theme)
    Map.merge(palette, for({name, expr} <- raw, into: %{}, do: {name, colour(palette, expr)}))
  end

  defp hero_ground(hero, stop, lit, glow) do
    base = hero["hero-#{stop}"]
    if lit, do: over(colour(hero, glow), base), else: base
  end

  # ---------------------------------------------------------------------------
  # Palettes

  @doc """
  `%{{theme, accent} => palette}` for every theme and accent given.
  `dark_themes` are the ones `data-theme-dark` marks (theme packs with
  `"dark": true`), which pick up the dark accent set.
  """
  def palettes(css, themes, accents \\ @accents, dark_themes \\ []) do
    for theme <- themes,
        accent <- accents,
        into: %{},
        do: {{theme, accent}, palette(css, theme, accent, theme in dark_themes)}
  end

  @theme_block ~r/(?:^|\n)(?::root|html)?\[data-theme="([\w-]+)"\]\s*\{([^}]*)\}/

  @doc "Every theme's tokens, `\"light\"` being `:root`'s."
  def themes(css) do
    [root] = Regex.run(~r/(?:^|\n):root\s*\{([^}]*)\}/, css, capture: :all_but_first)
    root = tokens(root)

    named =
      for [name, _] <- Regex.scan(@theme_block, css, capture: :all_but_first),
          into: %{},
          do: {name, Enum.reduce(theme_bodies(css, name), root, &Map.merge(&2, tokens(&1)))}

    Map.put(named, "light", root)
  end

  defp theme_bodies(css, theme) do
    for [name, body] <- Regex.scan(@theme_block, css, capture: :all_but_first),
        name == theme,
        do: body
  end

  # The theme's tokens, then the accent's: `[data-accent]` blocks come after
  # the theme blocks with the same specificity, so they win; the ones scoped
  # with `:where([data-theme=...])` apply only on the themes they name, and
  # come after the unscoped set.
  @doc false
  def palette(css, theme, accent, dark? \\ false)

  def palette(css, theme, "green", _dark?), do: Map.fetch!(themes(css), theme)

  def palette(css, theme, accent, dark?) do
    unscoped =
      Regex.run(~r/(?:^|\n)\[data-accent="#{accent}"\]\s*\{([^}]*)\}/, css,
        capture: :all_but_first
      )

    scoped =
      for [where, body] <-
            Regex.scan(
              ~r/(?:^|\n)\[data-accent="#{accent}"\]:where\(([^)]*)\)\s*\{([^}]*)\}/,
              css,
              capture: :all_but_first
            ),
          where =~ ~s([data-theme="#{theme}"]) or (dark? and where =~ "[data-theme-dark]"),
          do: body

    Enum.reduce(
      List.wrap(unscoped) ++ scoped,
      Map.fetch!(themes(css), theme),
      &Map.merge(&2, tokens(&1))
    )
  end

  defp tokens(body) do
    for [name, value] <- Regex.scan(~r/--([\w-]+):\s*([^;]+);/, body, capture: :all_but_first),
        parsed = parse(String.trim(value)),
        parsed != nil,
        into: %{},
        do: {name, parsed}
  end

  defp ground(palette, {tint, base}) do
    case {palette[tint], ground(palette, base)} do
      {nil, _} -> nil
      {_, nil} -> nil
      {t, b} -> over(t, b)
    end
  end

  defp ground(palette, name), do: palette[name]

  defp describe({tint, base}), do: "--#{tint} over --#{base}"
  defp describe(name), do: "--#{name}"

  # ---------------------------------------------------------------------------
  # Colours: {r, g, b, alpha}, channels 0-255

  @doc """
  A colour value as written in a rule. `nil` for anything that is not a flat
  colour (a gradient, `inherit`, `currentColor`), which is not measured.
  """
  def colour(palette, expr) do
    expr = String.trim(expr)

    cond do
      match = Regex.run(~r/^var\(--([\w-]+)\)$/, expr, capture: :all_but_first) ->
        palette[hd(match)]

      match =
          Regex.run(~r/^color-mix\(in srgb,\s*(.+?)\s+([\d.]+)%,\s*(.+)\)$/, expr,
            capture: :all_but_first
          ) ->
        [a, percent, b] = match
        {a, b} = {colour(palette, a), colour(palette, b)}
        if a && b, do: mix(a, b, number(percent) / 100)

      true ->
        parse(expr)
    end
  end

  @doc "A literal colour (`#rgb`, `#rrggbb`, `rgba()`, a few names), or `nil`."
  def parse("#" <> <<hex::binary-size(6)>>) do
    if hex =~ ~r/\A[0-9a-fA-F]{6}\z/ do
      [r, g, b] = for <<channel::binary-size(2) <- hex>>, do: String.to_integer(channel, 16) * 1.0
      {r, g, b, 1.0}
    end
  end

  def parse("#" <> <<r::binary-size(1), g::binary-size(1), b::binary-size(1)>>),
    do: parse("#" <> r <> r <> g <> g <> b <> b)

  def parse("transparent"), do: {0.0, 0.0, 0.0, 0.0}
  def parse("white"), do: {255.0, 255.0, 255.0, 1.0}
  def parse("black"), do: {0.0, 0.0, 0.0, 1.0}

  def parse(value) do
    case Regex.run(~r/^rgba\((\d+),\s*(\d+),\s*(\d+),\s*([\d.]+)\)$/, value,
           capture: :all_but_first
         ) do
      [r, g, b, a] -> {number(r), number(g), number(b), number(a)}
      nil -> nil
    end
  end

  defp number(text) do
    {value, ""} = Float.parse(if String.starts_with?(text, "."), do: "0" <> text, else: text)
    value
  end

  # `color-mix(in srgb, a p%, b)`: interpolated with premultiplied alpha, as
  # CSS Color 5 specifies, so a mix with `transparent` is a translucent `a`.
  defp mix({r1, g1, b1, a1}, {r2, g2, b2, a2}, p) do
    alpha = a1 * p + a2 * (1 - p)
    channel = fn c1, c2 -> (c1 * a1 * p + c2 * a2 * (1 - p)) / alpha end
    {channel.(r1, r2), channel.(g1, g2), channel.(b1, b2), alpha}
  end

  @doc "`fg` laid over `bg`."
  def over(nil, _bg), do: nil
  def over(_fg, nil), do: nil

  def over({r, g, b, a}, {br, bg, bb, _}),
    do: {r * a + br * (1 - a), g * a + bg * (1 - a), b * a + bb * (1 - a), 1.0}

  @doc "A colour as `#rrggbb`."
  def hex({r, g, b, _}),
    do:
      "#" <>
        Enum.map_join(
          [r, g, b],
          &(&1
            |> round()
            |> Integer.to_string(16)
            |> String.pad_leading(2, "0")
            |> String.downcase())
        )

  @doc "The WCAG contrast ratio of two opaque colours."
  def ratio(a, b) do
    [lighter, darker] = Enum.sort([luminance(a), luminance(b)], :desc)
    (lighter + 0.05) / (darker + 0.05)
  end

  defp luminance({r, g, b, _}) do
    [r, g, b] =
      for c <- [r, g, b] do
        c = c / 255
        if c <= 0.04045, do: c / 12.92, else: :math.pow((c + 0.055) / 1.055, 2.4)
      end

    0.2126 * r + 0.7152 * g + 0.0722 * b
  end

  @doc "daisyUI's theme colours (oklch) to sRGB, clamped into gamut."
  def daisy_theme(css, name) do
    [body] =
      Regex.run(~r/daisyui-theme"\s*\{\s*name:\s*"#{name}";(.*?)\}/s, css,
        capture: :all_but_first
      )

    for [token, l, c, h] <-
          Regex.scan(~r/--color-([\w-]+):\s*oklch\(([\d.]+)%\s+([\d.]+)\s+([\d.]+)\)/, body,
            capture: :all_but_first
          ),
        into: %{},
        do: {token, oklch(number(l) / 100, number(c), number(h))}
  end

  defp oklch(l, c, h) do
    {a, b} = {c * :math.cos(h * :math.pi() / 180), c * :math.sin(h * :math.pi() / 180)}

    lms = [
      l + 0.3963377774 * a + 0.2158037573 * b,
      l - 0.1055613458 * a - 0.0638541728 * b,
      l - 0.0894841775 * a - 1.2914855480 * b
    ]

    [l3, m3, s3] = Enum.map(lms, &:math.pow(&1, 3))

    [r, g, b] =
      [
        4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3,
        -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3,
        -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3
      ]
      |> Enum.map(fn linear ->
        linear = min(max(linear, 0.0), 1.0)

        encoded =
          if linear <= 0.0031308,
            do: 12.92 * linear,
            else: 1.055 * :math.pow(linear, 1 / 2.4) - 0.055

        encoded * 255
      end)

    {r, g, b, 1.0}
  end
end
