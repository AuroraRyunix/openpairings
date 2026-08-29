defmodule PairingsEngine.Audit do
  @moduledoc """
  The audit trail: an exhaustive, append-only record of every state-changing
  action this app takes, who did it, when, and a structured `details`
  payload rich enough to reconstruct the change without cross-referencing
  other tables.

  Most rows are about one tournament, written with `log/4`. A smaller set of
  acts - granting or revoking a role, downloading a backup, repointing the
  publishing connection or replacing its token, starting a rating-list sync -
  are about the installation itself and have no tournament to name; those go
  through `log_system/3` instead, which stores `tournament_id: nil`. Both
  write the same table and render through the same
  `PairingsEngineWeb.AuditLive.describe/1`; see that nullable column's
  migration for why one table holds both kinds of row rather than two.

  ## Where writes come from

  By design (see the project's audit-trail spec), `log/4` and `log_system/3`
  are called directly from each LiveView `handle_event` clause (or
  controller action, for `log_system/3`'s two non-LiveView callers),
  immediately after the underlying context call succeeds - *not* threaded as
  a `user_id`/scope parameter through the context functions themselves.
  Every call site already has the acting user in `current_scope` and already
  knows exactly which user-facing action just happened, so the audit call
  sites sit right next to the events they describe and the context layer
  stays untouched.

  Writing an audit row never broadcasts on the tournament PubSub topic - this
  is a background bookkeeping write, and the audit page reloads on its own
  navigation/refresh rather than needing live push. Keeping it off the topic
  also avoids feedback loops with the very `broadcast_tournament_change/2`
  events these actions already emit.

  ## Never a secret

  `details` is a JSON column an administrator can read on screen. A
  publishing token or an `ADMIN_EMAILS` value is never put in it - "the
  token was replaced" is the record; the token itself is not. Only the
  writer at each call site can enforce that, so keep it in mind whenever a
  new `log_system/3` call site is added.
  """

  import Ecto.Query
  require Logger
  alias PairingsEngine.Repo
  alias PairingsEngine.Accounts.Scope
  alias PairingsEngine.Audit.AuditLog

  @doc """
  Records one audit-trail row for `tournament_id`.

  The second argument is the acting user: a `PairingsEngine.Accounts.Scope`
  (the common LiveView case - the user id is pulled out for you), a plain
  integer `user_id`, or `nil` for a system/no-auth write (rendered as
  "System").

  `action` is a dot-namespaced code (see the module doc and
  `PairingsEngineWeb.AuditLive`), `details` a freeform map specific to that
  action. Returns `{:ok, %AuditLog{}}` or `{:error, changeset}`; callers
  generally fire-and-forget (an audit write must never break the user-facing
  action it records), so a failure here is logged, not raised.
  """
  def log(tournament_id, user, action, details \\ %{})

  def log(tournament_id, %Scope{user: %{id: user_id}}, action, details),
    do: do_log(tournament_id, user_id, action, details)

  def log(tournament_id, %Scope{}, action, details),
    do: do_log(tournament_id, nil, action, details)

  def log(tournament_id, user_id, action, details)
      when is_integer(user_id) or is_nil(user_id),
      do: do_log(tournament_id, user_id, action, details)

  @doc """
  Records one audit-trail row for a machine-wide act - one with no single
  tournament to attribute it to (a role change, a backup download, the
  publishing connection, a rating-list sync). Stores `tournament_id: nil`.

  Same acting-user argument, same `action`/`details` shape, same
  fire-and-forget failure handling as `log/4` - see its doc. The two exist
  separately only because the first argument differs (a tournament to name,
  or none); everything after that is shared.
  """
  def log_system(user, action, details \\ %{})

  def log_system(%Scope{user: %{id: user_id}}, action, details),
    do: do_log(nil, user_id, action, details)

  def log_system(%Scope{}, action, details),
    do: do_log(nil, nil, action, details)

  def log_system(user_id, action, details)
      when is_integer(user_id) or is_nil(user_id),
      do: do_log(nil, user_id, action, details)

  defp do_log(tournament_id, user_id, action, details) do
    result =
      %AuditLog{}
      |> AuditLog.changeset(%{
        tournament_id: tournament_id,
        user_id: user_id,
        action: to_string(action),
        details: normalize_details(details)
      })
      |> Repo.insert()

    case result do
      {:ok, _} = ok ->
        ok

      {:error, changeset} = error ->
        Logger.error(
          "Audit.log failed for tournament #{tournament_id} action #{action}: #{inspect(changeset.errors)}"
        )

        error
    end
  end

  # `details` maps are persisted to a JSON column, so any tuples (e.g. a
  # `{before, after}` changed-field pair) must be turned into JSON-friendly
  # lists first, recursively, before insert.
  defp normalize_details(details) when is_map(details) and not is_struct(details) do
    Map.new(details, fn {k, v} -> {k, normalize_details(v)} end)
  end

  defp normalize_details(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> normalize_details()

  defp normalize_details(value) when is_list(value), do: Enum.map(value, &normalize_details/1)
  defp normalize_details(%Date{} = d), do: Date.to_iso8601(d)
  defp normalize_details(%DateTime{} = d), do: DateTime.to_iso8601(d)
  defp normalize_details(value), do: value

  @doc """
  Lists audit rows for `tournament_id`, newest first, with the acting `:user`
  association preloaded.

  Options:

    * `:limit` - max rows to return (default 100 - a long-running tournament's
      log can grow large, so this is never unbounded).
    * `:offset` - rows to skip, for simple pagination.
    * `:action` - exact action code to filter by (e.g. `"pairing.round_paired"`).
    * `:actions` - a list of action codes to filter by (the audit page's
      category buckets pass the whole set of codes in a category).
  """
  def list_for_tournament(tournament_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)

    query =
      from a in AuditLog,
        where: a.tournament_id == ^tournament_id,
        order_by: [desc: a.inserted_at, desc: a.id],
        limit: ^limit,
        offset: ^offset,
        preload: [:user]

    query
    |> filter_action(Keyword.get(opts, :action))
    |> filter_actions(Keyword.get(opts, :actions))
    |> Repo.all()
  end

  @doc """
  Lists machine-wide audit rows (`tournament_id IS NULL`) - a role change, a
  backup download, the publishing connection, a rating-list sync - newest
  first, with the acting `:user` preloaded. Same `:limit`/`:offset` options
  as `list_for_tournament/2`; no category filter, since the Admin page
  shows these unfiltered.

  Deliberately a separate query rather than `list_for_tournament(nil, ...)`:
  `WHERE tournament_id = NULL` is never true in SQL, so that call would
  silently return nothing instead of the machine-wide rows - `IS NULL` is a
  different operator, not a different value of the same one.
  """
  def list_machine_wide(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)

    from(a in AuditLog,
      where: is_nil(a.tournament_id),
      order_by: [desc: a.inserted_at, desc: a.id],
      limit: ^limit,
      offset: ^offset,
      preload: [:user]
    )
    |> Repo.all()
  end

  defp filter_action(query, nil), do: query
  defp filter_action(query, action), do: from(a in query, where: a.action == ^action)

  defp filter_actions(query, nil), do: query
  defp filter_actions(query, []), do: query
  defp filter_actions(query, actions), do: from(a in query, where: a.action in ^actions)

  @doc "Total number of audit rows for `tournament_id` (optionally filtered by `:actions`)."
  def count_for_tournament(tournament_id, opts \\ []) do
    query = from a in AuditLog, where: a.tournament_id == ^tournament_id

    query
    |> filter_actions(Keyword.get(opts, :actions))
    |> Repo.aggregate(:count)
  end
end
