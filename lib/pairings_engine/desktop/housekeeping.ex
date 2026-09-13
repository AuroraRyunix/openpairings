defmodule PairingsEngine.Desktop.Housekeeping do
  @moduledoc """
  What a Windows desktop start does before anything opens the database:
  put the data where no installer can remove it, then make the "Installed
  apps" entries safe and single.

  Runs from `PairingsEngine.Application.start/2`, before migrations, and
  only when `config/runtime.exs` decided this is the Windows default layout
  (local mode, on Windows, no `OPENPAIRINGS_DATA_DIR`) - which it records as
  `:windows_data_layout`. Nothing here may stop a start: every step past the
  data move is wrapped, logged and skipped on failure, and the data move
  itself falls back to the old directory rather than raising.

  The order is the point:

    1. `DataHome.secure/2` - the data moves (or is found already moved).
    2. The application's configuration is pointed at wherever it now is.
    3. `DataHome.move_backups/1`, then `DataHome.tidy_program_files/1`.
    4. `UninstallEntries` - only now, so that an entry is never judged
       against a data directory that is about to move.
  """

  require Logger

  alias PairingsEngine.Desktop.{DataHome, Registry, UninstallEntries}

  @result_key {__MODULE__, :result}

  @doc "Runs it all if this is the Windows default layout; otherwise nothing."
  @spec run() :: :ok
  def run do
    case Application.get_env(:pairings_engine, :windows_data_layout) do
      %{parent: _} = layout -> run(layout, registry: registry())
      _ -> :ok
    end
  end

  @doc false
  # The same steps with the registry injected, for tests. `registry: nil`
  # skips the entries step (a machine with no registry).
  def run(layout, opts) do
    {outcome, home} = DataHome.secure(layout, running_from: System.get_env("RELEASE_ROOT"))
    repoint(layout, home)

    step(:backups, fn -> DataHome.move_backups(layout) end)
    step(:program_files, fn -> DataHome.tidy_program_files(layout.home) end)

    step(:set_aside_trees, fn ->
      release_root = System.get_env("RELEASE_ROOT")
      install = UninstallEntries.install_from_release_root(release_root)
      clear_set_aside_trees(layout, install, release_root)
    end)

    reports =
      case opts[:registry] do
        nil ->
          []

        registry ->
          step(:uninstall_entries, fn -> consolidate(layout, registry) end) || []
      end

    # After a copy the old folder keeps its (now unused) copy by design; after
    # an earlier move it should be gone, so data there again is worth saying.
    legacy_left? = outcome == :already and DataHome.has_data?(layout.legacy)

    if legacy_left? do
      Logger.warning(
        "#{layout.legacy} has OpenPairings data in it again, but #{layout.home} is the data " <>
          "directory. Nothing in the old folder is used or changed; an older OpenPairings " <>
          "may have been started since the move."
      )
    end

    :persistent_term.put(@result_key, %{
      outcome: outcome,
      home: home,
      legacy_still_has_data: legacy_left?,
      reports: reports
    })

    :ok
  end

  @doc "What the last `run/0` found, for the page that shows it; nil if it did not run."
  def result, do: :persistent_term.get(@result_key, nil)

  defp registry do
    if Registry.available?(), do: {Registry, Registry.real_roots()}
  end

  @set_aside_prefix "current.before-msi-"

  @doc """
  Deletes the program trees the `.msi` set aside when it installed over a
  Setup.exe install (`current.before-msi-*`, see `set_aside_setup_exe_tree`
  in `rel/windows/launcher.c`), once this copy is running from the `.msi`'s
  own tree - and refuses everything else.

  Program files, not data; but a recursive delete all the same, so it only
  touches a directory that sits directly in the running `.msi` install's
  root, carries that exact name prefix, is not the tree this process runs
  from, and is none of - and contains none of - the data, old data or
  backups directories. `HousekeepingTest` mutation-checks the guard.
  """
  @spec clear_set_aside_trees(
          DataHome.layout(),
          UninstallEntries.install() | nil,
          String.t() | nil
        ) :: :ok
  def clear_set_aside_trees(_layout, nil, _release_root), do: :ok

  def clear_set_aside_trees(layout, %{kind: :msi, root: root} = install, release_root) do
    case File.ls(root) do
      {:ok, names} ->
        for name <- names, String.starts_with?(name, @set_aside_prefix) do
          path = Path.join(root, name)

          if set_aside_removable?(layout, install, release_root, path) do
            File.rm_rf!(path)
          end
        end

        :ok

      {:error, _} ->
        :ok
    end
  end

  def clear_set_aside_trees(_layout, _install, _release_root), do: :ok

  @doc false
  def set_aside_removable?(layout, %{kind: :msi, root: root}, release_root, path) do
    File.dir?(path) and
      DataHome.same_path?(Path.dirname(Path.expand(path)), root) and
      String.starts_with?(Path.basename(path), @set_aside_prefix) and
      not DataHome.same_path?(path, release_root) and
      not DataHome.inside?(release_root, path) and
      not Enum.any?([layout.legacy, layout.home, layout.backups, layout.parent], fn protected ->
        DataHome.same_path?(path, protected) or DataHome.inside?(protected, path)
      end)
  end

  def set_aside_removable?(_layout, _install, _release_root, _path), do: false

  defp consolidate(layout, registry) do
    install = UninstallEntries.install_from_release_root(System.get_env("RELEASE_ROOT"))

    registry
    |> UninstallEntries.read_all()
    |> UninstallEntries.plan(%{layout: layout, install: install, version: version()})
    |> UninstallEntries.apply_actions(registry)
    |> tap(fn reports ->
      for {what, entry} <- reports do
        Logger.warning("Installed apps entry #{entry.root}\\#{entry.key}: #{inspect(what)}")
      end
    end)
  end

  defp version do
    case Application.spec(:pairings_engine, :vsn) do
      nil -> ""
      vsn -> List.to_string(vsn)
    end
  end

  # `config/runtime.exs` pointed the database at whichever directory it saw;
  # if this start moved it, everything that reads the path at runtime has to
  # see the new one before the repository starts.
  defp repoint(layout, home) do
    repo = Application.get_env(:pairings_engine, PairingsEngine.Repo, [])
    database = repo[:database]

    if is_binary(database) and DataHome.inside?(database, layout.legacy) and
         not DataHome.same_path?(home, layout.legacy) do
      moved = Path.join(home, Path.basename(database))

      Application.put_env(
        :pairings_engine,
        PairingsEngine.Repo,
        Keyword.put(repo, :database, moved)
      )
    end

    :ok
  end

  defp step(name, fun) do
    fun.()
  rescue
    error ->
      Logger.error(
        "Desktop housekeeping step #{name} failed: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      nil
  end
end
