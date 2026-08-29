defmodule PairingsEngineWeb.BackupDownloadTest do
  @moduledoc """
  Getting a backup off the machine it protects.

  Backups are written beside the database. That survives a bad migration, an
  accidental delete and a botched restore - most of what goes wrong - and it
  does not survive the disk. Copying one somewhere else needs a destination
  this app has no business holding credentials for, so what it does instead is
  hand the file over.

  Two things are being tested, and the second is the one that matters:

    * a backup is the whole database, so only an administrator may take it -
      and signing in through 02cloud SSO is explicitly NOT enough, which is
      the change of 2026-08-29 and the thing most worth pinning here;
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

  defp admin_conn(conn) do
    user = PairingsEngine.AccountsFixtures.user_fixture()
    {:ok, admin} = Accounts.set_role(user.email, "admin")
    log_in_user(conn, admin)
  end

  defp local_mode(on?) do
    previous = Application.get_env(:pairings_engine, :local_mode)
    Application.put_env(:pairings_engine, :local_mode, on?)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:pairings_engine, :local_mode)
        value -> Application.put_env(:pairings_engine, :local_mode, value)
      end
    end)
  end

  describe "who may download one" do
    test "an administrator gets the file", %{conn: conn, name: name} do
      conn = conn |> admin_conn() |> get(~p"/backups/#{name}")

      assert conn.status == 200
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ name
      assert byte_size(conn.resp_body) > 0
    end

    test "an SSO account without the role does not", %{conn: conn, name: name} do
      # The point of the role. Everyone in a federated directory is SSO;
      # almost none of them should be able to walk off with every
      # tournament, every player, the entry form's email addresses and
      # every publishing key. "How you signed in" was never the same
      # question as "what may you do", and this is where they part.
      conn = conn |> sso_conn() |> get(~p"/backups/#{name}")

      assert conn.status == 403
    end

    test "an ordinary signed-in account does not", %{conn: conn, name: name} do
      conn = get(conn, ~p"/backups/#{name}")

      assert conn.status == 403
    end

    test "a local run needs no role at all", %{conn: conn, name: name} do
      # There is nobody to gate against: the listener is pinned to loopback,
      # the auto-sign-in re-checks the connection came from this machine,
      # and the file being downloaded is sitting beside a database the
      # person asking can simply open. A gate here would lock an arbiter out
      # of their own backups and protect nothing.
      local_mode(true)

      conn = get(conn, ~p"/backups/#{name}")

      assert conn.status == 200
    end
  end

  describe "the file name" do
    test "a traversal is refused, not resolved", %{conn: conn} do
      for attempt <- [
            "../../../../etc/passwd",
            "..%2F..%2Fpairings_engine_dev.db",
            "....//....//mix.exs"
          ] do
        conn = conn |> admin_conn() |> get("/backups/#{attempt}")

        assert conn.status in [400, 403, 404],
               "#{attempt} answered #{conn.status}"

        refute conn.resp_body =~ "root:"
        refute conn.resp_body =~ "defmodule"
      end
    end

    test "a name that is not a backup on this machine is a 404", %{conn: conn} do
      conn = conn |> admin_conn() |> get(~p"/backups/openpairings-2020-01-01T00-00-00Z.opbak")

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
      conn = conn |> admin_conn() |> get(~p"/backups/#{name}")

      assert conn.resp_body == on_disk
    end
  end
end
