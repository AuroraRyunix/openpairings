defmodule PairingsEngineWeb.LayoutOverflowTest do
  use ExUnit.Case, async: true

  @moduledoc """
  The rows that must wrap rather than overflow, checked as data.

  A flex or grid child defaults to `min-width: auto`, which means it refuses
  to shrink below its own content. A row of controls whose container also has
  the default `flex-wrap: nowrap` therefore has no legal way to fit: it cannot
  shrink and it cannot wrap, so it overflows - and because `body` sets
  `overflow-x: hidden`, the overflow is CLIPPED rather than scrolled. Nothing
  appears broken; a control simply is not there.

  That is invisible in English and routine in Dutch, which runs up to 2.4x
  longer on exactly the short strings that live in these rows ("Tools" ->
  "Hulpmiddelen", "Import SWAR file" -> "SWAR-bestand importeren"). Measured
  against the shipped catalogue: the tournaments page's action row wanted
  1237px of single-line buttons in Dutch against 983px in English, and below
  ~800px of available width it put "Nieuw toernooi" past the edge where it
  could not be clicked. The top bar did the same to "Afmelden" from a 1000px
  window - and to English's own "Settings" tab from 1150px with a tournament
  open, so this was never purely a translation problem.

  ## What this file deliberately does NOT test

  The tempting general rule is "every flex/grid rule whose children hold text
  must set `min-width: 0` on them, or be allowlisted". It was not written,
  because a stylesheet does not know which of its rules have text in them -
  answering that means matching CSS selectors against HEEx templates and
  guessing which `gettext(` calls land inside which element. On this codebase
  that is ~90 rules to adjudicate, most of them correctly unguarded (a column
  flex, a grid with `minmax(0, 1fr)`, a row whose only child is an icon), so
  the test would have been mostly allowlist, and an allowlist that long is a
  list of things nobody checked. A test people learn to append to is worse
  than no test.

  What is written instead is narrow and exact: the specific rows that were
  found overflowing, asserted to keep the property that fixes them. It cannot
  catch a NEW unguarded row - that is a real gap, stated here rather than
  papered over - but it cannot cry wolf either, and it fails on the line that
  would reintroduce the bug.
  """

  @css File.read!("assets/css/app.css")

  # Base rules only. Every rule in this stylesheet that is nested inside an
  # `@media` block is indented; the top-level ones start at column 0. Anchoring
  # to the line start is what keeps a responsive override from being mistaken
  # for the rule it overrides - and the fix under test is precisely that these
  # properties moved OUT of `@media (max-width: 768px)` and into the base.
  defp base_rule(selector) do
    matches =
      ~r/^#{Regex.escape(selector)}\s*\{([^}]*)\}/m
      |> Regex.scan(@css)
      |> Enum.map(fn [_, body] -> body end)

    case matches do
      [body] ->
        body

      [] ->
        flunk(
          "no top-level `#{selector} { … }` rule in assets/css/app.css - it was " <>
            "renamed or removed, and whatever replaced it is not being checked here"
        )

      many ->
        flunk(
          "#{length(many)} top-level `#{selector}` rules - this test reads the " <>
            "first and would miss a later override"
        )
    end
  end

  # Each row, with what it holds and what happened when it could not wrap.
  @wrapping_rows [
    {".actions",
     "the button row under every page heading (six buttons on the tournaments " <>
       "page); clipped \"Nieuw toernooi\" off the right edge below ~800px"},
    {".page-header",
     "heading block beside that button row; without wrapping the row is squeezed " <>
       "into the heading instead of dropping below it"},
    {".topbar",
     "brand + tab strip + auth cluster, rendered on every page; clipped the " <>
       "\"Afmelden\"/\"Log out\" link at a 1000px window"},
    {".pe-modal-foot",
     "Cancel + confirm inside .pe-modal-card, which sets `overflow: hidden` - " <>
       "so anything that does not fit is clipped with no scrollbar to reveal it"}
  ]

  test "the rows that hold translated controls are allowed to wrap" do
    for {selector, why} <- @wrapping_rows do
      body = base_rule(selector)

      assert body =~ ~r/display:\s*(flex|grid)/,
             "#{selector} is no longer a flex/grid row, so this check no longer " <>
               "describes it - re-read the rule and update this test"

      assert body =~ ~r/flex-wrap:\s*wrap/,
             "#{selector} lost `flex-wrap: wrap`. It is #{why}. Its children keep " <>
               "the flex default `min-width: auto` and will not shrink below their " <>
               "own labels, so without wrapping the row can only overflow - and " <>
               "`body { overflow-x: hidden }` clips that silently. English usually " <>
               "fits and hides the damage; Dutch does not."
    end
  end

  test "the top bar has no fixed height to clip against" do
    body = base_rule(".topbar")

    # `height: 56px` was the lid: it fixed the bar's size before its contents
    # were known, so a bar that needed two rows got one row and a crop. The
    # single-row bar is still exactly 56px tall - `min-height` sets a floor
    # rather than a ceiling.
    refute body =~ ~r/(?<!min-)height:\s*\d/,
           "the top bar has a fixed height again. A wrapped bar needs a second " <>
             "row to grow into; a fixed height gives it one row and clips the rest, " <>
             "which is how the log-out link went missing. Use `min-height`."

    assert body =~ ~r/min-height:\s*56px/,
           "the top bar lost its `min-height: 56px`, so a bar whose contents are " <>
             "shorter than 56px will now be shorter than 56px"
  end

  test "a wrapped top bar does not use the horizontal gap between its rows" do
    body = base_rule(".topbar")

    # `gap: 28px` is the right distance between brand and tabs and a silly one
    # between stacked rows - it made a two-row bar 28px taller than it needed
    # to be. The two-value form sets row-gap first.
    assert body =~ ~r/gap:\s*\d+px\s+\d+px/,
           "the top bar's `gap` is back to a single value, so its row gap is now " <>
             "the same as its (much larger) column gap and a wrapped bar has a " <>
             "hole in it. Use the `row column` form."
  end
end
