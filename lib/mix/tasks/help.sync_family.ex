defmodule Mix.Tasks.Help.SyncFamily do
  @shortdoc "Refreshes the vendored documentation of the other programs in the family"

  @moduledoc """
  Copies the documentation of Alnasl, Arkab, Ascella, Polis, Nunki and
  OpenResults from their sibling checkouts into `priv/manual/family/`, where
  `PairingsEngine.Manual.Family` bakes it into the Help pages.

      mix help.sync_family
      mix help.sync_family --root ../..

  The public CI and the release builds of OpenPairings cannot see the
  sibling repositories, so the text is vendored: committed here, refreshed by
  whoever runs this task, then reviewed as a diff like any other change.

  `--root` is the folder that holds the checkouts (`alnasl/`, `arkab/`, ...).
  Without it the task looks upwards from the current directory, which finds
  them from the main checkout and from a worktree of it alike. A program
  whose checkout is not found is reported and left as it was.

  Every document passes through `PairingsEngine.Manual.FamilyLinks.scrub/1`
  (pictures dropped, `DGT` in prose written as "electronic boards"). What
  is taken from each program is the one table below, `@programs`: the
  README and the pages meant for the people who use the program. Plans,
  briefs, release notes, audits, protocol contracts, deployment and launcher
  internals are not on it, deliberately.

  The task prints what it added, changed and removed, and writes
  `priv/manual/family/manifest.json`: per program, the commit its checkout
  was at, and whether the vendored files differed from that commit.
  """
  use Mix.Task

  alias PairingsEngine.Manual.FamilyLinks

  # THE selection. `files` and `nl` are globs inside the program's checkout;
  # the Dutch files keep their names, so `nl` is only the folder to look in.
  @programs [
    %{
      slug: "alnasl",
      name: "Alnasl",
      repo: "Alnasl",
      dir: "alnasl",
      files: ["priv/manual/[0-9]*.md"],
      nl: ["priv/manual/nl/[0-9]*.md"]
    },
    %{slug: "arkab", name: "Arkab", repo: "Arkab", dir: "arkab", files: ["README.md"], nl: []},
    %{
      slug: "ascella",
      name: "Ascella",
      repo: "Ascella",
      dir: "ascella",
      files: ["README.md"],
      nl: []
    },
    %{
      slug: "polis",
      name: "Polis",
      repo: "Polis",
      dir: "polis",
      files: ["README.md", "docs/openpairings-integration.md"],
      nl: []
    },
    %{
      slug: "nunki",
      name: "Nunki",
      repo: "Nunki",
      dir: "nunki",
      files: ["README.md", "docs/openpairings-integration.md"],
      nl: []
    },
    %{
      slug: "openresults",
      name: "OpenResults",
      repo: "openresults",
      dir: "openresults",
      files: ["README.md", "docs/public-extras.md"],
      nl: []
    }
  ]

  @doc "The selection table, for tests and for whoever wants to see it."
  def programs, do: @programs

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [root: :string, target: :string])

    target = opts[:target] || Path.expand("priv/manual/family")
    root = opts[:root] && Path.expand(opts[:root])

    sync(root || find_root(), target)
  end

  @doc """
  Syncs every program found under `root` into `target`. Returns the manifest.
  Public so the tests can point it at a temporary folder.
  """
  def sync(root, target) do
    # Expanded: `Path.wildcard/1` takes a backslash for an escape.
    root = root && Path.expand(root)
    target = Path.expand(target)
    old = read_manifest(target)

    entries =
      for program <- @programs do
        checkout = root && Path.join(root, program.dir)

        if checkout && File.dir?(checkout) do
          sync_program(program, checkout, target)
        else
          Mix.shell().info("#{program.name}: no checkout found, left as it was")
          Enum.find(old["programs"] || [], &(&1["slug"] == program.slug))
        end
      end
      |> Enum.reject(&is_nil/1)

    manifest = %{"programs" => entries}
    File.mkdir_p!(target)
    File.write!(Path.join(target, "manifest.json"), Jason.encode!(manifest, pretty: true) <> "\n")
    manifest
  end

  # Looks for a folder with the checkouts in it, upwards from here.
  defp find_root do
    cwd = File.cwd!()

    0..6
    |> Enum.map(fn n -> Enum.reduce(1..n//1, cwd, fn _, dir -> Path.dirname(dir) end) end)
    |> Enum.find(fn dir ->
      Enum.any?(@programs, &File.dir?(Path.join(dir, &1.dir <> "/.git")))
    end)
    |> case do
      nil -> Mix.raise("No sibling checkouts found above #{cwd}; pass --root DIR")
      dir -> dir
    end
  end

  defp sync_program(program, checkout, target) do
    folder = Path.join(target, program.slug)
    english = expand(checkout, program.files)
    dutch = expand(checkout, program.nl)

    # The Dutch file is used for a page only if the English one exists.
    english_names = MapSet.new(english, &Path.basename/1)
    dutch = Enum.filter(dutch, &MapSet.member?(english_names, Path.basename(&1)))

    wanted =
      Enum.map(english, &{Path.join(folder, Path.basename(&1)), &1}) ++
        Enum.map(dutch, &{Path.join([folder, "nl", Path.basename(&1)]), &1})

    changes =
      for {dest, source} <- wanted do
        text = source |> File.read!() |> FamilyLinks.scrub()
        write_if_changed(dest, text)
      end

    removed = remove_stale(folder, Enum.map(wanted, &elem(&1, 0)))

    report(program, Enum.zip(Enum.map(wanted, &elem(&1, 0)), changes), removed, target)

    %{
      "slug" => program.slug,
      "name" => program.name,
      "repo" => program.repo,
      "commit" => commit(checkout),
      "dirty" => dirty?(checkout, english ++ dutch),
      "files" =>
        Enum.map(english, fn path ->
          %{
            "source" => relative(checkout, path),
            "file" => Path.basename(path),
            "nl" => Enum.any?(dutch, &(Path.basename(&1) == Path.basename(path)))
          }
        end)
    }
  end

  defp expand(checkout, globs) do
    globs
    |> Enum.flat_map(&Path.wildcard(Path.join(checkout, &1)))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp relative(checkout, path), do: Path.relative_to(path, checkout)

  defp write_if_changed(dest, text) do
    case File.read(dest) do
      {:ok, ^text} ->
        :unchanged

      {:ok, _} ->
        File.write!(dest, text)
        :changed

      {:error, _} ->
        File.mkdir_p!(Path.dirname(dest))
        File.write!(dest, text)
        :added
    end
  end

  defp remove_stale(folder, keep) do
    keep = MapSet.new(keep)

    for path <- Path.wildcard(Path.join(folder, "**/*.md")), not MapSet.member?(keep, path) do
      File.rm!(path)
      path
    end
  end

  defp report(program, changes, removed, target) do
    count = fn kind -> Enum.count(changes, &(elem(&1, 1) == kind)) end

    Mix.shell().info(
      "#{program.name}: #{count.(:added)} added, #{count.(:changed)} changed, " <>
        "#{count.(:unchanged)} unchanged, #{length(removed)} removed"
    )

    for {path, kind} <- changes, kind != :unchanged do
      Mix.shell().info("  #{kind}: #{Path.relative_to(path, target)}")
    end

    for path <- removed do
      Mix.shell().info("  removed: #{Path.relative_to(path, target)}")
    end
  end

  defp read_manifest(target) do
    with {:ok, text} <- File.read(Path.join(target, "manifest.json")),
         {:ok, manifest} <- Jason.decode(text) do
      manifest
    else
      _ -> %{}
    end
  end

  defp commit(checkout) do
    case git(checkout, ["rev-parse", "HEAD"]) do
      {:ok, hash} -> hash
      :error -> "unknown"
    end
  end

  # True if a vendored file differs from the commit recorded for it, i.e. the
  # hash alone does not say what was copied.
  defp dirty?(checkout, paths) do
    relative = Enum.map(paths, &relative(checkout, &1))

    case git(checkout, ["status", "--porcelain", "--" | relative]) do
      {:ok, ""} -> false
      {:ok, _} -> true
      :error -> false
    end
  end

  defp git(checkout, args) do
    case System.cmd("git", ["-C", checkout | args], stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      _ -> :error
    end
  rescue
    _ -> :error
  end
end
