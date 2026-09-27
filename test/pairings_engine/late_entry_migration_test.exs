defmodule PairingsEngine.LateEntryMigrationTest do
  @moduledoc """
  Which existing tournaments the late-entry migration leaves with the old
  count (`20260927160644_add_late_entry_absences.exs`): the finished and the
  archived ones, whose final standings must not move on an upgrade. Runs
  the migration's own statement, not a copy of it.
  """
  use PairingsEngine.DataCase, async: false

  alias PairingsEngine.Repo
  alias PairingsEngine.Tournaments.Tournament

  @migration "priv/repo/migrations/20260927160644_add_late_entry_absences.exs"
  @migration_module PairingsEngine.Repo.Migrations.AddLateEntryAbsences

  setup_all do
    unless Code.ensure_loaded?(@migration_module) do
      Code.require_file(@migration)
    end

    :ok
  end

  defp tournament(attrs),
    do: Repo.insert!(struct(%Tournament{name: "Old", type: "swiss", rounds_count: 5}, attrs))

  test "finished and archived tournaments keep the old count; the rest get the new one" do
    finished = tournament(%{status: "finished"})
    archived = tournament(%{status: "running", archived_at: ~U[2026-09-01 10:00:00Z]})
    running = tournament(%{status: "running"})
    setup = tournament(%{status: "setup"})

    Repo.query!(apply(@migration_module, :finished_off_sql, []))

    on? = &Repo.reload!(&1).late_entry_absences
    refute on?.(finished)
    refute on?.(archived)
    assert on?.(running)
    assert on?.(setup)
  end

  test "a backup written before the setting existed gets the same answer on import" do
    user =
      Repo.insert!(%PairingsEngine.Accounts.User{
        email: "user#{System.unique_integer([:positive])}@example.com",
        confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

    scope = PairingsEngine.Accounts.Scope.for_user(user)

    entry = fn attrs ->
      %{
        "tournament" =>
          Map.merge(%{"name" => "Backup", "type" => "swiss", "rounds_count" => 5}, attrs),
        "players" => [%{"id" => 1, "name" => "A"}]
      }
    end

    payload = %{
      "format" => "openpairings-export",
      "version" => 1,
      "tournaments" => [
        entry.(%{"status" => "finished"}),
        entry.(%{"status" => "running"}),
        entry.(%{"status" => "finished", "late_entry_absences" => true})
      ]
    }

    assert {:ok, [finished, running, chosen]} =
             PairingsEngine.TournamentImport.import(payload, scope)

    refute Repo.reload!(finished).late_entry_absences
    assert Repo.reload!(running).late_entry_absences
    assert Repo.reload!(chosen).late_entry_absences
  end
end
