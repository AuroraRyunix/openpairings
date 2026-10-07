# The hosted edition's plugins (see mix.exs) are formatted with these same
# rules; in every other build the list is empty.
plugin_inputs =
  for dir <- Mix.Project.config()[:pairings_plugin_dirs] || [],
      glob <- ["{lib,test}/**/*.{heex,ex,exs}", "priv/migrations/*.exs"],
      do: Path.join(dir, glob)

[
  import_deps: [:ecto, :ecto_sql, :phoenix],
  subdirectories: ["priv/*/migrations"],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs:
    ["*.{heex,ex,exs}", "{config,lib,test}/**/*.{heex,ex,exs}", "priv/*/seeds.exs"] ++
      plugin_inputs
]
