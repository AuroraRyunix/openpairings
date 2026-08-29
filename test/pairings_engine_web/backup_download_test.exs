defmodule PairingsEngineWeb.BackupDownloadTest do
  @moduledoc """
  Getting a backup off the machine it protects.

  Backups are written beside the database. That survives a bad migration, an
  accidental delete and a botched restore - most of what goes wrong - and it
  does not survive the disk. Copying one somewhere else needs a destination
  this app has no business holding credentials for, so what it does instead is
  hand the file over.

  Two things are being tested, and the second is the one that matters:

    * a backup is the whole database, so only an 02cloud account may take it;
    * the file name in the URL is matched against what is on disk, never
      joined onto a directory - a name reaching `Path.join/2` unchecked is a
      traversal into anything the application can read, and being behind a
      login is not an answer, because the login is what an attacker who is
      already inside has.
  """
  use PairingsEngineWeb.ConnCase, async: false

  alias PairingsEngine.{Accounts, Backup}

  setup :register_and_log_in_user

  setup do
    dir = Path.join(System.tmp_dir!(), "opbak-dl-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:pairings_engine, :backup_dir, dir)

    on_exit(fn ->
      Application.delete_env(:pairings_engine, :backup_dir)
      File.rm_rf(dir)
    end)

    {:ok, dir} = {:ok, dir}
    {:ok, path} = Backup.create(dir: dir)

    {:ok, dir: dir, name: Path.basename(path)}
  end

  defp sso_conn(conn) do
    {:ok, user} =
      Accounts.find_or_create_from_keycloak(%{
        sub: "sso-sub-#{System.unique_integer()}",
        email: "sso-user-#{System.unique_integer()}@example.com"
      })

    log_in_user(conn, user)
  end

  describe "who may download one" do
    test "an 02cloud account gets the file", %{conn: conn, name: name} do
      conn = conn |> sso_conn() |> get(~p"/backups/#{name}")

      assert conn.status == 200
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ name
      assert byte_size(conn.resp_body) > 0
    end

    test "an ordinary signed-in account does not", %{conn: conn, name: name} do
      # A backup is every tournament, every player, the entry form's email
      # addresses and every publishing key. A self-registered user taking all
      # of that is not a smaller problem than one repointing where it
      # publishes, which is gated the same way.
      conn = get(conn, ~p"/backups/#{name}")

      assert conn.status == 403
    end
  end

  describe "the file name" do
    test "a traversal is refused, not resolved", %{conn: conn} do
      for attempt <- [
            "../../../../etc/passwd",
            "..%2F..%2Fpairings_engine_dev.db",
            "....//....//mix.exs"
          ] do
        conn = conn |> sso_conn() |> get("/backups/#{attempt}")

        assert conn.status in [400, 403, 404],
               "#{attempt} answered #{conn.status}"

        refute conn.resp_body =~ "root:"
        refute conn.resp_body =~ "defmodule"
      end
    end

    test "a name that is not a backup on this machine is a 404", %{conn: conn} do
      conn = conn |> sso_conn() |> get(~p"/backups/openpairings-2020-01-01T00-00-00Z.opbak")

      assert conn.status == 404
    end

    test "and the served file is the one recorded, not one built from the URL", %{
      conn: conn,
      dir: dir,
      name: name
    } do
      # The defence is a lookup rather than a sanitiser, because a lookup
      # cannot be outwitted by an encoding somebody thinks of later.
      on_disk = File.read!(Path.join(dir, name))
      conn = conn |> sso_conn() |> get(~p"/backups/#{name}")

      assert conn.resp_body == on_disk
    end
  end
end
