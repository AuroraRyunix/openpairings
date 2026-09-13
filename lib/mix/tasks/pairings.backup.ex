defmodule Mix.Tasks.Pairings.Backup do
  @shortdoc "Write a backup now, list them, verify one, or recover one"

  @moduledoc """
  Backups, from the command line.

      mix pairings.backup              # write one now
      mix pairings.backup --list       # what is on disk
      mix pairings.backup --verify F   # open F, read every page, say what is in it
      mix pairings.backup --restore F  # recover F beside the live database

  The scheduler writes one a day by itself; this is for taking one before a
  risky change, and for the half that matters - getting the data back.

  `F` is a path, or a name exactly as `--list` prints it: the drill of
  2026-09-13 typed the listed name back in and got "no such file".

  `--restore` deliberately does not swap the live file. A SQLite database
  cannot be replaced underneath an open connection pool without risking the
  very thing being recovered, so it writes the recovered copy beside it and
  prints the swap, the migration and the start with this machine's paths -
  steps 4 to 8 of `docs/deployment.md`, "Restoring a backup". What to
  re-apply afterwards is in the same guide.
  """
  use Mix.Task

  alias PairingsEngine.Backup

  @requirements ["app.config"]

  # `app.config` and nothing more. The backup opens its own SQLite connection
  # rather than going through the Repo, so it needs configuration and not a
  # running application - and starting one here would put a second web endpoint
  # up against the port the live service is already bound to.
  @impl Mix.Task
  def run(argv) do
    case argv do
      ["--list"] -> list()
      ["--verify", path] -> verify(resolve(path))
      ["--restore", path] -> restore(resolve(path))
      [] -> create()
      _ -> Mix.raise("usage: mix pairings.backup [--list | --verify FILE | --restore FILE]")
    end
  end

  # A path that exists is taken as given. Otherwise a bare name that matches a
  # backup in the backup directory is that backup - which is what `--list`
  # shows, so its output can be pasted back in.
  @doc false
  def resolve(path) do
    cond do
      File.exists?(path) ->
        path

      Path.basename(path) == path ->
        case Enum.find(Backup.list(), &(Path.basename(&1.path) == path)) do
          %{path: found} -> found
          nil -> path
        end

      true ->
        path
    end
  end

  defp create do
    case Backup.create() do
      {:ok, path} ->
        size = File.stat!(path).size

        Mix.shell().info([
          :green,
          "Wrote ",
          :reset,
          path,
          " (#{human(size)}#{if Backup.encrypted?(), do: ", encrypted", else: ""})"
        ])

        case Backup.prune() do
          0 -> :ok
          n -> Mix.shell().info("Removed #{n} older backup(s), keeping #{Backup.retention()}.")
        end

      {:error, reason} ->
        Mix.raise("Backup failed: " <> reason)
    end
  end

  defp list do
    case Backup.list() do
      [] ->
        Mix.shell().info("No backups in #{Backup.directory()}.")

      backups ->
        Mix.shell().info("#{length(backups)} in #{Backup.directory()}, newest first:\n")

        for b <- backups do
          Mix.shell().info(
            "  #{DateTime.to_string(b.created_at)}  #{String.pad_leading(human(b.size), 9)}" <>
              "#{if b.encrypted, do: "  encrypted", else: ""}  #{Path.basename(b.path)}"
          )
        end
    end
  end

  defp verify(path) do
    case Backup.verify(path) do
      {:ok, info} ->
        Mix.shell().info([:green, "Readable. ", :reset, describe(info)])

      {:error, reason} ->
        Mix.raise(reason)
    end
  end

  defp restore(path) do
    case Backup.restore(path) do
      {:ok, target} ->
        Mix.shell().info([:green, "Recovered to ", :reset, target, "\n"])
        Mix.shell().info(swap_instructions(target, live()))

      {:error, reason} ->
        Mix.raise(reason)
    end
  end

  @doc false
  # The rest of the procedure, with this machine's real paths in it. Each line
  # is there because the 2026-09-13 drill broke without it - see
  # docs/restore-drill-2026-09-13.md. It used to print two `mv`s that moved
  # the database without its `-wal`: after a crash or a kill, SQLite then read
  # the OLD database back through the restored file's name.
  #
  # Only the indented lines are commands, and `PairingsEngine.BackupSwapTest`
  # runs exactly those, so keep prose unindented.
  def swap_instructions(target, live, app_dir \\ File.cwd!()) do
    dir = Path.dirname(live)
    name = Path.basename(live)

    """
    The live database has NOT been touched. The rest, as root. Read "What a
    restore undoes" in docs/deployment.md before you start the service again.

      systemctl stop pairingsengine
      systemctl is-active pairingsengine               # must print: inactive

      cd "#{dir}"
      stamp=$(date -u +%Y%m%dT%H%M%SZ)
      # The -wal and -shm files move WITH the database. Left beside the
      # restored file, SQLite reads them into it and old data comes back.
      for f in #{name} #{name}-wal #{name}-shm; do
        [ -e "$f" ] && mv "$f" "${f/#{name}/#{name}.before-restore-$stamp}"
      done
      mv #{Path.basename(target)} #{name}
      chown --reference=. #{name}

      # Migrate, as the service account, with the unit's environment. A backup
      # older than the code boots and then fails every tournament page:
      # phx.server does not migrate.
      unit=/etc/systemd/system/pairingsengine.service
      for k in MIX_ENV DATABASE_PATH SECRET_KEY_BASE MIX_HOME HEX_HOME PATH PORT; do
        v=$(cat "$unit" "$unit".d/*.conf 2>/dev/null | sed -n "s|^Environment=\\"$k=\\(.*\\)\\"\\$|\\1|p" | tail -1)
        [ -n "$v" ] && export "$k=$v"
      done
      (cd "#{app_dir}" && runuser --preserve-environment -u "$(stat -c %U "#{dir}")" -- mix ecto.migrate)

      systemctl start pairingsengine
      curl -s -o /dev/null -w '%{http_code}\\n' "http://127.0.0.1:${PORT:-4001}/"   # expect 302

    Keep the .before-restore-* files until you are sure: they hold everything
    written after the backup.
    """
  end

  defp live, do: Application.get_env(:pairings_engine, PairingsEngine.Repo)[:database]

  defp human(bytes) when bytes > 1_000_000, do: "#{Float.round(bytes / 1_000_000, 1)} MB"
  defp human(bytes) when bytes > 1_000, do: "#{div(bytes, 1_000)} kB"
  defp human(bytes), do: "#{bytes} B"

  defp describe(info), do: "#{info.tournaments} tournament(s), #{length(info.tables)} tables."
end
