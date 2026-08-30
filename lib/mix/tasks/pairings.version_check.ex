defmodule Mix.Tasks.Pairings.VersionCheck do
  @shortdoc "Fails if a document states a version mix.exs does not"

  @moduledoc """
  Checks that every document naming the app's version names the same one.

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

  @impl Mix.Task
  def run(_args) do
    expected = Mix.Project.config()[:version]

    case Enum.flat_map(@documents, &check(&1, expected)) do
      [] ->
        Mix.shell().info("Version #{expected} agreed by #{length(@documents)} documents.")

      problems ->
        Mix.raise("""
        mix.exs is at #{expected}, and these disagree:

        #{Enum.join(problems, "\n")}

        Bump them, or bump mix.exs if the documents are the ones that are right.
        """)
    end
  end

  defp check({path, pattern, what}, expected) do
    case File.read(path) do
      {:error, reason} ->
        ["  #{path} - could not be read (#{:file.format_error(reason)})"]

      {:ok, contents} ->
        case Regex.run(pattern, contents) do
          [_whole, ^expected] -> []
          [_whole, found] -> ["  #{path} - #{what} says #{found}"]
          nil -> ["  #{path} - #{what} states no version this could find"]
        end
    end
  end
end
