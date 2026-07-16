defmodule PairingsEngine.Audit do
  @moduledoc """
  The tournament audit trail: an exhaustive, append-only record of every
  state-changing action taken on a tournament (who did what, when, and a
  structured `details` payload rich enough to reconstruct the change without
  cross-referencing other tables).

  ## Where writes come from

  By design (see the project's audit-trail spec), `log/4` is called directly
  from each LiveView `handle_event` clause, immediately after the underlying
  `PairingsEngine.Tournaments` (or `PairingsEngine.Pairing`, ...) context
  call succeeds — *not* threaded as a `user_id`/scope parameter through the
  context functions themselves. Every LiveView handler already has the acting
  user in `socket.assigns.current_scope` and already knows exactly which
  user-facing action just happened, so the audit call sites sit right next to
  the events they describe and the context layer stays untouched.

  Writing an audit row never broadcasts on the tournament PubSub topic — this
  is a background bookkeeping write, and the audit page reloads on its own
  navigation/refresh rather than needing live push. Keeping it off the topic
  also avoids feedback loops with the very `broadcast_tournament_change/2`
  events these actions already emit.
  """

  import Ecto.Query
  alias PairingsEngine.Repo
  alias PairingsEngine.Accounts.Scope
  alias PairingsEngine.Audit.AuditLog

  @doc """
  Records one audit-trail row for `tournament_id`.

  The second argument is the acting user: a `PairingsEngine.Accounts.Scope`
  (the common LiveView case — the user id is pulled out for you), a plain
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

  defp do_log(tournament_id, user_id, action, details) do
    %AuditLog{}
    |> AuditLog.changeset(%{
      tournament_id: tournament_id,
      user_id: user_id,
      action: to_string(action),
      details: normalize_details(details)
    })
    |> Repo.insert()
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

    * `:limit` — max rows to return (default 100 — a long-running tournament's
      log can grow large, so this is never unbounded).
    * `:offset` — rows to skip, for simple pagination.
    * `:action` — exact action code to filter by (e.g. `"pairing.round_paired"`).
    * `:actions` — a list of action codes to filter by (the audit page's
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
