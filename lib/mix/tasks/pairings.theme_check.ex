defmodule Mix.Tasks.Pairings.ThemeCheck do
  @shortdoc "Checks a theme pack: safety scan, then WCAG contrast in every accent"

  @moduledoc """
  Checks a theme pack folder before it is installed anywhere:

      mix pairings.theme_check path/to/my-theme

  Two passes, the same two the program applies:

    1. `PairingsEngine.ThemePacks.load/1` - `theme.json` is complete,
       `theme.css` is under 200 KB, and `PairingsEngine.ThemePacks.Scanner`
       finds nothing it refuses (no `@import`, no URL but the pack's own
       `fonts/*.woff2`, every rule scoped to `[data-theme="<id>"]`). A pack
       that fails here is refused by the app as well.
    2. `PairingsEngineWeb.ThemeContrast` - the WCAG pairings
       `test/pairings_engine_web/contrast_test.exs` holds the built-in themes
       to, in all nine accents, plus every rule (the app's and the pack's)
       that sets a colour and a background together, and the sign-in panel.
       The app would load a pack that fails here; this is where its author
       finds out that nobody can read it.

  Prints every failure and exits non-zero if there is one. Reads the app's
  stylesheet from `assets/css/app.css`, so run it from the repository.
  """

  use Mix.Task

  alias PairingsEngine.ThemePacks
  alias PairingsEngineWeb.ThemeContrast

  @impl Mix.Task
  def run([path]) do
    Mix.Task.run("compile")

    case ThemePacks.load(path) do
      {:error, reason} ->
        Mix.shell().error("refused: #{reason}")
        exit({:shutdown, 1})

      {:ok, pack} ->
        Mix.shell().info("#{pack.id}: scan passed (#{if pack.dark, do: "dark", else: "light"})")
        core = File.read!(Path.join(File.cwd!(), "assets/css/app.css"))
        css = File.read!(Path.join(path, "theme.css"))

        case ThemeContrast.pack_failures(core, css, pack.id, pack.dark) do
          [] ->
            Mix.shell().info(
              "#{pack.id}: contrast passed in all #{length(ThemeContrast.accents())} accents"
            )

          failures ->
            Enum.each(failures, fn failure -> Mix.shell().error(failure) end)
            Mix.shell().error("#{length(failures)} contrast failure(s)")
            exit({:shutdown, 1})
        end
    end
  end

  def run(_), do: Mix.raise("usage: mix pairings.theme_check PATH")
end
