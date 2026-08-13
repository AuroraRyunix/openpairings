defmodule PairingsEngine.Snapshots do
  @moduledoc """
  Point-in-time copies of a whole tournament, taken automatically just before
  an action that is hard or impossible to undo by hand.

  ## What's in one

  The payload is a `PairingsEngine.TournamentExport` envelope — byte-identical
  to what the "Export full backup (JSON)" button produces. Reusing that
  serializer (rather than writing a second one) means snapshots inherit its
  round-trip tests and can't drift from it, and the restore path is a variant
  of `PairingsEngine.TournamentImport` rather than a parallel implementation.

  It follows that snapshots inherit the export's deliberate exclusions, and
  that's the behaviour we want here too:

    * **Sharing state is not captured** (`public_pages_enabled`,
      `registration_open`, `public_slug`). Rolling back to an earlier state
      must never silently re-publish a tournament whose public link was taken
      down, or hand out a slug that was rotated away after a leak.
    * **Ownership and lifecycle are not captured** (`user_id`, `deleted_at`,
      `archived_at`). A restore changes a tournament's *contents*, never who
      owns it or whether it's archived.
    * The logo is a known gap, same as the export's.

  ## Where they're taken

  From the LiveView handler, immediately *before* the risky context call —
  the same call-site convention `PairingsEngine.Audit` uses and for the same
  reason (the handler knows exactly which user-facing action is about to
  happen). `capture/4` is deliberately fire-and-forget: a snapshot failing
  must never block the action it was trying to protect.

  ## Retention

  `@keep_per_tournament` most recent snapshots per tournament, pruned on
  every capture. These are full tournament copies, so they'd otherwise grow
  without bound on a long-running event.
  """

  import Ecto.Query
  require Logger

  alias PairingsEngine.{Repo, TournamentExport, TournamentImport, Tournaments}
  alias PairingsEngine.Accounts.Scope
  alias PairingsEngine.Snapshots.Snapshot
  alias PairingsEngine.Tournaments.{Player, Round, Team, Tournament}

  @keep_per_tournament 50

  @doc "How many snapshots are kept per tournament before the oldest are pruned."
  def keep_per_tournament, do: @keep_per_tournament

  @doc """
  Captures `tournament`'s current state, tagged with `trigger` (an action code
  in the same dot-namespaced style as the audit log) and an optional
  human-readable `summary`.

  Fire-and-forget by design: returns `{:ok, snapshot}` or `{:error, reason}`,
  but callers are expected to ignore the result. A snapshot that fails to
  write is logged and must never break the user-facing action it was taken to
  protect — losing the ability to roll back is bad, refusing to pair a round
  because the safety net failed is worse.
  """
  @spec capture(Tournament.t(), String.t(), Scope.t() | integer() | nil, keyword()) ::
          {:ok, Snapshot.t()} | {:error, term()}
  def capture(tournament, trigger, actor \\ nil, opts \\ [])

  def capture(%Tournament{} = tournament, trigger, actor, opts) do
    result =
      %Snapshot{}
      |> Snapshot.changeset(%{
        tournament_id: tournament.id,
        user_id: user_id(actor),
        trigger: to_string(trigger),
        summary: Keyword.get(opts, :summary),
        pinned: Keyword.get(opts, :pinned, false),
        payload: TournamentExport.export_tournament(tournament)
      })
      |> Repo.insert()

    case result do
      {:ok, snapshot} ->
        prune(tournament.id)
        {:ok, snapshot}

      {:error, changeset} ->
        Logger.error(
          "Snapshots.capture failed for tournament #{tournament.id} " <>
            "trigger #{trigger}: #{inspect(changeset.errors)}"
        )

        {:error, changeset}
    end
  end

  defp user_id(%Scope{user: %{id: id}}), do: id
  defp user_id(%Scope{}), do: nil
  defp user_id(id) when is_integer(id), do: id
  defp user_id(nil), do: nil

  @doc """
  Lists `tournament_id`'s snapshots, newest first, with the acting `:user`
  preloaded. The `payload` is excluded — it's a full tournament copy, far too
  heavy to load for a list view. Use `get/2` to fetch one with its payload.
  """
  @spec list(integer(), keyword()) :: [Snapshot.t()]
  def list(tournament_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, @keep_per_tournament)

    Repo.all(
      from s in Snapshot,
        where: s.tournament_id == ^tournament_id,
        order_by: [desc: s.inserted_at, desc: s.id],
        limit: ^limit,
        preload: [:user],
        select: %{s | payload: nil}
    )
  end

  @doc """
  Fetches one snapshot *with* its payload, scoped to `tournament_id` so a
  crafted id can't reach another tournament's snapshot. Returns `nil` if it
  doesn't exist or belongs elsewhere.
  """
  @spec get(integer(), integer() | String.t()) :: Snapshot.t() | nil
  def get(tournament_id, id) do
    Repo.one(
      from s in Snapshot,
        where: s.tournament_id == ^tournament_id and s.id == ^id,
        preload: [:user]
    )
  end

  @doc "Total number of snapshots held for `tournament_id`."
  @spec count(integer()) :: non_neg_integer()
  def count(tournament_id) do
    Repo.aggregate(from(s in Snapshot, where: s.tournament_id == ^tournament_id), :count)
  end

  @doc """
  Deletes all but the `@keep_per_tournament` most recent *unpinned* snapshots
  for `tournament_id`. Called automatically by `capture/4`; returns the number
  deleted.

  Pinned snapshots (the ones a restore takes of the state it replaced) are
  never counted and never deleted — see the `pinned` field's own comment.
  """
  @spec prune(integer()) :: non_neg_integer()
  def prune(tournament_id) do
    keep_ids =
      Repo.all(
        from s in Snapshot,
          where: s.tournament_id == ^tournament_id and s.pinned == false,
          order_by: [desc: s.inserted_at, desc: s.id],
          limit: @keep_per_tournament,
          select: s.id
      )

    {deleted, _} =
      Repo.delete_all(
        from s in Snapshot,
          where: s.tournament_id == ^tournament_id and s.pinned == false and s.id not in ^keep_ids
      )

    deleted
  end

  ## ---------- restoring ----------

  @doc """
  Replaces `tournament`'s contents with the state held in snapshot `id`.

  Before doing anything it captures the *current* state as a pinned snapshot,
  so the jump is itself reversible — going back to Tuesday leaves a restore
  point holding Thursday, which appears on the timeline and can be jumped
  forward to. Pinned so that bouncing between two states can't push the state
  you jumped away from off the end of the retention window.

  What it replaces: teams, players, rounds (and their pairings, via cascade),
  byes, forbidden pairings, and the tournament's own settings fields.

  What it deliberately leaves alone:

    * **Collaborators** — who has access is not tournament content, and a
      restore silently revoking a co-arbiter would be its own incident.
    * **The audit log and other snapshots** — the history of what happened
      must survive being rolled back, or the record would be self-erasing.
    * **Mobile enrolments** — phones already scanned in keep working.
    * **Sharing state and the public slug** — these aren't in the payload at
      all (see the moduledoc); a restore must never silently re-publish a
      tournament or resurrect a rotated link.

  Runs in one transaction: either the whole state lands or nothing does.
  Refuses on an archived tournament, like every other write.

  Returns `{:ok, tournament}` with the reloaded tournament, or
  `{:error, reason}`.
  """
  @spec restore(Tournament.t(), integer() | String.t(), Scope.t() | integer() | nil) ::
          {:ok, Tournament.t()} | {:error, term()}
  def restore(%Tournament{} = tournament, snapshot_id, actor \\ nil) do
    with :ok <- Tournaments.ensure_writable(tournament),
         %Snapshot{} = snapshot <- get(tournament.id, snapshot_id),
         {:ok, entry} <- payload_entry(snapshot) do
      # Capture what we're about to overwrite, pinned, so this is reversible.
      capture(tournament, "snapshot.restored", actor,
        summary: "Before restoring to #{restore_label(snapshot)}",
        pinned: true
      )

      do_restore(tournament, entry)
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp restore_label(%Snapshot{summary: summary}) when is_binary(summary) and summary != "",
    do: "\"#{summary}\""

  defp restore_label(%Snapshot{inserted_at: at}),
    do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")

  defp payload_entry(%Snapshot{payload: %{"tournaments" => [entry | _]}}) when is_map(entry),
    do: {:ok, entry}

  defp payload_entry(%Snapshot{}), do: {:error, :malformed_snapshot}

  defp do_restore(tournament, entry) do
    result =
      Tournaments.with_broadcast_suppressed(fn ->
        Repo.transaction(fn ->
          wipe_contents(tournament.id)
          TournamentImport.restore_into!(tournament, entry)
        end)
      end)

    case result do
      {:ok, _} ->
        Tournaments.broadcast_tournament_change(tournament.id, :tournament)
        {:ok, Tournaments.refresh_status!(tournament.id)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Teams, players, rounds, byes and forbidden pairings are the whole of what
  # a snapshot carries, so they're replaced wholesale rather than diffed.
  # Deleting rounds cascades to their pairings; deleting players would too,
  # but byes/forbidden pairings are schemaless so they're cleared explicitly
  # and in the right order.
  defp wipe_contents(tournament_id) do
    Repo.delete_all(from b in "byes", where: b.tournament_id == ^tournament_id)
    Repo.delete_all(from f in "forbidden_pairings", where: f.tournament_id == ^tournament_id)
    Repo.delete_all(from r in Round, where: r.tournament_id == ^tournament_id)
    Repo.delete_all(from p in Player, where: p.tournament_id == ^tournament_id)
    Repo.delete_all(from t in Team, where: t.tournament_id == ^tournament_id)
  end
end
