defmodule PairingsEngineWeb.BackupController do
  @moduledoc """
  Downloading a backup, so it can leave the machine it protects.

  ## Why this route exists

  `PairingsEngine.Backup` writes to a directory beside the database. That
  survives a bad migration, an accidental delete and a botched restore, which
  is most of what actually goes wrong - and it does not survive the disk, the
  machine, or the building. A backup stored only on the thing it is insuring
  is half a backup.

  Copying it somewhere else needs a destination this app has no business
  holding credentials for. What it can do is hand the file over, so an arbiter
  or an operator can put it wherever they keep such things.

  ## Why it is SSO-only

  A backup is the whole database. It carries every tournament, every player,
  and the one piece of personal data in the system - the email addresses
  people gave the entry form - plus every OpenResults publishing key, which is
  what decides who may withdraw a published tournament.

  So this is gated exactly as changing the publishing settings is: an
  02cloud account, not merely a signed-in one. A self-registered user
  downloading the entire database is not a smaller problem than a
  self-registered user repointing where it publishes.

  ## Why the filename is not taken from the URL

  The parameter is matched against the backups actually on disk and the file
  is served by its own recorded path. A name that reached `Path.join/2`
  unchecked would be a directory traversal into anything the application can
  read, and "it is behind a login" is not an answer to that - the login is
  the thing an attacker who is already inside has.
  """
  use PairingsEngineWeb, :controller

  alias PairingsEngine.Accounts.User
  alias PairingsEngine.Backup

  require Logger

  @doc """
  `GET /backups/:name` - downloads one backup by file name.
  """
  def download(conn, %{"name" => name}) do
    cond do
      not User.sso?(conn.assigns.current_scope.user) ->
        refuse(conn, :forbidden, "Only an 02cloud account can download a backup.")

      backup = find(name) ->
        Logger.info("Backup downloaded: #{Path.basename(backup.path)}")

        conn
        |> put_resp_content_type("application/octet-stream")
        |> send_download({:file, backup.path}, filename: Path.basename(backup.path))

      true ->
        refuse(conn, :not_found, "No such backup.")
    end
  end

  # Matched against what is on disk rather than joined onto a directory. See
  # the moduledoc: this is the whole of the traversal defence, and it is a
  # lookup rather than a sanitiser because a lookup cannot be outwitted by an
  # encoding somebody thought of later.
  defp find(name), do: Enum.find(Backup.list(), &(Path.basename(&1.path) == name))

  defp refuse(conn, status, message) do
    conn
    |> put_status(status)
    |> put_view(html: PairingsEngineWeb.ErrorHTML)
    |> text(message)
  end
end
