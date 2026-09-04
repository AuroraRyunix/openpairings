defmodule PairingsEngine.ChangelogStyleTest do
  @moduledoc """
  The changelog emboldens what changed, not the word "Fix".

  Entries read `- [Tag] **What changed.** Then the detail`, so a reader
  scanning for whether an upgrade affects them gets their answer from the bold
  text. The tag is already a column down the left-hand side; emboldening it
  spends the emphasis on the one thing they can see without reading.

  This exists because the style drifted for eleven releases in a single day
  and nothing noticed.

  Two things are deliberately NOT asserted, because the file has never
  followed them and a test should describe what is true:

    * that every entry has a bold lead - plenty of smaller ones do not, and
      they read fine as a plain sentence;
    * that the lead is a complete sentence - about a third lead with a
      fragment that flows into the rest ("**A quieter middle button**
      (`tonal`) for the second action on a busy page"), which is good writing.
  """
  use ExUnit.Case, async: true

  @changelog File.read!("CHANGELOG.md")

  # An entry runs from its `- [Tag]` to the next entry or heading, so a lead
  # wrapped over two lines is still one entry.
  defp entries do
    @changelog
    |> String.split(~r/\n(?=- \[|## |### )/)
    |> Enum.filter(&String.starts_with?(&1, "- ["))
    |> Enum.map(&(&1 |> String.split() |> Enum.join(" ")))
  end

  defp bold_leads do
    @changelog
    |> String.split(~r/\n(?=- |## |### )/)
    |> Enum.filter(&String.starts_with?(&1, "- "))
    |> Enum.map(&(&1 |> String.split() |> Enum.join(" ")))
    |> Enum.map(&Regex.run(~r/^- \[\w+\] \*\*(.+?)\*\*/, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn [_, lead] -> lead end)
  end

  test "there are entries to check at all" do
    assert length(entries()) > 200, "the changelog should not be nearly empty"
    assert length(bold_leads()) > 100, "most notable entries carry a bold lead"
  end

  test "the tag is never what is emboldened" do
    # `- **[Fix]** ...` is the regression this file exists to catch.
    offenders =
      @changelog
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "- **["))

    assert offenders == [],
           "#{length(offenders)} entries embolden the tag instead of what changed:\n" <>
             Enum.map_join(Enum.take(offenders, 5), "\n", &String.slice(&1, 0, 90))
  end

  test "a bold lead has not swallowed the whole entry" do
    # Bound measured from the file, not invented: 387 leads, median 60
    # characters, longest 169.
    too_long = Enum.filter(bold_leads(), &(String.length(&1) > 220))

    assert too_long == [],
           "these leads have swallowed the entry:\n" <>
             Enum.map_join(too_long, "\n", &String.slice(&1, 0, 90))
  end

  test "every entry starts with a recognised tag" do
    known = ~w(Feature Fix Change Removed Security Verified)

    offenders =
      Enum.reject(entries(), fn entry ->
        Enum.any?(known, &String.starts_with?(entry, "- [#{&1}]"))
      end)

    assert offenders == [],
           "unrecognised tags (the table at the top of the file lists them):\n" <>
             Enum.map_join(Enum.take(offenders, 5), "\n", &String.slice(&1, 0, 90))
  end
end
