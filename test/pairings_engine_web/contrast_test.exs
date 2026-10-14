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

  The arithmetic lives in `PairingsEngineWeb.ThemeContrast`, which
  `mix pairings.theme_check` runs over a theme pack the same way.

  Added with the accessibility pass of 2026-09-13. The tokens it moved, with
  their ratios before and after, are in `docs/accessibility-2026-09-13.md`.
  """
  use ExUnit.Case, async: true

  @css Path.expand("../../assets/css/app.css", __DIR__)
  @layouts Path.expand("../../lib/pairings_engine_web/components/layouts.ex", __DIR__)

  import PairingsEngineWeb.ThemeContrast,
    only: [
      rules: 1,
      palettes: 2,
      palette: 3,
      themes: 1,
      pairing_failures: 1,
      rule_failures: 2,
      hero_failures: 2,
      hero_glow: 1,
      hero_raw: 2,
      hero_palette: 3,
      rule_value: 3,
      hex: 1,
      parse: 1,
      ratio: 2,
      over: 2,
      daisy_theme: 2
    ]

  @themes ~w(light dark slate paper board tomw contrast)
  @accents ~w(green blue teal violet rose slate indigo cyan fuchsia)

  setup_all do
    css = PairingsEngineWeb.ThemeContrast.strip_comments(File.read!(@css))
    {:ok, css: css, palettes: palettes(css, @themes)}
  end

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
    failures = pairing_failures(palettes)
    assert failures == [], Enum.join(failures, "
")
  end

  test "every rule that sets a text colour and a background reaches 4.5:1, in every theme and accent",
       %{css: css, palettes: palettes} do
    {measured, failures} = rule_failures(css, palettes)

    # The walk found the rules, rather than finding nothing and passing.
    assert measured > 60

    assert failures == [], Enum.join(failures, "
")
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

  test "the sign-in panel: every line of text on its gradient, in every theme and accent", %{
    css: css,
    palettes: palettes
  } do
    # The panel is derived from the accent (--hero-* tokens, defined with the
    # themes), so it is measured per palette: text against all three gradient
    # stops, bare and with the corner glow (the strongest overlay) laid on it.
    assert hero_glow(css) =~ "var(--hero-pole)"

    for theme <- @themes do
      assert hero_raw(css, theme) |> Map.keys() |> Enum.sort() ==
               ~w(hero-a hero-b hero-c hero-ink hero-pole)
    end

    failures = hero_failures(css, palettes)
    assert failures == [], Enum.join(failures, "
")

    # The point of the exercise: on a light theme the panel starts as the very
    # colour of the primary button, so the two never disagree.
    for {{theme, accent}, palette} <- palettes, theme not in ["dark", "slate"] do
      assert hero_palette(css, theme, palette)["hero-a"] == palette["accent"],
             "#{theme} theme, #{accent} accent: the panel is not the accent"
    end
  end

  test "the sign-in panel is made of tokens, not of a fixed colour", %{css: css} do
    # It was a fixed green gradient beside a primary button that follows the
    # accent. Any colour literal back in the panel's fill, or the intro capped
    # narrower than the list under it, is what this is here to refuse.
    fill = rule_value(css, ".auth-hero", "background")
    refute fill =~ ~r/#[0-9a-f]{3,6}|rgba?\(/i, ".auth-hero's fill has a colour literal: #{fill}"
    assert fill =~ "var(--hero-a)"
    assert rule_value(css, ".auth-hero", "color") == "var(--hero-ink)"
    assert rule_value(css, ".auth-hero-sub", "max-width") == "none"
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
end
