defmodule Mix.Tasks.Pairings.VersionCheck do
  @shortdoc "Fails if a document states a version mix.exs does not"

  @moduledoc """
  Checks that every document naming the app's version names the same one, and
  that every file that is supposed to derive it has not gone back to stating
  one.

  ## Why this exists

  The version is written in four places and `mix.exs` is the only one anything
  reads. The other three are prose, so nothing catches them drifting - and
  they have drifted repeatedly:

    * The 2026-08-26 sweep found `TODO.md` and `docs/features.md` both on
      0.16.1 while `mix.exs` was on 0.17.1 and the changelog's top section
      was 0.17.1 too. It suggested exactly this check.
    * `TODO.md` was fixed to 0.18.0 and `docs/features.md` was not, so the
      same drift recurred **inside the three days** the follow-up covered.
    * The follow-up filed that recurrence as live proof the check would
      already have paid for itself. It still did not exist.

  A version header is the cheapest possible thing to get wrong and one of the
  more embarrassing to be caught on: it is the first line a reader sees, and
  being wrong there invites them to distrust the rest.

  ## The other direction

  On 2026-09-10 the same failure turned up somewhere prose was not: the macOS
  `.app` bundle's `Info.plist`, written by `.github/workflows/binaries.yml`,
  carried a literal `0.18.0` while the app was on 0.54.0. `Info.plist` is not
  a document nobody reads - macOS reads it, and shows
  `CFBundleShortVersionString` as the Finder "Version" column and in Get Info
  - so 37 minor versions of `.dmg` told their users the wrong number.

  The fix there was not to add a fourth document to keep in step. It was to
  make the workflow read `mix.exs` at build time, which is what the Windows
  launcher already did (`mix.exs` hands `release.version` to
  `rel/windows/build_launcher.ps1`). So the check's job for that file is the
  inverse of its job for the prose: a version found there is the failure,
  because finding one means somebody hardcoded it again.

  ## What it does not do

  It does not bump anything, and it deliberately does not know which file is
  right - it reads `mix.exs` and reports every document that disagrees. A
  release is still a human deciding to bump; this only refuses to let the
  documents fall behind after they have.

  Run from `mix precommit`, and on its own:

      mix pairings.version_check
  """

  use Mix.Task

  # Each entry is {path, regex, what it is}. The regex must capture the
  # version in group 1, and is matched against the whole file - the changelog
  # has many version headings and only its first is the current one, which is
  # what `Regex.run/2` returns.
  @documents [
    {"TODO.md", ~r/^Version: \*\*(\d+\.\d+\.\d+)\*\*/m, "the roadmap's header"},
    {"docs/features.md", ~r/^Current version: \*\*(\d+\.\d+\.\d+)\*\*/m,
     "the feature list's header"},
    {"CHANGELOG.md", ~r/^## \[(\d+\.\d+\.\d+)\]/m, "the changelog's top section"}
  ]

  # Same shape, opposite verdict: these files build the version from mix.exs,
  # so a match is what fails. Matching the current version is no defence - a
  # literal that happens to be right today is the state the plist was in the
  # day somebody typed it, and it drifts on the next bump.
  #
  # Anchored on the CFBundle keys rather than on any three-part number,
  # because that workflow is full of legitimate versions: OTP, Elixir, Zig,
  # and every pinned action SHA's trailing comment.
  @derived [
    {".github/workflows/binaries.yml",
     ~r{<key>CFBundle(?:ShortVersionString|Version)</key>\s*<string>(\d+\.\d+\.\d+)</string>},
     "the macOS bundle's Info.plist"}
  ]

  @impl Mix.Task
  def run(_args) do
    expected = Mix.Project.config()[:version]

    stale = Enum.flat_map(@documents, &check_states(&1, expected))
    hardcoded = Enum.flat_map(@derived, &check_derives/1)

    case stale ++ hardcoded do
      [] ->
        Mix.shell().info(
          "Version #{expected} agreed by #{length(@documents)} documents, " <>
            "and derived by #{length(@derived)}."
        )

      _ ->
        Mix.raise(report(expected, stale, hardcoded))
    end
  end

  defp check_states({path, pattern, what}, expected) do
    with_file(path, fn contents ->
      case Regex.run(pattern, contents) do
        [_whole, ^expected] -> []
        [_whole, found] -> ["  #{path} - #{what} says #{found}"]
        nil -> ["  #{path} - #{what} states no version this could find"]
      end
    end)
  end

  defp check_derives({path, pattern, what}) do
    with_file(path, fn contents ->
      case Regex.run(pattern, contents) do
        nil -> []
        [_whole, found] -> ["  #{path} - #{what} hardcodes #{found}"]
      end
    end)
  end

  defp with_file(path, fun) do
    case File.read(path) do
      {:error, reason} -> ["  #{path} - could not be read (#{:file.format_error(reason)})"]
      {:ok, contents} -> fun.(contents)
    end
  end

  defp report(expected, stale, hardcoded) do
    IO.iodata_to_binary([
      "mix.exs is at #{expected}.\n",
      section(
        stale,
        """

        These state a different one:
        """,
        """

        Bump them, or bump mix.exs if the documents are the ones that are right.
        """
      ),
      section(
        hardcoded,
        """

        These are supposed to take it from mix.exs at build time:
        """,
        """

        Put the value back behind whatever reads mix.exs there. A literal is
        wrong even when it is currently right - it only has to survive one bump
        to start lying.
        """
      )
    ])
  end

  defp section([], _heading, _advice), do: []
  defp section(problems, heading, advice), do: [heading, Enum.join(problems, "\n"), "\n", advice]
end
