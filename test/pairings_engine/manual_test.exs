defmodule PairingsEngine.ManualTest do
  use ExUnit.Case, async: true

  alias PairingsEngine.Manual

  test "every chapter file under priv/manual is a chapter, in file order" do
    files =
      "priv/manual/*.md"
      |> Path.wildcard()
      |> Enum.filter(&Regex.match?(~r/\A\d+-/, Path.basename(&1)))
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

  test "SCREENSHOTS.md is not a chapter" do
    refute "SCREENSHOTS" in Manual.slugs()
    refute "screenshots" in Manual.slugs()
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

  describe "links resolve" do
    # Every `href` inside the manual that stays inside it: another chapter,
    # a heading of another chapter, or a heading of the same chapter. A
    # renamed heading or chapter fails here, naming the link.
    test "every internal link and anchor points at a chapter and an id that exist" do
      by_slug = Map.new(Manual.chapters(), &{&1.slug, &1})

      for chapter <- Manual.chapters(),
          [_, href] <- Regex.scan(~r/href="([^"]*)"/, chapter.html),
          not String.starts_with?(href, ["http://", "https://", "mailto:"]) do
        {slug, anchor} =
          case Regex.run(~r{\A/help/([a-z0-9-]+)(?:#(.*))?\z}, href) do
            [_, slug] ->
              {slug, nil}

            [_, slug, anchor] ->
              {slug, anchor}

            nil ->
              case href do
                "#" <> anchor ->
                  {chapter.slug, anchor}

                other ->
                  flunk("#{chapter.slug}: link #{other} is neither a chapter nor an anchor")
              end
          end

        target = Map.get(by_slug, slug)
        assert target, "#{chapter.slug}: link #{href} names a missing chapter"

        if anchor do
          assert target.html =~ ~s(id="#{anchor}"),
                 "#{chapter.slug}: link #{href} names a missing heading in #{slug}"
        end
      end
    end

    test "the ? links on the app pages point at existing sections" do
      for {topic, {slug, anchor}} <- PairingsEngineWeb.Components.ManualLink.targets() do
        chapter = Manual.get(slug)
        assert chapter, "#{topic}: no chapter #{slug}"

        assert Enum.any?(chapter.toc, &(&1.id == anchor)),
               "#{topic}: no heading #{anchor} in #{slug}"
      end
    end
  end

  describe "screenshots" do
    test "SCREENSHOTS.md lists exactly the slots the chapters use" do
      listed =
        ~r/^\| `([^`]+\.png)`/m
        |> Regex.scan(File.read!("priv/manual/SCREENSHOTS.md"))
        |> Enum.map(fn [_, file] -> file end)

      used = for {_chapter, figure} <- Manual.figures(), do: figure.file

      assert Enum.sort(listed) == Enum.sort(used)
      assert used == Enum.uniq(used), "a screenshot file is used twice"
    end

    test "each figure has alt text and a caption" do
      for {chapter, figure} <- Manual.figures() do
        assert figure.alt != "", "#{chapter.slug}: #{figure.file} has no alt text"
        assert figure.caption != "", "#{chapter.slug}: #{figure.file} has no caption"
      end
    end
  end

  describe "search" do
    test "finds a section by its words, best match first, with the matches marked" do
      assert [first | _] = results = Manual.search("half-point bye")

      assert first.chapter.slug == "byes-and-absences"
      assert Enum.any?(first.snippet_parts ++ first.heading_parts, &match?({_, true}, &1))

      assert Enum.any?(results, fn r ->
               r.section_id && Enum.any?(r.chapter.toc, &(&1.id == r.section_id))
             end)
    end

    test "every word must match; nothing for nonsense or an empty query" do
      assert Manual.search("") == []
      assert Manual.search("x") == []
      assert Manual.search("pairing zzzqqqxx") == []
    end

    test "is case-insensitive" do
      assert Manual.search("BERGER") != []
      assert length(Manual.search("berger")) == length(Manual.search("Berger"))
    end
  end

  describe "translations" do
    test "a translated chapter has exactly the English chapter's section ids, so every link lands" do
      english = Map.new(Manual.chapters(), &{&1.slug, Enum.map(Manual.toc(&1), fn h -> h.id end)})

      for locale <- Manual.locales(), chapter <- Manual.chapters(locale) do
        assert Enum.map(Manual.toc(chapter), & &1.id) == english[chapter.slug],
               "#{locale}/#{chapter.slug}: section ids differ from the English chapter"

        refute Enum.any?(Manual.toc(chapter), &String.contains?(&1.text, "{#")),
               "#{locale}/#{chapter.slug}: an explicit id leaked into a heading"
      end
    end

    test "every locale has every chapter, in the English order" do
      for locale <- Manual.locales() do
        assert Enum.map(Manual.chapters(locale), & &1.slug) == Manual.slugs()
      end
    end

    test "an explicit id wins over the heading text" do
      html =
        PairingsEngine.Manual.Markup.chapter(
          "# T

## Een kop {#a-heading}

Tekst.
",
          1
        )

      assert [%{id: "a-heading", text: "Een kop"}] = html.toc
    end
  end
end
