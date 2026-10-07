defmodule PairingsEngine.ManualTest do
  use ExUnit.Case, async: true

  alias PairingsEngine.Manual

  test "every chapter file under priv/manual is a chapter, in file order" do
    files =
      "priv/manual/*.md"
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.map(&(Path.basename(&1, ".md") |> String.replace(~r/^\d+-/, "")))

    assert files != []
    assert Manual.slugs() == files
  end

  test "each chapter has a title, a body and a table of contents" do
    for chapter <- Manual.chapters() do
      assert chapter.title != "", chapter.slug
      assert chapter.html =~ "<p>", chapter.slug
      assert Manual.toc(chapter) != [], "#{chapter.slug} has no ## headings"
    end
  end

  test "the chapter title is not repeated as a heading in the body" do
    for chapter <- Manual.chapters() do
      refute chapter.html =~ "<h1", chapter.slug
    end
  end

  test "headings carry ids that the chapter's contents point at" do
    for chapter <- Manual.chapters(), %{id: id} <- Manual.toc(chapter) do
      assert chapter.html =~ ~s(id="#{id}"), "#{chapter.slug}: #{id}"
    end
  end

  test "links between chapters point at /help/<slug>, and every target exists" do
    slugs = Manual.slugs()

    for chapter <- Manual.chapters() do
      refute chapter.html =~ ~r/href="[^"]*\.md/, "#{chapter.slug} links to a .md file"

      for [_, target] <- Regex.scan(~r{href="/help/([a-z0-9-]+)(?:#[^"]*)?"}, chapter.html) do
        assert target in slugs, "#{chapter.slug} links to a missing chapter #{target}"
      end
    end
  end

  test "neighbours walk the reading order" do
    [first, second | _] = Manual.chapters()

    assert {nil, ^second} = Manual.neighbours(first.slug)
    assert {^first, _} = Manual.neighbours(second.slug)
    assert {nil, nil} = Manual.neighbours("no-such-chapter")
    assert Manual.get("no-such-chapter") == nil
  end

  test "the manual covers the features the rest of the program names" do
    text = Manual.chapters() |> Enum.map_join("\n", & &1.html)

    for needle <- ["FIDE mode", "tie-break", "Berger", "Keizer", "TRF", "OpenResults", "hand-off"] do
      assert String.downcase(text) =~ String.downcase(needle), needle
    end
  end
end
