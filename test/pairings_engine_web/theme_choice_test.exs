defmodule PairingsEngineWeb.ThemeChoiceTest do
  use ExUnit.Case, async: true

  @moduledoc """
  The set of themes, checked in the three places it is written down.

  A theme choice is not state this app owns: it is a string in somebody
  else's browser, and it outlives the theme it names. Dracula and Tokyo
  Night were removed while people were using them, and a stored
  `"dracula"` stamped onto `<html>` matches no `[data-theme]` block at all -
  the page falls back to `:root`, which is the LIGHT palette, under every
  assumption a dark theme makes. That reads as a broken app rather than as
  a retired theme, so the bootstrap keeps a list of what it will accept and
  sends anything else to the default.

  A list is only a safety net while it is true, which is what these check:
  the bootstrap, the stylesheet and the picker have to name the same
  eleven themes, and nothing may refer to one that is gone.
  """

  @root File.read!("lib/pairings_engine_web/components/layouts/root.html.heex")
  @css File.read!("assets/css/app.css")
  @layouts File.read!("lib/pairings_engine_web/components/layouts.ex")

  # The `known` set in the inline bootstrap - the only strings allowed to
  # reach `data-theme`.
  defp accepted do
    [_, body] = Regex.run(~r/const known = new Set\(\[(.*?)\]\)/s, @root)

    ~r/"([a-z-]+)"/
    |> Regex.scan(body)
    |> MapSet.new(fn [_, name] -> name end)
  end

  # A palette block, which is a whole theme - not the `[data-theme=...]`
  # that appears mid-selector in an accent scope or a picker highlight.
  defp styled do
    ~r/^\[data-theme="([a-z-]+)"\] \{/m
    |> Regex.scan(@css)
    |> MapSet.new(fn [_, name] -> name end)
  end

  # `light` has no block of its own: it IS `:root`, which is why the script
  # may stamp it even though nothing matches it.
  defp styled_or_root, do: MapSet.put(styled(), "light")

  defp offered do
    [_, body] = Regex.run(~r/@themes \[(.*?)\n  \]/s, @layouts)

    ~r/\{"([a-z-]+)",/
    |> Regex.scan(body)
    |> MapSet.new(fn [_, name] -> name end)
  end

  test "the bootstrap accepts exactly the themes the stylesheet defines" do
    assert MapSet.size(accepted()) == 11,
           "expected eleven themes, the bootstrap accepts " <>
             "#{inspect(Enum.sort(accepted()))}"

    assert MapSet.equal?(accepted(), styled_or_root()),
           "the bootstrap's `known` set and app.css disagree. Accepted but not " <>
             "styled: #{inspect(Enum.sort(MapSet.difference(accepted(), styled_or_root())))} - " <>
             "those render as the bare :root palette. Styled but not accepted: " <>
             "#{inspect(Enum.sort(MapSet.difference(styled_or_root(), accepted())))} - " <>
             "those can never be applied, because the script refuses them."
  end

  test "the picker offers exactly the themes that exist" do
    assert MapSet.equal?(offered(), accepted()),
           "the theme picker and the bootstrap disagree. Offered but not accepted: " <>
             "#{inspect(Enum.sort(MapSet.difference(offered(), accepted())))} - clicking " <>
             "those does nothing but clear the stored choice. Accepted but not offered: " <>
             "#{inspect(Enum.sort(MapSet.difference(accepted(), offered())))} - a theme " <>
             "nobody can reach."
  end

  # The selectors that mark the open picker's current choice.
  defp highlighted do
    ~r/html\[data-theme-source="user"\]\[data-theme="([a-z-]+)"\] \.theme-picker-item/
    |> Regex.scan(@css)
    |> MapSet.new(fn [_, name] -> name end)
  end

  # The theme names the dark-mode accent brightening is scoped to.
  defp scoped do
    ~r/\[data-accent="[a-z]+"\]:where\(([^)]*)\)/
    |> Regex.scan(@css)
    |> Enum.flat_map(fn [_, scope] ->
      Regex.scan(~r/\[data-theme="([a-z-]+)"\]/, scope)
    end)
    |> MapSet.new(fn [_, name] -> name end)
  end

  test "every offered theme has a rule marking it as the current one" do
    assert MapSet.equal?(highlighted(), offered()),
           "the picker's current-choice highlight covers #{inspect(Enum.sort(highlighted()))} " <>
             "but the picker offers #{inspect(Enum.sort(offered()))}. A theme missing from " <>
             "that selector list is selectable but never shown as selected."
  end

  test "the accent overrides are scoped to themes that still exist" do
    # The dark-mode brightening is keyed to a list of theme names. A name
    # left in it after the theme goes is dead weight; a dark theme left OUT
    # of it silently takes the LIGHT accents, which is the same bug in the
    # other direction and invisible until somebody looks at the button.
    unknown = MapSet.difference(scoped(), accepted())

    assert MapSet.equal?(unknown, MapSet.new()),
           "the accent overrides are scoped to #{inspect(Enum.sort(unknown))}, which " <>
             "no longer exist - the scope was not updated when the theme was removed"

    # Every theme in the scope is a dark one, and every dark theme is in the
    # scope. `color-scheme` is the stylesheet's own answer to which is which.
    dark =
      ~r/^\[data-theme="([a-z-]+)"\] \{[^}]*color-scheme: dark/m
      |> Regex.scan(@css)
      |> MapSet.new(fn [_, name] -> name end)

    assert MapSet.equal?(scoped(), dark),
           "the dark themes are #{inspect(Enum.sort(dark))} but the accent overrides " <>
             "are scoped to #{inspect(Enum.sort(scoped()))}. A dark theme outside that " <>
             "scope gets the light accents - dark ink on a dark surface."
  end

  test "an unknown stored theme falls back instead of being applied" do
    # The guard itself, read as source: a stored choice that is not on the
    # list must both be forgotten and replaced by the default, and it has to
    # happen before `applyTheme` sees it.
    [_, guard] =
      Regex.run(~r/const setTheme = \(theme\) => \{(.*?)\n          if \(theme ===/s, @root)

    assert guard =~ "!known.has(theme)",
           "setTheme no longer checks the stored value against the known themes, so " <>
             "a retired theme is stamped onto <html> unchanged"

    assert guard =~ ~s|store.remove("phx:theme")|,
           "the stale choice is not cleared, so the fallback is re-decided on every " <>
             "page load and the browser keeps a theme that does not exist"

    assert guard =~ "theme = defaultTheme()",
           "the unknown theme is not replaced by the default, so whatever it was still " <>
             "reaches applyTheme"
  end

  test "a retired theme survives only as prose" do
    # Named rather than derived, because the point of the check is the two
    # names that were removed. Comments may still explain them - that is
    # what the comments are for - but nothing that DECIDES anything may
    # still name them.
    for retired <- ~w(dracula tokyo),
        {place, names} <- [
          {"the bootstrap's known set", accepted()},
          {"the stylesheet's palette blocks", styled()},
          {"the theme picker", offered()},
          {"the picker's current-choice highlight", highlighted()},
          {"the dark-mode accent scope", scoped()}
        ] do
      refute retired in names,
             "#{retired} is gone from the palette but #{place} still names it"
    end
  end
end
