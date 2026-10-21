defmodule PairingsEngine.Manual.FamilyTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Help.SyncFamily
  alias PairingsEngine.Manual
  alias PairingsEngine.Manual.{Family, FamilyLinks}

  @slugs ~w(ainalrami openresults alnasl arkab polis nunki ascella)

  describe "the vendored programs" do
    test "all seven are there, in the documented order" do
      assert Enum.map(Family.programs(), & &1.slug) == @slugs
    end

    test "each has a page that renders, and a releases link" do
      for program <- Family.programs() do
        assert [first | _] = program.pages
        assert first.slug == nil
        assert first.html =~ "<"
        assert first.title != ""
        assert program.summary != ""

        if program.slug == "openresults",
          do: assert(program.releases_url == nil),
          else:
            assert(
              program.releases_url ==
                "https://github.com/teapot-chess/#{program.repo}/releases/latest"
            )
      end

      assert Enum.find(Family.programs(), &(&1.slug == "openresults")).repo == "openresults"
    end

    test "each has an introduction in both languages, in the same three parts" do
      for locale <- ["en", "nl"], program <- Family.programs(locale) do
        assert %{title: tagline, html: html} = program.intro, "#{locale} #{program.slug}"
        assert tagline != "" and program.tagline == tagline
        assert String.ends_with?(program.summary, "."), "#{locale} #{program.slug}"

        leads =
          if locale == "nl",
            do: ["Wanneer je het nodig hebt.", "Waar het past."],
            else: ["When you need it.", "Where it fits."]

        for lead <- leads, do: assert(html =~ "<strong>#{lead}</strong>", program.slug)
      end

      en = Family.programs("en") |> Enum.map(& &1.intro.html)
      nl = Family.programs("nl") |> Enum.map(& &1.intro.html)
      assert Enum.zip(en, nl) |> Enum.all?(fn {a, b} -> a != b end)
    end

    test "every link in an introduction lands on a chapter, a section or a program" do
      for locale <- ["en", "nl"], program <- Family.programs(locale) do
        hrefs = Regex.scan(~r/href="([^"]*)"/, program.intro.html, capture: :all_but_first)
        assert hrefs != [], program.slug

        for [href] <- hrefs do
          case String.split(href, ["/", "#"]) do
            ["", "help", "other", slug] ->
              assert Family.program(slug), "#{program.slug}: #{href}"

            ["", "help", slug | anchor] ->
              chapter = Manual.get(slug, locale)
              assert chapter, "#{program.slug}: #{href}"

              for id <- anchor,
                  do: assert(Enum.any?(chapter.toc, &(&1.id == id)), "#{program.slug}: #{href}")
          end
        end
      end
    end

    test "every program has its mark but OpenResults, which has none to have" do
      for program <- Family.programs() do
        if program.slug == "openresults" do
          assert program.mark == nil
        else
          assert [_ | _] = program.mark
          assert Enum.all?(program.mark, &(&1.kind in ~w(ink empty accent)))
          assert Enum.count(program.mark, &(&1.kind == "accent")) == 1
        end
      end
    end

    test "only Alnasl has a Dutch manual" do
      for program <- Family.programs("nl") do
        translated = Enum.map(program.pages, & &1.translated?)

        if program.slug == "alnasl",
          do: assert(Enum.all?(translated)),
          else: refute(Enum.any?(translated))
      end
    end

    test "Alnasl's Dutch pages are not the English ones" do
      en = Family.get("alnasl", "boards-and-ports", "en") |> elem(1)
      nl = Family.get("alnasl", "boards-and-ports", "nl") |> elem(1)
      assert en.html != nl.html
    end

    test "every link on every page is an in-help address or an absolute URL" do
      for locale <- ["en", "nl"], page <- Family.pages(locale) do
        hrefs = Regex.scan(~r/href="([^"]*)"/, page.html, capture: :all_but_first)

        for [href] <- hrefs do
          assert String.starts_with?(href, ["#", "https://", "http://", "mailto:", "/help/"]),
                 "#{page.key}: #{href}"

          if String.starts_with?(href, "/help/other/") do
            [path | _] = String.split(href, "#")
            [_, _, _, program | rest] = String.split(path, "/")
            assert Family.get(program, List.first(rest), locale), "#{page.key}: #{href}"
          end
        end
      end
    end

    test "links between the pages of a program stay in the help" do
      {_, program} = {nil, Family.program("alnasl")}
      html = Enum.map_join(program.pages, & &1.html)
      assert html =~ ~s(href="/help/other/alnasl/)
      refute html =~ ".md\""
    end

    test "the vendored text never says the brand name of the boards in prose" do
      for page <- Family.pages("en") ++ Family.pages("nl") do
        text = page.sections |> Enum.map_join(" ", & &1.text)
        refute text =~ ~r/\bDGT\b/, page.key
      end
    end

    test "the search covers the family pages" do
      assert Enum.any?(Manual.search("nunki"), &(&1.chapter[:family?] == true))
      results = Manual.search("announcer")
      assert Enum.any?(results, &(&1.chapter[:program] == "nunki"))
    end
  end

  describe "FamilyLinks.rewrite/4" do
    @pages %{
      "README.md" => "/help/other/demo",
      "docs/macos.md" => "/help/other/demo/macos"
    }

    test "a vendored page becomes an in-help link, anchor kept" do
      assert FamilyLinks.rewrite("docs/macos.md#x", "README.md", @pages, "Demo") ==
               "/help/other/demo/macos#x"

      assert FamilyLinks.rewrite("../README.md", "docs/macos.md", @pages, "Demo") ==
               "/help/other/demo"
    end

    test "anything else points at GitHub" do
      assert FamilyLinks.rewrite("LICENSE", "README.md", @pages, "Demo") ==
               "https://github.com/teapot-chess/Demo/blob/main/LICENSE"

      assert FamilyLinks.rewrite("releasing.md", "docs/macos.md", @pages, "Demo") ==
               "https://github.com/teapot-chess/Demo/blob/main/docs/releasing.md"

      assert FamilyLinks.rewrite("../../../x.md", "docs/macos.md", @pages, "Demo") ==
               "https://github.com/teapot-chess/Demo/blob/main/x.md"
    end

    test "absolute URLs, anchors and mail links are left alone" do
      for href <- ["https://example.org/a", "#here", "mailto:a@b.c"] do
        assert FamilyLinks.rewrite(href, "README.md", @pages, "Demo") == href
      end
    end

    test "a Dutch page resolves against the English layout" do
      pages = %{"priv/manual/02-b.md" => "/help/other/demo/b"}

      assert FamilyLinks.rewrite("02-b.md", "priv/manual/nl/01-a.md", pages, "Demo") ==
               "/help/other/demo/b"
    end
  end

  describe "FamilyLinks.scrub/1" do
    test "the board brand becomes electronic boards, but code is left alone" do
      text = "Plug in a DGT board.\n\nUse `DgtSerial` and `DGT`.\n\n```\nDGT stays\n```\n"
      out = FamilyLinks.scrub(text)
      assert out =~ "Plug in a electronic boards board."
      assert out =~ "`DGT`"
      assert out =~ "DGT stays"
    end

    test "link targets keep their spelling" do
      assert FamilyLinks.scrub("[the DGT page](https://example.org/DGT)") ==
               "[the electronic boards page](https://example.org/DGT)"
    end

    test "pictures and the holder of a copyright go" do
      out = FamilyLinks.scrub("![logo](a.png)\n\nText, (c) 2026 Some Person - same licence")
      refute out =~ "a.png"
      refute out =~ "Some Person"
      assert out =~ "same licence"

      assert FamilyLinks.scrub("Apache-2.0 (see the file), © 2026 Some Person.") ==
               "Apache-2.0 (see the file)."
    end
  end

  describe "FamilyLinks.drop_sections/3" do
    @readme """
    # Demo

    See [the tests](#tests) and [running](#running-it).

    ## Using it

    Use it.

    ## Tests

    ```sh
    ## not a heading
    mix test
    ```

    ### Running it {#running-it}

    Slowly.

    ## Licence

    Free.
    """

    test "a dropped section goes with its subsections and its code, and nothing else" do
      out = FamilyLinks.drop_sections(@readme, ["Tests"], "https://x/README.md")

      refute out =~ "## Tests"
      refute out =~ "not a heading"
      refute out =~ "Slowly"
      assert out =~ "## Using it"
      assert out =~ "## Licence\n\nFree."
    end

    test "links to what went point at the document on GitHub instead" do
      out = FamilyLinks.drop_sections(@readme, ["Tests"], "https://x/README.md")

      assert out =~ "[the tests](https://x/README.md#tests)"
      assert out =~ "[running](https://x/README.md#running-it)"
    end

    test "nothing to drop changes nothing, and a heading in a code block is code" do
      assert FamilyLinks.drop_sections(@readme, [], "u") == @readme
      assert FamilyLinks.drop_sections(@readme, ["not a heading"], "u") == @readme
    end
  end

  describe "mix help.sync_family" do
    setup do
      base = Path.join(System.tmp_dir!(), "family_sync_#{System.unique_integer([:positive])}")
      root = Path.join(base, "siblings")
      target = Path.join(base, "vendored")
      File.mkdir_p!(root)
      Mix.shell(Mix.Shell.Process)

      on_exit(fn ->
        Mix.shell(Mix.Shell.IO)
        File.rm_rf!(base)
      end)

      %{root: root, target: target}
    end

    defp flush_shell do
      receive do
        {:mix_shell, _, _} -> flush_shell()
      after
        0 -> :ok
      end
    end

    defp put(root, path, text) do
      path = Path.join(root, path)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, text)
    end

    test "takes the table's files, scrubs them and writes the manifest", %{
      root: root,
      target: target
    } do
      put(
        root,
        "nunki/README.md",
        "# Nunki\r\n\r\nSpeaks for a DGT hall.\r\n\r\n## Building\r\n\r\nmix setup\r\n"
      )

      put(root, "nunki/docs/openpairings-integration.md", "# Integration\n\nHow.\n")
      put(root, "nunki/docs/releasing.md", "# Releasing\n")
      put(root, "alnasl/priv/manual/01-getting-started.md", "# Start\n\nEnglish.\n")
      put(root, "alnasl/priv/manual/nl/01-getting-started.md", "# Begin\n\nNederlands.\n")
      put(root, "alnasl/priv/manual/nl/09-orphan.md", "# Weeskind\n")

      manifest = SyncFamily.sync(root, target)

      assert Enum.map(manifest["programs"], & &1["slug"]) == ["alnasl", "nunki"]

      assert File.read!(Path.join(target, "nunki/README.md")) ==
               "# Nunki\n\nSpeaks for a electronic boards hall.\n"

      # The plugin's wiring and the release notes are for developers, and so
      # is the README's Building.
      refute File.exists?(Path.join(target, "nunki/openpairings-integration.md"))
      refute File.exists?(Path.join(target, "nunki/releasing.md"))
      assert File.exists?(Path.join(target, "alnasl/nl/01-getting-started.md"))
      # A Dutch file without an English original is not taken.
      refute File.exists?(Path.join(target, "alnasl/nl/09-orphan.md"))

      nunki = Enum.find(manifest["programs"], &(&1["slug"] == "nunki"))
      assert nunki["commit"] == "unknown"
      assert nunki["repo"] == "Nunki"

      assert Enum.map(nunki["files"], & &1["source"]) == ["README.md"]
      assert nunki["releases"] == true

      alnasl = Enum.find(manifest["programs"], &(&1["slug"] == "alnasl"))
      assert [%{"nl" => true}] = alnasl["files"]

      assert File.read!(Path.join(target, "manifest.json")) |> Jason.decode!() == manifest
    end

    test "a second run reports nothing changed, and removes what left the table", %{
      root: root,
      target: target
    } do
      put(root, "arkab/README.md", "# Arkab\n")
      SyncFamily.sync(root, target)

      stale = Path.join(target, "arkab/stale.md")
      File.write!(stale, "# Old\n")

      flush_shell()
      SyncFamily.sync(root, target)

      assert_received {:mix_shell, :info, ["Arkab: 0 added, 0 changed, 1 unchanged, 1 removed"]}
      assert_received {:mix_shell, :info, ["  removed: arkab/stale.md"]}
      refute File.exists?(stale)

      put(root, "arkab/README.md", "# Arkab\n\nMore.\n")
      SyncFamily.sync(root, target)
      assert_received {:mix_shell, :info, ["Arkab: 0 added, 1 changed" <> _]}
      assert_received {:mix_shell, :info, ["  changed: arkab/README.md"]}
    end

    test "a program without a checkout is left as it was", %{root: root, target: target} do
      put(root, "arkab/README.md", "# Arkab\n")
      SyncFamily.sync(root, target)
      File.rm_rf!(Path.join(root, "arkab"))
      put(root, "polis/README.md", "# Polis\n")

      manifest = SyncFamily.sync(root, target)

      assert Enum.map(manifest["programs"], & &1["slug"]) == ["arkab", "polis"]
      assert File.exists?(Path.join(target, "arkab/README.md"))
    end

    test "the selection table names the seven programs" do
      assert Enum.map(SyncFamily.programs(), & &1.slug) == @slugs
    end
  end
end
