defmodule PairingsEngine.Manual.MarkupTest do
  use ExUnit.Case, async: true

  alias PairingsEngine.Manual.Markup

  defp render(markdown, opts \\ []), do: Markup.chapter("# Title\n\n" <> markdown, 6, opts)

  test "the first # heading is the title and is not in the body" do
    chapter = render("Some text.")

    assert chapter.title == "Title"
    refute chapter.html =~ "<h1"
  end

  describe "callouts" do
    test "a marker turns a blockquote into a callout, with its default title" do
      html = render("> [!WARNING]\n> Unpairing deletes results.").html

      assert html =~ ~s(class="manual-callout manual-callout-warning")
      assert html =~ ~s(role="note")
      assert html =~ "Warning</p>"
      assert html =~ "<p>Unpairing deletes results.</p>"
      refute html =~ "[!WARNING]"
      refute html =~ "<blockquote"
    end

    test "text after the marker is the title; FIDE has its own kind" do
      html = render("> [!FIDE] C.04.3 Article 5\n> The **bye** rule.").html

      assert html =~ "manual-callout-fide"
      assert html =~ "hero-scale"
      assert html =~ "C.04.3 Article 5</p>"
      assert html =~ "<p>The <strong>bye</strong> rule.</p>"
    end

    test "an ordinary blockquote stays one" do
      html = render("> Just a quote.").html

      assert html =~ "<blockquote>"
      refute html =~ "manual-callout"
    end
  end

  test "numbered lists are steps, and keep their start number" do
    assert render("1. one\n2. two").html =~ ~s(<ol class="manual-steps">)
    assert render("3. three\n4. four").html =~ "counter-reset: step 2"
  end

  test "<kbd> becomes a key; other HTML stays text, and so does <kbd> in code" do
    html = render("Press <kbd>Ctrl</kbd>+<kbd>K</kbd>. <script>x</script> `<kbd>A</kbd>`").html

    assert html =~ "<kbd>Ctrl</kbd>+<kbd>K</kbd>"
    assert html =~ "&lt;script&gt;x&lt;/script&gt;"
    assert html =~ "&lt;kbd&gt;A&lt;/kbd&gt;"
    refute html =~ "<script"
  end

  test "headings get ids, a copy-link anchor and an outline entry" do
    chapter = render("## The Pairings page\n\n### Hand edits\n\n## The Pairings page")

    assert chapter.html =~ ~s(<h2 id="the-pairings-page">)
    assert chapter.html =~ ~s(href="#the-pairings-page")
    assert chapter.html =~ ~s(id="the-pairings-page-2")

    assert [
             %{id: "the-pairings-page", level: 2},
             %{id: "hand-edits", level: 3},
             %{id: "the-pairings-page-2"}
           ] = chapter.toc
  end

  test "links to chapter files become manual links, with their anchor" do
    html = render("[Swiss](06-pairing.md#swiss) and [Printing](09-printing.md)").html

    assert html =~ ~s(href="/help/pairing#swiss")
    assert html =~ ~s(href="/help/printing")
  end

  describe "screenshots" do
    @tag :tmp_dir
    test "a missing file renders a placeholder naming the file and what to show", %{tmp_dir: dir} do
      chapter =
        render(~s|![The round table](screenshots/06-round.png "Round 3")|, screenshot_dir: dir)

      assert chapter.html =~ "manual-figure is-missing"
      assert chapter.html =~ "manual-figure-placeholder"
      assert chapter.html =~ "06-round.png"
      assert chapter.html =~ "The round table"
      assert chapter.html =~ "Figure 6.1</span> Round 3"
      refute chapter.html =~ "<img"

      assert [%{file: "06-round.png", present?: false, caption: "Round 3"}] = chapter.figures
    end

    @tag :tmp_dir
    test "a file that exists renders a lazy, enlargeable image", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "06-round.png"), "png")

      html = render("![The round table](screenshots/06-round.png)", screenshot_dir: dir).html

      assert html =~ ~s(src="/images/manual/06-round.png")
      assert html =~ ~s(alt="The round table")
      assert html =~ ~s(loading="lazy")
      assert html =~ ~s(data-enlarge="true")
      # No title: the alt text is the caption.
      assert html =~ "Figure 6.1</span> The round table"
      refute html =~ "is-missing"
    end

    test "only a plain file name in screenshots/ is looked up" do
      chapter = render("![x](screenshots/../secret.png)", screenshot_dir: "priv")
      assert [%{file: nil}] = chapter.figures
    end
  end

  test "search sections are cut at the headings, without the anchors' #" do
    chapter = render("Intro.\n\n## First\n\nAlpha text.\n\n## Second\n\nBeta text.")

    assert [
             %{id: nil, text: "Intro."},
             %{id: "first", heading: "First", text: "Alpha text."},
             %{id: "second", heading: "Second", text: "Beta text."}
           ] = chapter.sections
  end
end
