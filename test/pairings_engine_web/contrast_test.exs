defmodule PairingsEngineWeb.ContrastTest do
  @moduledoc """
  Colour contrast in the arbiter's app, computed from `assets/css/app.css`
  with the WCAG 2.2 formula - not judged by eye.

  Every colour is a token. Seven themes (`:root` is Light, then one
  `[data-theme]` block each) and nine accents, each of which replaces the
  accent tokens on top of whichever theme is on: 63 palettes, and two checks
  run over every one of them -

    * the pairings the design system is built from: text on each ground, the
      accent on its own tint, the ink on each filled colour and its hover, the
      focus ring and the edge of a field; and
    * every rule in the stylesheet that sets a text colour and a background
      together, with `color-mix()` and translucent fills laid over the ground
      they sit on - so a badge or a pill added later is measured the day it
      lands, in every theme, without anybody listing it here.

  Added with the accessibility pass of 2026-09-13. The tokens it moved, with
  their ratios before and after, are in `docs/accessibility-2026-09-13.md`.
  """
  use ExUnit.Case, async: true

  @css Path.expand("../../assets/css/app.css", __DIR__)
  @layouts Path.expand("../../lib/pairings_engine_web/components/layouts.ex", __DIR__)

  @themes ~w(light dark slate mocha paper board contrast)
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

  # On the sign-in hero's fixed green gradient, the same in every theme -
  # measured by "the sign-in hero" below instead.
  @on_the_hero [".auth-hero-cta-btn"]

  setup_all do
    css = stylesheet()
    {:ok, css: css, palettes: palettes(css)}
  end

  defp stylesheet, do: Regex.replace(~r{/\*.*?\*/}s, File.read!(@css), "")

  defp rules(css), do: Regex.scan(~r/([^{}]+)\{([^{}]*)\}/, css, capture: :all_but_first)

  test "every theme and every accent the pickers offer is defined", %{css: css} do
    assert Enum.sort(Map.keys(themes(css))) == Enum.sort(@themes)

    for accent <- @accents -- ["green"] do
      assert css =~ ~s([data-accent="#{accent}"] {),
             "no light-theme block for the #{accent} accent"
    end

    # The picker's swatches are the colour the accent really is. Two of them
    # were darkened in this pass; a swatch still showing the old value would
    # preview a colour the buttons no longer have.
    swatches =
      for [key, hex] <-
            Regex.scan(~r/\{"(\w+)", "(#[0-9a-f]{6})"\}/, File.read!(@layouts),
              capture: :all_but_first
            ),
          into: %{},
          do: {key, hex}

    assert Enum.sort(Map.keys(swatches)) == Enum.sort(@accents)

    for accent <- @accents do
      assert hex(palette(css, "light", accent)["accent"]) == swatches[accent],
             "the #{accent} swatch is #{swatches[accent]}, the accent it applies is #{hex(palette(css, "light", accent)["accent"])}"
    end
  end

  test "every token pairing reaches its WCAG AA ratio, in every theme and accent", %{
    palettes: palettes
  } do
    failures =
      for {{theme, accent}, palette} <- palettes,
          {what, fg, ground, needed} <- @pairings,
          back = ground(palette, ground),
          ratio = ratio(over(palette[fg], back), back),
          ratio < needed do
        "#{theme} theme, #{accent} accent: #{what} (--#{fg} on #{describe(ground)}) is " <>
          "#{Float.round(ratio, 2)}:1, needs #{needed}:1"
      end

    assert failures == [], Enum.join(failures, "\n")
  end

  test "every rule that sets a text colour and a background reaches 4.5:1, in every theme and accent",
       %{css: css, palettes: palettes} do
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

    # The walk found the rules, rather than finding nothing and passing.
    assert length(measured) > 60

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

    assert failures == [], Enum.join(failures, "\n")
  end

  test "daisyUI's filled colours carry readable text, in both of its themes", %{css: css} do
    # core_components' flash (alert-info, alert-error) and primary button.
    for name <- ~w(light dark),
        {fg, bg} <- [
          {"primary-content", "primary"},
          {"info-content", "info"},
          {"error-content", "error"}
        ] do
      daisy = daisy_theme(css, name)
      ratio = ratio(daisy[fg], daisy[bg])

      assert ratio >= 4.5,
             "daisyUI #{name}: --color-#{fg} on --color-#{bg} is #{Float.round(ratio, 2)}:1"
    end
  end

  test "the sign-in hero: every line of text on the green gradient", %{css: css} do
    [stops] =
      Regex.run(~r/\.auth-hero\s*\{[^}]*radial-gradient\([^,]+,\s*([^;]+)\);/, css,
        capture: :all_but_first
      )

    stops =
      for [hex, at] <- Regex.scan(~r/(#[0-9a-f]{6})\s+([\d.]+)%/, stops, capture: :all_but_first),
          do: {parse(hex), String.to_integer(at) / 100}

    # Where each line sits along the gradient, which runs from the top-left
    # corner over an ellipse 150% of the panel's height: 0 at the corner, 0.46
    # at the middle stop. Measured on the 680px panel, text 44px in: the name
    # and title near the top, the subtitle from ~200px down, the feature list
    # from ~300px, the "coming soon" line and the call to action below it.
    lines = [
      {".auth-hero", 0.1, 3.0},
      {".auth-hero-sub", 0.2, 4.5},
      {".auth-features li", 0.3, 4.5},
      {".auth-feature-soon", 0.5, 4.5},
      {".auth-hero-cta", 0.6, 4.5}
    ]

    for {selector, at, needed} <- lines do
      [color] =
        Regex.run(
          ~r/(?:^|\n)#{Regex.escape(selector)}\s*\{[^}]*?(?:^|[;{\s])color:\s*([^;]+);/,
          css, capture: :all_but_first)

      back = gradient(stops, at)
      ratio = ratio(over(colour(%{}, color), back), back)

      assert ratio >= needed,
             "#{selector} is #{Float.round(ratio, 2)}:1 on the hero, needs #{needed}:1"
    end

    [button_back, button_text] =
      Regex.run(
        ~r/\.auth-hero-cta-btn\s*\{[^}]*background:\s*([^;]+);[^}]*color:\s*([^;]+);/,
        css, capture: :all_but_first)

    back = over(colour(%{}, button_back), gradient(stops, 0.65))
    assert ratio(colour(%{}, button_text), back) >= 4.5
  end

  test "no field is edged in the hairline colour", %{css: css} do
    # `--border` is 1.2-1.8:1 against the card in every theme but High
    # Contrast: a line between two rows, not an edge to find a text box by.
    offenders =
      for [selector, body] <- rules(css),
          selector =~ ~r/\b(input|select|textarea)\b/,
          body =~ ~r/border(-color)?:[^;]*var\(--border\)/,
          do: String.trim(selector)

    assert offenders == []
  end

  test "keyboard focus is drawn in the accent, and taken away only where something else draws it",
       %{css: css} do
    assert css =~ ~r/(^|\n):focus-visible\s*\{\s*outline:\s*2px solid var\(--accent\)/

    # Where focus is MOVED to by the skip link or a dialog, which nobody
    # operates; a ring round the whole page says nothing the move has not.
    moved_to = ["#main-content:focus", "[data-dialog]:focus"]

    removed =
      for [selector, body] <- rules(css),
          body =~ ~r/outline:\s*(none|0)\s*;/,
          one <- String.split(selector, ","),
          do: {String.trim(one), body}

    assert Enum.all?(moved_to, fn target -> Enum.any?(removed, &(elem(&1, 0) == target)) end)

    for {selector, body} <- removed, selector not in moved_to do
      drawn_here = body =~ ~r/(border-color|box-shadow):[^;]*var\(--accent\)/

      drawn_on_focus_visible =
        css =~
          ~r/#{Regex.escape(selector)}:focus-visible\s*\{[^}]*outline:\s*2px solid var\(--accent\)/

      assert drawn_here or drawn_on_focus_visible,
             "#{selector} takes the focus ring away and draws nothing in its place"
    end
  end

  test "the formula, against the published reference values" do
    assert_in_delta ratio(parse("#000000"), parse("#ffffff")), 21.0, 0.001
    assert_in_delta ratio(parse("#ffffff"), parse("#ffffff")), 1.0, 0.001
    # The WCAG understanding document's own example: #767676 on white.
    assert_in_delta ratio(parse("#767676"), parse("#ffffff")), 4.54, 0.01
    # A tint is laid over its ground before it is measured.
    assert over(parse("rgba(0, 0, 0, 0.5)"), parse("#ffffff")) == {127.5, 127.5, 127.5, 1.0}
  end

  # ---------------------------------------------------------------------------
  # Palettes

  defp palettes(css),
    do:
      for(
        theme <- @themes,
        accent <- @accents,
        into: %{},
        do: {{theme, accent}, palette(css, theme, accent)}
      )

  defp themes(css) do
    [root] = Regex.run(~r/(?:^|\n):root\s*\{([^}]*)\}/, css, capture: :all_but_first)
    root = tokens(root)

    named =
      for [name, body] <-
            Regex.scan(~r/(?:^|\n)\[data-theme="(\w+)"\]\s*\{([^}]*)\}/, css,
              capture: :all_but_first
            ),
          into: %{},
          do: {name, Map.merge(root, tokens(body))}

    Map.put(named, "light", root)
  end

  # The theme's tokens, then the accent's: `[data-accent]` blocks come after
  # the theme blocks with the same specificity, so they win; the ones scoped
  # with `:where([data-theme=...])` apply only on the themes they name, and
  # come after the unscoped set.
  defp palette(css, theme, "green"), do: Map.fetch!(themes(css), theme)

  defp palette(css, theme, accent) do
    unscoped =
      Regex.run(~r/(?:^|\n)\[data-accent="#{accent}"\]\s*\{([^}]*)\}/, css,
        capture: :all_but_first
      )

    scoped =
      for [where, body] <-
            Regex.scan(
              ~r/(?:^|\n)\[data-accent="#{accent}"\]:where\(([^)]*)\)\s*\{([^}]*)\}/,
              css, capture: :all_but_first),
          where =~ ~s([data-theme="#{theme}"]),
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

  defp ground(palette, {tint, base}), do: over(palette[tint], ground(palette, base))
  defp ground(palette, name), do: palette[name]

  defp describe({tint, base}), do: "--#{tint} over --#{base}"
  defp describe(name), do: "--#{name}"

  # ---------------------------------------------------------------------------
  # Colours: {r, g, b, alpha}, channels 0-255

  # A colour value as written in a rule. `nil` for anything that is not a
  # flat colour (a gradient, `inherit`, `currentColor`), which is not measured.
  defp colour(palette, expr) do
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

  defp parse("#" <> <<hex::binary-size(6)>>) do
    [r, g, b] = for <<channel::binary-size(2) <- hex>>, do: String.to_integer(channel, 16) * 1.0
    {r, g, b, 1.0}
  end

  defp parse("#" <> <<r::binary-size(1), g::binary-size(1), b::binary-size(1)>>),
    do: parse("#" <> r <> r <> g <> g <> b <> b)

  defp parse("transparent"), do: {0.0, 0.0, 0.0, 0.0}
  defp parse("white"), do: {255.0, 255.0, 255.0, 1.0}
  defp parse("black"), do: {0.0, 0.0, 0.0, 1.0}

  defp parse(value) do
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

  defp over({r, g, b, a}, {br, bg, bb, _}),
    do: {r * a + br * (1 - a), g * a + bg * (1 - a), b * a + bb * (1 - a), 1.0}

  defp gradient(stops, at) do
    {{from, a}, {to, b}} =
      stops |> Enum.zip(tl(stops)) |> Enum.find(fn {{_, a}, {_, b}} -> at >= a and at <= b end)

    mix(to, from, (at - a) / (b - a))
  end

  defp hex({r, g, b, _}),
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

  defp ratio(a, b) do
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

  # daisyUI's theme colours are oklch(); to linear sRGB, clamped into gamut.
  defp daisy_theme(css, name) do
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
