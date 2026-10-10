defmodule PairingsEngine.Publishing.Accepted do
  @moduledoc """
  What the results site last accepted for each tournament, so the queue can
  decline to send the same document twice.

  A queued publish is an intent, and plenty of intents change nothing: a
  dialog confirmed with nothing to do, a setting saved as it was, a result
  typed and taken back before the drain woke up. Each used to cost a full
  document over the hall's wifi, another row in the server's history and a
  top bar saying "Sending" about nothing at all.

  So the drain builds the document as it always did, and asks here whether it
  is the one the server already holds (`unchanged?/3`). Only the drain asks.
  `Publishing.publish/1` called directly, "Try again", a first publish and
  anything after a failure all send.

  ## The rule this is built around

  Not sending a change is the one failure that matters; sending a document
  twice costs a few kilobytes. Every doubtful case below therefore resolves
  to "send", and a skip needs all of these to hold at once:

    * this running copy of the app POSTed a document for this tournament and
      the server answered 2xx to it (`record/3` is called from nowhere else);
    * the document about to go out hashes the same (`fingerprint/1`);
    * it would go to the same server, under the same tournament key and the
      same credential, built by the same version of the app (the binding);
    * no send for this tournament has failed since, nor shortly before - see
      "After a failure";
    * the acceptance is less than `trust_seconds/0` old.

  ## Memory, not the database

  The table lives in this VM and dies with it. That is the point: it is a
  record of what the SERVER holds, and the database is the wrong place to
  keep one. A database restored from last night's backup would bring last
  night's fingerprint with it and compare it, successfully, with last night's
  data - while the server is showing this morning's. Kept here, a restore, an
  import or a hand-off coming back changes what gets built and nothing about
  what was accepted, so the comparison stays honest.

  The price is one send per tournament after a restart, which is also what
  makes the upgrade re-send (`Publishing.backfill/0`) and a changed snapshot
  format go out with no code here knowing about either.

  ## Why not ask the server instead

  It was considered. OpenResults has no digest or ETag for a snapshot on its
  API; the only way to learn what it holds is `GET /api/tournaments/:slug`,
  which returns the whole document (minus `publisher`, and a 404 for a
  tournament its operator has hidden). Downloading the document to avoid
  uploading it saves nothing and adds a second way to be wrong.

  What local memory cannot see is the server changing behind this machine's
  back: a restore on that side, an operator's delete, a second machine
  holding the same key. Nothing in the app could see those before either -
  they were repaired by accident, by the next write. `trust_seconds/0` keeps
  that accident available: an identical document is skipped for an hour
  after the server took it, and after that it is sent again like any other.

  ## After a failure

  A send that timed out here may still be in flight there. If the retry then
  succeeds and the stalled request lands after it, the server holds the OLDER
  document while this side remembers the newer one. So a failure forgets the
  tournament's entry, and nothing is remembered for it again until
  `settle_seconds/0` have passed - longer than any timeout between here and
  the server. Sends during that time simply go out.

  ## One sender at a time

  `Publishing` builds and posts under a per-tournament lock, so two sends of
  one tournament cannot overlap and "the last one this side saw accepted" is
  the last one the server stored.
  """

  @table :publishing_accepted

  # The top-level keys of a snapshot that are a statement about WHEN it was
  # built rather than about the tournament. Left out of the fingerprint, each
  # for a reason that has to be written down here:
  #
  #   * "published_at" - `Snapshot.build/1`'s own clock, to the second. It is
  #     the reason no two builds were ever byte-identical. Leaving it out
  #     means a skipped document keeps the stamp of the send that carried the
  #     same content, which is the true answer to "when was this published".
  #     OpenResults stores it beside its own `received_at` and decides
  #     nothing by it: retention and ordering use `received_at`.
  #
  # That is the whole list. "source" (this app's version) is deliberately NOT
  # here: a document built by different code is a different document.
  @volatile ~w(published_at)

  # Everything else `Snapshot.build/1` can put at the top level. Hashed.
  @stable ~w(schema version source tournament players rounds standings publisher teams
             team_standings board_stats)

  # An identical document is skipped only this long after the server took
  # it. See "Why not ask the server instead".
  @trust_seconds 3_600

  # See "After a failure". Publishing's own request timeout is 15 seconds;
  # a proxy in front of the server gives up within a couple of minutes.
  @settle_seconds 300

  @doc "Top-level snapshot keys left out of the fingerprint."
  def volatile_keys, do: @volatile

  @doc "Top-level snapshot keys this module knows to be content."
  def stable_keys, do: @stable

  def trust_seconds, do: @trust_seconds
  def settle_seconds, do: @settle_seconds

  @doc """
  Creates the table. Called once from `PairingsEngine.Application.start/2`,
  whose process outlives everything that reads it.
  """
  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  SHA-256 of `payload` without its volatile keys.

  A key this module has never heard of is HASHED, not dropped: an unknown
  field is content until somebody argues otherwise in `@volatile`. The test
  that walks `Snapshot.build/1`'s keys exists so that argument happens when
  the field is added rather than never.

  Hashed as a deterministic external term rather than as JSON. Two payloads
  that differ anywhere differ as terms, so equal hashes mean an equal
  document; the reverse can fail (an atom where a string was) and costs one
  unnecessary send.
  """
  @spec fingerprint(map()) :: binary()
  def fingerprint(%{} = payload) do
    :crypto.hash(
      :sha256,
      payload |> Map.drop(@volatile) |> :erlang.term_to_binary([:deterministic])
    )
  end

  @doc """
  Whether `payload` is the document the server last accepted for
  `tournament_id` under `binding`, by every condition in the moduledoc.

  `binding` is whatever must also be unchanged for "the server has this" to
  still be true - `Publishing.acceptance_binding/1` builds it. `now` is unix
  seconds and exists for tests.
  """
  @spec unchanged?(integer(), map(), term(), integer()) :: boolean()
  def unchanged?(tournament_id, payload, binding, now \\ now()) do
    case lookup(tournament_id) do
      {fingerprint, bound, accepted_at} ->
        age = now - accepted_at

        # A negative age is a clock that went backwards, and a clock that
        # went backwards has no opinion worth acting on.
        age >= 0 and age < @trust_seconds and bound == digest(binding) and
          not unsettled?(tournament_id, accepted_at) and fingerprint == fingerprint(payload)

      nil ->
        false
    end
  rescue
    # No table, or a payload that will not serialise: not a reason to skip.
    _ -> false
  end

  @doc """
  Remembers that the server answered success to exactly `payload`. Nothing
  is remembered while a failed send may still be in flight.
  """
  @spec record(integer(), map(), term(), integer()) :: :ok
  def record(tournament_id, payload, binding, now \\ now()) do
    if unsettled?(tournament_id, now) do
      :ets.delete(@table, tournament_id)
    else
      :ets.insert(@table, {tournament_id, fingerprint(payload), digest(binding), now})
    end

    :ok
  rescue
    _ ->
      forget(tournament_id)
      :ok
  end

  @doc "A send for `tournament_id` failed, or was refused before it left."
  @spec failed(integer(), integer()) :: :ok
  def failed(tournament_id, now \\ now()) do
    :ets.delete(@table, tournament_id)
    :ets.insert(@table, {{:failed, tournament_id}, now})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Forgets `tournament_id`'s entry, so its next queued publish is sent
  whatever it contains. For everything that changes what is on the server,
  or who owns it, without going through a send from here.
  """
  @spec forget(integer()) :: :ok
  def forget(tournament_id) do
    :ets.delete(@table, tournament_id)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Forgets every entry. For a change of server or credential, and for tests."
  @spec forget_all() :: :ok
  def forget_all do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp lookup(tournament_id) do
    case :ets.lookup(@table, tournament_id) do
      [{^tournament_id, fingerprint, bound, accepted_at}] -> {fingerprint, bound, accepted_at}
      [] -> nil
    end
  end

  # Whether a failure is recent enough, relative to `at`, that a request
  # from it could still arrive. A failure stamped after `at` counts too:
  # that is the same backwards clock again.
  defp unsettled?(tournament_id, at) do
    case :ets.lookup(@table, {:failed, tournament_id}) do
      [{_key, failed_at}] -> at < failed_at + @settle_seconds
      [] -> false
    end
  end

  # The binding holds a tournament key and a credential. Compared, never
  # read back, so only a digest is kept.
  defp digest(binding), do: :crypto.hash(:sha256, :erlang.term_to_binary(binding))

  defp now, do: System.os_time(:second)
end
