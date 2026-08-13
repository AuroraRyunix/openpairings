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

  alias PairingsEngine.{Repo, TournamentExport}
  alias PairingsEngine.Accounts.Scope
  alias PairingsEngine.Snapshots.Snapshot
  alias PairingsEngine.Tournaments.Tournament

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
  Deletes all but the `@keep_per_tournament` most recent snapshots for
  `tournament_id`. Called automatically by `capture/4`; returns the number
  deleted.
  """
  @spec prune(integer()) :: non_neg_integer()
  def prune(tournament_id) do
    keep_ids =
      Repo.all(
        from s in Snapshot,
          where: s.tournament_id == ^tournament_id,
          order_by: [desc: s.inserted_at, desc: s.id],
          limit: @keep_per_tournament,
          select: s.id
      )

    {deleted, _} =
      Repo.delete_all(
        from s in Snapshot,
          where: s.tournament_id == ^tournament_id and s.id not in ^keep_ids
      )

    deleted
  end
end
