defmodule PairingsEngine.BusyWrite do
  @moduledoc """
  Turns "the database was locked" from a crash into an answer.

  SQLite allows exactly one writer at a time, database-wide - not per table.
  While one transaction holds the write lock every other write waits, and
  after `busy_timeout` (15s, see `config/runtime.exs`) it gives up with
  `database is locked`.

  That failure arrives as a raised exception, not as `{:error, changeset}`,
  so it sails straight past the `case` that every write path in the web layer
  wraps its call in, kills the LiveView, and shows the person a generic
  "something went wrong" while the screen resets. An arbiter entering a
  result sees the click do nothing and has no idea whether it saved.

  It did not save - a raise means the write never happened, and the remount
  re-reads from the database, so nothing is silently lost. But "nothing was
  lost" is only reassuring to somebody who knows that, and the arbiter
  standing in front of a room does not.

  So this converts it to `{:error, :database_busy}`, which the existing
  error branches already know how to render: a flash that says plainly the
  result was NOT saved, and a refresh that shows what is actually stored.

  ## Why there is no retry loop here

  The obvious reflex is to retry. It is wrong: `busy_timeout` already means
  SQLite spent 15 seconds retrying internally before raising, so a loop of
  six attempts is a 90-second freeze rather than six quick tries. Waiting
  longer is not the fix - not holding the lock that long is (see
  `PairingsEngine.Fide.Sync`, which is the only thing in the application
  that ever holds it for more than milliseconds).
  """

  require Logger

  @doc """
  Runs `fun`, converting a SQLite lock timeout into `{:error, :database_busy}`.

  Anything else raised is re-raised untouched: a lock is a condition to
  report, but a bug is still a bug and must not be swallowed into a flash
  message that blames the database.
  """
  def run(fun) when is_function(fun, 0) do
    fun.()
  rescue
    error ->
      if locked?(error) do
        Logger.warning("write refused, database locked: #{Exception.message(error)}")
        {:error, :database_busy}
      else
        reraise(error, __STACKTRACE__)
      end
  end

  # Matched on the message rather than the struct: exqlite reports this as a
  # plain string from SQLite itself, and which exception wraps it depends on
  # whether the pool or the adapter noticed first.
  defp locked?(error) do
    message = error |> Exception.message() |> String.downcase()

    String.contains?(message, "database is locked") or
      String.contains?(message, "database table is locked") or
      String.contains?(message, "sqlite_busy")
  end
end
