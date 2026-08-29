defmodule PairingsEngineWeb.BackupControllerTest do
  use PairingsEngineWeb.ConnCase

  alias PairingsEngine.{Accounts, Audit, Backup}

  setup :register_and_log_in_user

  defp live_database, do: Application.get_env(:pairings_engine, PairingsEngine.Repo)[:database]

  # Mirrors `PairingsEngine.BackupTest`'s `source/2`: `VACUUM INTO` a
  # throwaway file-level snapshot of the live test database, rather than
  # touching the sandboxed connection's own uncommitted transaction.
  defp put_one_backup(dir) do
    source_path = Path.join(dir, "source-#{System.unique_integer([:positive])}.db")
    {:ok, conn} = Exqlite.Sqlite3.open(live_database())
    :ok = Exqlite.Sqlite3.execute(conn, "VACUUM INTO '#{source_path}'")
    :ok = Exqlite.Sqlite3.close(conn)

    {:ok, path} = Backup.create(dir: dir, source: source_path)
    Path.basename(path)
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "opbak-ctrl-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:pairings_engine, :backup_dir, dir)

    on_exit(fn ->
      Application.delete_env(:pairings_engine, :backup_dir)
      File.rm_rf(dir)
    end)

    {:ok, dir: dir}
  end

  defp admin_conn(conn, user) do
    {:ok, admin} = Accounts.set_role(user.email, "admin")
    {log_in_user(conn, admin), admin}
  end

  describe "GET /backups/:name" do
    test "a non-administrator is refused, and nothing is logged", %{conn: conn, dir: dir} do
      name = put_one_backup(dir)

      conn = get(conn, ~p"/backups/#{name}")

      assert conn.status == 403
      assert conn.resp_body =~ "administrator"
      assert Audit.list_machine_wide() == []
    end

    test "an administrator can download a backup, and it is durably logged", %{
      conn: conn,
      user: user,
      dir: dir
    } do
      name = put_one_backup(dir)
      {conn, admin} = admin_conn(conn, user)

      conn = get(conn, ~p"/backups/#{name}")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
      assert conn.resp_body != ""

      assert [row] = Audit.list_machine_wide()
      assert row.action == "backup.downloaded"
      assert row.tournament_id == nil
      assert row.user_id == admin.id
      assert row.details["filename"] == name
    end

    test "a name not on disk 404s, and nothing is logged", %{conn: conn, user: user} do
      # The backup dir from setup exists but holds nothing, so this name is
      # not a traversal attempt succeeding - it is simply not among what
      # `Backup.list/0` finds, which is the whole of the defence (see the
      # controller's moduledoc).
      {conn, _admin} = admin_conn(conn, user)

      conn = get(conn, ~p"/backups/does-not-exist.opbak")

      assert conn.status == 404
      assert Audit.list_machine_wide() == []
    end
  end
end
