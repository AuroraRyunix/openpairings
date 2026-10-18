defmodule PairingsEngine.Manual.Family do
  @moduledoc """
  The documentation of the other programs in the family - Alnasl, Arkab,
  Ascella, Polis, Nunki and OpenResults - shown in the Help under "Other
  programs". Duplicating their text here is intended: one place to read, for
  an arbiter who has all of them running in the same hall.

  ## Where the text comes from

  `priv/manual/family/<program>/*.md` (Dutch in `.../nl/`), vendored by
  `mix help.sync_family` from the sibling checkouts, with
  `priv/manual/family/manifest.json` recording which commit each came from.
  The public CI and the release builds cannot see those checkouts, which is
  the whole reason the text is committed here. Do not edit the vendored
  files by hand: the next sync overwrites them. What is taken, and what is
  deliberately not, is the table in `Mix.Tasks.Help.SyncFamily`.

  ## How it is rendered

  Exactly as the chapters of `PairingsEngine.Manual` are
  (`PairingsEngine.Manual.Markup`), at compile time, with one difference:
  links go through `PairingsEngine.Manual.FamilyLinks.rewrite/4`, so a link
  to another vendored page of the program opens it in the Help and anything
  else (the licence, a document that is not vendored) opens the program's
  GitHub.

  Only Alnasl has a Dutch manual; every other page is shown in English on
  the Dutch side, which `translated?` says (the page tells the reader).
  """

  alias PairingsEngine.Manual.{FamilyLinks, Markup}

  @family_dir Path.expand("../../../priv/manual/family", __DIR__)
  @manifest_file Path.join(@family_dir, "manifest.json")
  @screenshot_dir Path.expand("../../../priv/static/images/manual", __DIR__)

  @external_resource @manifest_file

  @manifest (case File.read(@manifest_file) do
               {:ok, text} -> Jason.decode!(text)
               {:error, _} -> %{"programs" => []}
             end)

  # A change in the set of vendored files is noticed, as for the chapters.
  @files_hash :erlang.md5(
                :erlang.term_to_binary(Path.wildcard(Path.join(@family_dir, "**/*.md")))
              )

  for file <- Path.wildcard(Path.join(@family_dir, "**/*.md")), do: @external_resource(file)

  @doc false
  def __mix_recompile__? do
    :erlang.md5(:erlang.term_to_binary(Path.wildcard(Path.join(@family_dir, "**/*.md")))) !=
      @files_hash
  end

  slug_of = fn file ->
    file |> Path.basename(".md") |> String.replace(~r/\A\d+-/, "") |> String.downcase()
  end

  # The first file of a program (its README, or its first chapter) is the
  # program's own address; the rest hang below it.
  address = fn program, file, first ->
    if file == first["file"],
      do: "/help/other/" <> program,
      else: "/help/other/#{program}/#{slug_of.(file)}"
  end

  render = fn program, entry, index, locale ->
    folder = if locale == "en", do: [], else: [locale]
    file = Path.join([@family_dir, program["slug"]] ++ folder ++ [entry["file"]])
    translated? = locale == "en" or entry["nl"] == true

    file =
      if File.regular?(file),
        do: file,
        else: Path.join([@family_dir, program["slug"], entry["file"]])

    # Source path -> address, for the links of this program.
    pages =
      Map.new(program["files"], fn e ->
        {e["source"], address.(program["slug"], e["file"], hd(program["files"]))}
      end)

    rendered =
      file
      |> File.read!()
      |> Markup.chapter(0,
        screenshot_dir: @screenshot_dir,
        link: &FamilyLinks.rewrite(&1, entry["source"], pages, program["repo"])
      )

    page_slug = slug_of.(entry["file"])
    first? = index == 0

    rendered
    |> Map.put(:family?, true)
    |> Map.put(:program, program["slug"])
    |> Map.put(:program_name, program["name"])
    |> Map.put(:slug, if(first?, do: nil, else: page_slug))
    |> Map.put(:key, program["slug"] <> "/" <> if(first?, do: "", else: page_slug))
    |> Map.put(:number, nil)
    |> Map.put(:order, 1000)
    |> Map.put(:translated?, translated?)
    |> Map.put(:title, if(rendered.title == "", do: entry["file"], else: rendered.title))
  end

  @programs (for {program, p_index} <- Enum.with_index(@manifest["programs"]) do
               pages_for = fn locale ->
                 for {entry, index} <- Enum.with_index(program["files"]) do
                   render.(program, entry, index, locale)
                   |> Map.put(:order, 1000 + p_index * 100 + index)
                 end
               end

               %{
                 slug: program["slug"],
                 name: program["name"],
                 repo: program["repo"],
                 commit: program["commit"],
                 releases_url: FamilyLinks.releases(program["repo"]),
                 github_url: FamilyLinks.github(program["repo"]),
                 pages: %{"en" => pages_for.("en"), "nl" => pages_for.("nl")}
               }
             end)

  @doc """
  The programs, in the order of the manifest, as `%{slug:, name:, repo:,
  commit:, releases_url:, github_url:, pages:, summary:}`. `pages` are
  chapter-like maps (`title`, `html`, `toc`, `sections`, `summary`, `slug`,
  `program`, `translated?`, ...), the program's own page first.
  """
  def programs(locale \\ "en") do
    Enum.map(@programs, fn program ->
      pages = Map.get(program.pages, locale, program.pages["en"])
      program |> Map.put(:pages, pages) |> Map.put(:summary, summary(pages))
    end)
  end

  defp summary([first | _]), do: first.summary
  defp summary([]), do: ""

  @doc "The program with this slug, or `nil`."
  def program(slug, locale \\ "en"), do: Enum.find(programs(locale), &(&1.slug == slug))

  @doc """
  One page: the program's own (`page_slug` `nil`) or another of its pages.
  Returns `{program, page}` or `nil`.
  """
  def get(program_slug, page_slug \\ nil, locale \\ "en") do
    with %{} = program <- program(program_slug, locale),
         %{} = page <- Enum.find(program.pages, &(&1.slug == page_slug)) do
      {program, page}
    else
      _ -> nil
    end
  end

  @doc "Every page of every program, for the search."
  def pages(locale \\ "en"), do: Enum.flat_map(programs(locale), & &1.pages)

  @doc "The address of a page."
  def path(%{program: program, slug: nil}), do: "/help/other/" <> program
  def path(%{program: program, slug: slug}), do: "/help/other/#{program}/#{slug}"

  @doc "The page before and after `page` in its program, as `{previous, next}`."
  def neighbours(%{program: slug} = page, locale \\ "en") do
    case program(slug, locale) do
      nil ->
        {nil, nil}

      %{pages: pages} ->
        index = Enum.find_index(pages, &(&1.slug == page.slug))
        {if(index > 0, do: Enum.at(pages, index - 1)), Enum.at(pages, index + 1)}
    end
  end
end
