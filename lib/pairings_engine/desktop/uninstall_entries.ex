defmodule PairingsEngine.Desktop.UninstallEntries do
  @moduledoc """
  OpenPairings' own entries in Windows' "Installed apps" list, made safe and
  made one.

  ## What goes wrong without this

  Two installer types and one abandoned pack id each register their own
  entry, and neither installer type knows the other exists:

  | key under `...\\Uninstall`   | written by                          | uninstall runs |
  |------------------------------|-------------------------------------|----------------|
  | `OpenPairings`               | Setup.exe packed with the old id (0.53.x) | `Update.exe --uninstall`, which empties `%LOCALAPPDATA%\\OpenPairings` - the old data directory |
  | `OpenPairingsApp`            | Setup.exe                           | `Update.exe --uninstall` on its install directory |
  | `MSI:OpenPairingsApp`        | the `.msi` (HKCU per-user, HKLM per-machine) | `msiexec /x`, whose cleanup deletes the install directory AND `%LOCALAPPDATA%\\OpenPairings` (0.58.1-0.61.0, see `PairingsEngine.Desktop.DataHome`) |

  Setup.exe over an `.msi` install, or the `.msi` over Setup.exe, writes to
  the same install directory and leaves both entries - and uninstalling
  either one then deletes the directory the other still points at. An in-app
  update refreshes the version on its own entry only, so the other goes
  stale.

  ## What this does, on every start of a desktop install

  It reads only the four key names above, and only entries whose
  `DisplayName` is `OpenPairings`. It never runs an uninstaller and never
  deletes a file. For each entry it finds, in this order:

    1. **Its uninstall would remove data** - its install location is, or
       contains, the data directory, the backups directory, or the old data
       directory while that still holds data - and it is not the entry of the
       copy that is running: **removed**.
    2. **It is the running copy's own entry**: its `DisplayVersion` is set to
       this version if it differs.
    3. **It points at the running copy's directory but is the other
       installer type's entry**: **removed** - the running copy's own entry
       stays, and it is the one that matches what is on disk.
    4. **Its install location no longer exists**: **removed**.
    5. **It is a second, real install** (the other scope): left alone, and
       reported, because which one to keep is the arbiter's decision.

  "Removed" means: every value copied to
  `HKCU\\Software\\OpenPairings\\RemovedUninstallEntries\\<key>` and read back,
  and only then the key deleted. A crash between the two leaves both, and the
  next start repeats both - the copy is overwritten with the same values and
  the delete goes ahead. Entries under `HKEY_LOCAL_MACHINE` need an
  administrator to change and are only ever reported.

  The hidden Windows Installer product behind an `MSI:` entry stays
  registered: removing it without running its own uninstall is not something
  Windows offers, and running its uninstall is exactly what this avoids. It
  is invisible in the list, and a later `.msi` of this project removes it as
  part of its upgrade - after moving the data out of its way first.
  """

  require Logger

  alias PairingsEngine.Desktop.DataHome

  @keys ["OpenPairings", "OpenPairingsApp", "MSI:OpenPairingsApp", "MSI:OpenPairings"]
  @display_name "OpenPairings"

  @type entry :: %{root: atom(), key: String.t(), values: map()}
  @type install :: %{root: Path.t(), kind: :setup_exe | :msi, scope: :user | :machine}
  @type action ::
          {:remove, entry(), atom()}
          | {:set_version, entry(), String.t()}
          | {:report, atom(), entry()}

  @doc "The key names this module will ever look at."
  def keys, do: @keys

  @doc "Every OpenPairings entry under the given roots."
  @spec read_all({module(), map()}) :: [entry()]
  def read_all({store, roots}) do
    for root <- [:hkcu, :hklm, :hklm32],
        Map.has_key?(roots, root),
        key <- @keys,
        {:ok, values} <- [store.read(roots, root, key)],
        values["DisplayName"] in [nil, @display_name] do
      %{root: root, key: key, values: values}
    end
  end

  @doc """
  What to do about `entries`, decided without touching anything.

  `context`:

    * `:layout` - `PairingsEngine.Desktop.DataHome.layout/1`
    * `:install` - the running copy (`install_from_release_root/1`), or nil
      for a portable or single-file run
    * `:version` - this version
    * `:dir?` - optional, for tests; defaults to `File.dir?/1`
  """
  @spec plan([entry()], map()) :: [action()]
  def plan(entries, context) do
    dir? = Map.get(context, :dir?, &File.dir?/1)
    Enum.flat_map(entries, &decide(&1, context, dir?))
  end

  defp decide(entry, %{layout: layout, install: install, version: version}, dir?) do
    location = location(entry)
    own_dir? = install != nil and DataHome.same_path?(location, install.root)

    cond do
      endangers_data?(location, layout) and not own_dir? ->
        [removal(entry, :endangers_data)]

      own_dir? and own_entry?(entry, install) ->
        cond do
          endangers_data?(location, layout) ->
            [{:report, :own_entry_endangers_data, entry}]

          entry.values["DisplayVersion"] != version and entry.root == :hkcu ->
            [{:set_version, entry, version}]

          true ->
            []
        end

      own_dir? ->
        [removal(entry, :duplicate_of_running_install)]

      location == nil or not dir?.(location) ->
        [removal(entry, :install_location_missing)]

      # A portable or single-file run beside an installed copy is not two
      # installs; only an installed copy can be installed twice.
      install == nil ->
        []

      true ->
        [{:report, :installed_twice, entry}]
    end
  end

  defp removal(%{root: :hkcu} = entry, reason), do: {:remove, entry, reason}
  defp removal(entry, reason), do: {:report, {:needs_administrator, reason}, entry}

  # Whether running this entry's uninstall could delete anything of the
  # arbiter's: its install directory is one of the data directories, or holds
  # one. The old directory counts only while it still has data in it - once
  # the data has moved it is just an old program folder.
  defp endangers_data?(nil, _layout), do: false

  defp endangers_data?(location, layout) do
    protected =
      [layout.home, layout.backups] ++
        if DataHome.has_data?(layout.legacy), do: [layout.legacy], else: []

    Enum.any?(protected, fn dir ->
      DataHome.same_path?(dir, location) or DataHome.inside?(dir, location)
    end)
  end

  defp own_entry?(%{key: "MSI:" <> _, root: root}, %{kind: :msi, scope: scope}),
    do: (scope == :user and root == :hkcu) or (scope == :machine and root in [:hklm, :hklm32])

  defp own_entry?(%{key: "MSI:" <> _}, _install), do: false
  defp own_entry?(%{root: :hkcu}, %{kind: :setup_exe}), do: true
  defp own_entry?(_entry, _install), do: false

  # `InstallLocation` when present; otherwise the directory of the
  # `Update.exe` in `UninstallString`, which is what Velopack would act on.
  defp location(%{values: values}) do
    case values["InstallLocation"] do
      loc when is_binary(loc) and loc != "" ->
        loc

      _ ->
        case Regex.run(~r/"([^"]+)\\Update\.exe"/i, to_string_value(values["UninstallString"])) do
          [_, dir] -> dir
          _ -> nil
        end
    end
  end

  defp to_string_value(v) when is_binary(v), do: v
  defp to_string_value(_), do: ""

  @doc """
  The running copy, from `RELEASE_ROOT`: `<install root>\\current` with
  Velopack's `Update.exe` beside it, or nil. `.msi-installed` in the install
  root is Velopack's own marker for an `.msi` install. A root the process
  cannot write to is a per-machine install.
  """
  @spec install_from_release_root(String.t() | nil) :: install() | nil
  def install_from_release_root(nil), do: nil

  def install_from_release_root(release_root) do
    expanded = Path.expand(release_root)
    root = Path.dirname(expanded)

    if String.downcase(Path.basename(expanded)) == "current" and
         File.exists?(Path.join(root, "Update.exe")) do
      %{
        root: root,
        kind: if(File.exists?(Path.join(root, ".msi-installed")), do: :msi, else: :setup_exe),
        scope: if(writable?(root), do: :user, else: :machine)
      }
    end
  end

  defp writable?(dir) do
    probe = Path.join(dir, ".openpairings-write-probe-#{System.unique_integer([:positive])}")

    case File.write(probe, "") do
      :ok ->
        File.rm(probe)
        true

      {:error, _} ->
        false
    end
  end

  @doc """
  Carries out `actions`. Returns the reports (nothing to change, or nothing
  this process may change) for the caller to show.
  """
  @spec apply_actions([action()], {module(), map()}) :: [{atom() | tuple(), entry()}]
  def apply_actions(actions, {store, roots}) do
    Enum.flat_map(actions, fn
      {:remove, entry, reason} ->
        case remove(entry, reason, {store, roots}) do
          :ok -> []
          {:error, why} -> [{{:could_not_remove, why}, entry}]
        end

      {:set_version, entry, version} ->
        _ = store.put(roots, entry.root, entry.key, %{"DisplayVersion" => version})
        []

      {:report, what, entry} ->
        [{what, entry}]
    end)
  end

  defp remove(%{root: :hkcu, key: key, values: values}, reason, {store, roots}) do
    backup =
      Map.merge(values, %{
        "OpenPairingsRemovedFrom" => roots.hkcu <> "\\" <> key,
        "OpenPairingsRemovedBecause" => Atom.to_string(reason),
        "OpenPairingsRemovedAt" =>
          DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      })

    # Backed up, read back, and only then deleted. See the moduledoc.
    with :ok <- store.put(roots, :backup, key, backup),
         {:ok, %{"OpenPairingsRemovedFrom" => _}} <- store.read(roots, :backup, key),
         :ok <- store.delete(roots, :hkcu, key) do
      Logger.warning(
        "Removed the #{inspect(key)} entry from Installed apps (#{reason}); " <>
          "its values are kept under #{roots.backup}\\#{key}."
      )

      :ok
    else
      other ->
        Logger.error("Could not remove the #{inspect(key)} uninstall entry: #{inspect(other)}")
        {:error, other}
    end
  end
end
