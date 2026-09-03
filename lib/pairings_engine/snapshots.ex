defmodule PairingsEngine.Snapshots do
  @moduledoc """
  Point-in-time copies of a whole tournament, taken automatically just before
  an action that is hard or impossible to undo by hand.

  ## What's in one

  The payload is a `PairingsEngine.TournamentExport` envelope - byte-identical
  to what the "Export full backup (JSON)" button produces. Reusing that
  serializer (rather than writing a second one) means snapshots inherit its
  round-trip tests and can't drift from it, and the restore path is a variant
  of `PairingsEngine.TournamentImport` rather than a parallel implementation.

  It follows that snapshots inherit the export's deliberate exclusions, and
  that's the behaviour we want here too:

    * **Sharing state is not captured** (`registration_open`,
      `publish_to_openresults`, `public_slug`). Rolling back to an earlier
      state must never silently re-publish a tournament that was taken down,
      re-open entries that were closed, or hand out an address that was
      rotated away after a leak.
    * **Ownership and lifecycle are not captured** (`user_id`, `deleted_at`,
      `archived_at`). A restore changes a tournament's *contents*, never who
      owns it or whether it's archived.
    * The logo is a known gap, same as the export's.

  One exception is worth stating because it looks like a contradiction of the
  first bullet: the envelope's `"openresults"` block, holding the tournament's
  publishing key, IS in the payload - it is in every export, and snapshots use
  the export verbatim. Restoring never applies it. `openresults_key` is not
  cast by `Tournament.changeset/2`, so `TournamentImport.restore_into!/2`
  cannot write it, and that is the behaviour we want in both directions:
  rolling back to a restore point taken before the tournament first published
  must not revoke the key it holds now, and rolling back to one taken after
  must not resurrect a key a takedown deliberately retired.

  ## Where they're taken

  From the LiveView handler, immediately *before* the risky context call -
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
  protect - losing the ability to roll back is bad, refusing to pair a round
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
        # Hangs off wherever the live data currently sits, so a capture taken
        # after a restore forks the tree at the restored point rather than
        # extending the line that was abandoned.
        parent_id: tournament.head_snapshot_id,
        payload: TournamentExport.export_tournament(tournament)
      })
      |> Repo.insert()

    case result do
      {:ok, snapshot} ->
        # The new snapshot is now the tip of the current line.
        set_head(tournament, snapshot.id)
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

  # HEAD is bookkeeping, not user-facing content: written straight rather than
  # through `Tournaments.update_tournament/2` so it never broadcasts a
  # settings change or trips the archive guard (a snapshot of an archived
  # tournament is a read, and still legitimate).
  defp set_head(%Tournament{} = tournament, snapshot_id) do
    Repo.update_all(
      from(t in Tournament, where: t.id == ^tournament.id),
      set: [head_snapshot_id: snapshot_id]
    )
  end

  defp user_id(%Scope{user: %{id: id}}), do: id
  defp user_id(%Scope{}), do: nil
  defp user_id(id) when is_integer(id), do: id
  defp user_id(nil), do: nil

  @doc """
  Lists `tournament_id`'s snapshots, newest first, with the acting `:user`
  preloaded. The `payload` is excluded - it's a full tournament copy, far too
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
  never counted and never deleted - see the `pinned` field's own comment.
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

  ## ---------- the branch tree ----------

  @doc """
  `tournament`'s restore points as a drawable tree, newest first.

  Returns one entry per snapshot with the structure the timeline needs:

    * `:lane` - which vertical column to draw it in. The line the live data
      is currently on is always lane 0; each fork takes the next free lane,
      so a tournament that was never restored is a single straight column.
    * `:parent_lane` - the lane its parent sits in, so the view can draw the
      connector (straight down within a lane, a curve when it crosses).
    * `:on_head_line` - whether it's an ancestor of (or is) the current HEAD,
      i.e. part of the history that actually produced the live data. The
      other lanes are abandoned alternatives, still reachable.
    * `:children` - how many snapshots hang off it; more than one is the fork
      itself, which the view marks.

  Lane assignment walks oldest-first so a lane number, once given out, is
  stable as the tournament grows - a new branch never renumbers the existing
  ones under the reader.
  """
  @spec branch_tree(Tournament.t()) :: [map()]
  def branch_tree(%Tournament{} = tournament) do
    snapshots =
      Repo.all(
        from s in Snapshot,
          where: s.tournament_id == ^tournament.id,
          order_by: [asc: s.inserted_at, asc: s.id],
          preload: [:user],
          select: %{s | payload: nil}
      )

    by_id = Map.new(snapshots, &{&1.id, &1})
    child_counts = Enum.frequencies_by(snapshots, & &1.parent_id)
    head_line = ancestry(tournament.head_snapshot_id, by_id)

    {entries, _lanes, _continued} =
      Enum.reduce(snapshots, {[], %{}, MapSet.new()}, fn snapshot, {acc, lanes, continued} ->
        {lane, continued} = assign_lane(snapshot, lanes, continued, head_line)

        entry = %{
          snapshot: snapshot,
          lane: lane,
          parent_lane: Map.get(lanes, snapshot.parent_id),
          on_head_line: MapSet.member?(head_line, snapshot.id),
          is_head: snapshot.id == tournament.head_snapshot_id,
          children: Map.get(child_counts, snapshot.id, 0)
        }

        {[entry | acc], Map.put(lanes, snapshot.id, lane), continued}
      end)

    # Built oldest-first for stable lanes; returned newest-first to match the
    # timeline. The reduce already reverses, so this is the right order.
    entries
  end

  # Lane 0 is reserved for the line the live data is on, so the "real"
  # history reads as the trunk however much branching happened around it.
  # Everything else continues its parent's lane if it is that parent's first
  # child, and otherwise opens a new lane - which is what makes a fork look
  # like a fork and a straight run look like a straight run.
  #
  # `continued` is the set of parents that have already passed their lane to
  # a child, and it is why this is threaded through the reduce rather than
  # derived from `lanes`. Two earlier versions tried to derive it and both
  # were wrong, in opposite directions:
  #
  #   * asking "is any snapshot holding the parent's lane?" always matched
  #     the PARENT itself (snapshots are walked oldest-first, so the parent
  #     is already placed) - no child ever continued a lane, and an
  #     abandoned run of restore points drew as one lane per snapshot;
  #   * excluding just the parent then matched the GRANDPARENT, who is on
  #     the same lane legitimately - so a chain broke at its third node
  #     (A -> B -> C -> D gave B and C lane 1 but D lane 2).
  #
  # The question was never "who holds this lane" but "has a SIBLING taken
  # it", and that is not recoverable from `lanes` alone.
  defp assign_lane(snapshot, lanes, continued, head_line) do
    parent_lane = Map.get(lanes, snapshot.parent_id)

    cond do
      MapSet.member?(head_line, snapshot.id) ->
        {0, continued}

      # `parent_lane != 0` matters: reaching here means this snapshot is NOT
      # on the head line, so inheriting lane 0 from a parent that is would
      # draw an abandoned branch on the trunk. A root snapshot off the head
      # line (parent_lane nil) opens its own lane for the same reason.
      parent_lane not in [nil, 0] and not MapSet.member?(continued, snapshot.parent_id) ->
        {parent_lane, MapSet.put(continued, snapshot.parent_id)}

      true ->
        {next_free_lane(lanes), continued}
    end
  end

  defp next_free_lane(lanes) do
    used = lanes |> Map.values() |> MapSet.new()
    Stream.iterate(1, &(&1 + 1)) |> Enum.find(&(not MapSet.member?(used, &1)))
  end

  # Every snapshot from `id` back to its root - the chain that actually
  # produced the current live data.
  defp ancestry(nil, _by_id), do: MapSet.new()

  defp ancestry(id, by_id) do
    Stream.unfold(id, fn
      nil -> nil
      current -> {current, Map.get(by_id, current, %{parent_id: nil}).parent_id}
    end)
    |> MapSet.new()
  end

  ## ---------- restoring ----------

  @doc """
  Replaces `tournament`'s contents with the state held in snapshot `id`.

  Before doing anything it captures the *current* state as a pinned snapshot,
  so the jump is itself reversible - going back to Tuesday leaves a restore
  point holding Thursday, which appears on the timeline and can be jumped
  forward to. Pinned so that bouncing between two states can't push the state
  you jumped away from off the end of the retention window.

  What it replaces: teams, players, rounds (and their pairings, via cascade),
  byes, forbidden pairings, and the tournament's own settings fields.

  What it deliberately leaves alone:

    * **Collaborators** - who has access is not tournament content, and a
      restore silently revoking a co-arbiter would be its own incident.
    * **The audit log and other snapshots** - the history of what happened
      must survive being rolled back, or the record would be self-erasing.
    * **Mobile enrolments** - phones already scanned in keep working.
    * **Sharing state and the public slug** - these aren't in the payload at
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
      do_restore(tournament, snapshot, entry, actor)
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

  # The two HEAD writes belong to the restore, so they live inside its
  # transaction. They used to be plain committed writes ahead of it: a
  # snapshot whose payload no longer validates against the current changesets
  # left the tournament's data untouched (that part always rolled back
  # cleanly) but `head_snapshot_id` pointing at the target and a pinned
  # "Before restoring to …" snapshot on the tree, so the next `capture/4`
  # hung its `parent_id` off the wrong node. Now a rejected restore leaves
  # nothing behind at all.
  #
  # Order inside the transaction still matters: the "before" capture exports
  # the live data, so it has to run ahead of `wipe_contents/1`.
  defp do_restore(tournament, snapshot, entry, actor) do
    result =
      Tournaments.with_broadcast_suppressed(fn ->
        Repo.transaction(fn ->
          # Capture what we're about to overwrite, pinned, so this is
          # reversible. This extends the line being left (its parent is the
          # current HEAD), so that line stays intact and reachable rather
          # than being orphaned.
          capture(tournament, "snapshot.restored", actor,
            summary: "Before restoring to #{restore_label(snapshot)}",
            pinned: true
          )

          # Move HEAD to the point being restored. The next capture hangs
          # off here, which is what makes the tree fork at this node instead
          # of continuing the abandoned line.
          set_head(tournament, snapshot.id)

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

  @doc """
  Deletes everything an export envelope carries for `tournament_id` - teams,
  players, rounds (and their pairings, via cascade), byes and forbidden
  pairings - leaving the tournament row, its audit trail, its collaborators
  and its snapshots alone.

  Half of a wholesale replacement, and public because there are two of those:
  this module's `restore/3` and `PairingsEngine.Handoff.release/3`, which
  applies a returning hand-off file. Both pair it with
  `PairingsEngine.TournamentImport.restore_into!/2` inside one transaction,
  and calling it outside one is how a tournament is emptied for good.

  Teams, players, rounds, byes and forbidden pairings are the whole of what an
  envelope carries, so they are replaced wholesale rather than diffed.
  Deleting rounds cascades to their pairings; deleting players would too, but
  byes/forbidden pairings are schemaless so they're cleared explicitly and in
  the right order.
  """
  @spec wipe_contents(integer()) :: :ok
  def wipe_contents(tournament_id) do
    Repo.delete_all(from b in "byes", where: b.tournament_id == ^tournament_id)
    Repo.delete_all(from f in "forbidden_pairings", where: f.tournament_id == ^tournament_id)
    Repo.delete_all(from r in Round, where: r.tournament_id == ^tournament_id)
    Repo.delete_all(from p in Player, where: p.tournament_id == ^tournament_id)
    Repo.delete_all(from t in Team, where: t.tournament_id == ^tournament_id)
    :ok
  end
end
