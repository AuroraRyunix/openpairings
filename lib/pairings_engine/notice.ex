defmodule PairingsEngine.Notice do
  @moduledoc """
  A plain message shown to everyone, for as long as it is set.

  This is the "we are pushing the new system tomorrow morning" notice: an
  announcement, not a countdown. It is deliberately NOT
  `PairingsEngine.Deploy`, and the differences are the whole reason it
  exists rather than being a parameter to that one.

  | | `Deploy` | this |
  |---|---|---|
  | says | a restart is coming | whatever you type |
  | horizon | minutes, capped at two hours | days |
  | survives a restart | no, on purpose | yes, on purpose |
  | escalates | three tiers, red at the end | never |
  | clears itself | five minutes after the deadline | at the time you set |

  ## Why this one is persisted, when `Deploy`'s is not

  `Deploy` argues, correctly, that a pending-restart deadline belongs in
  memory: it is true only of the node about to be restarted, so dying with
  that release is the feature, and a database row would be a stale banner
  waiting to happen.

  The opposite is true here. A notice about maintenance twelve hours out has
  to outlive anything that happens in those twelve hours, including the
  ordinary restarts, the crash-restarts, and the deploy of an unrelated fix.
  Holding it in memory would mean a notice that quietly disappears at the
  first hiccup - and nobody would notice it had, because an absent banner
  looks exactly like a banner that was never set.

  So it goes in `meta`, and `until` is what removes it rather than a timer.

  ## What it must not do

  **It must not imply a restart.** Nothing here mentions saving your work,
  losing unsaved changes, or being logged out, because none of those follow
  from a notice being on screen. `Deploy` says those things when they are
  actually about to be true. If this borrowed that language it would teach
  people to ignore both.
  """

  alias PairingsEngine.Repo

  @topic "system:notice"
  @key "site_notice"

  @doc "PubSub topic carrying `{:site_notice, notice | nil}`."
  def topic, do: @topic

  @doc """
  The current notice, or nil.

  Returns nil once `until` has passed, without needing anything to have
  cleaned up: an expired row and no row mean the same thing to every reader,
  so a server that was switched off across the expiry still does the right
  thing when it comes back.
  """
  def current(now \\ DateTime.utc_now()) do
    with value when is_binary(value) <- meta_get(@key),
         {:ok, %{"message" => message, "until" => until}} <- Jason.decode(value),
         {:ok, until, _} <- DateTime.from_iso8601(until),
         :lt <- DateTime.compare(now, until) do
      %{message: message, until: until}
    else
      _absent_or_expired -> nil
    end
  end

  @doc """
  Shows `message` until `until`.

  Replaces any notice already showing - there is one banner, so there is one
  notice, and a second announcement is a correction of the first rather than
  an addition to it.
  """
  def put(message, %DateTime{} = until) when is_binary(message) do
    message = String.trim(message)

    cond do
      message == "" ->
        {:error, "the message is empty"}

      DateTime.compare(until, DateTime.utc_now()) != :gt ->
        {:error, "that time has already passed"}

      true ->
        meta_put(@key, Jason.encode!(%{message: message, until: DateTime.to_iso8601(until)}))
        notice = %{message: message, until: until}
        broadcast(notice)
        {:ok, notice}
    end
  end

  @doc "Takes the notice down."
  def clear do
    meta_delete(@key)
    broadcast(nil)
    :ok
  end

  defp broadcast(notice) do
    Phoenix.PubSub.broadcast(PairingsEngine.PubSub, @topic, {:site_notice, notice})
  end

  defp meta_get(key) do
    case Repo.query!("SELECT value FROM meta WHERE key = ?", [key]).rows do
      [[value]] -> value
      _ -> nil
    end
  end

  defp meta_put(key, value) do
    Repo.query!(
      "INSERT INTO meta (key, value) VALUES (?, ?) " <>
        "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
      [key, value]
    )

    :ok
  end

  defp meta_delete(key) do
    Repo.query!("DELETE FROM meta WHERE key = ?", [key])
    :ok
  end
end
