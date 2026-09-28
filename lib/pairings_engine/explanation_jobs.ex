defmodule PairingsEngine.ExplanationJobs do
  @moduledoc """
  Works out a round's engine account after the round is saved, rather than
  inside the "Pair round" click.

  The account (`Ainalrami.Pairing.explain_round/3` plus the float and bye
  alternatives, one forced re-pairing per candidate) is commentary: nothing
  about the pairing, its compliance stamp or the audit trail depends on it.
  It was nonetheless computed before the round was written, and for a
  450-player round 2 on the two-core server it was 235 of the click's 253
  seconds. So `PairingsEngine.Pairing` now stores the round with a PENDING
  record - the deviation facts it already knows, and a fingerprint - and
  hands the expensive part to `run/4`.

  ## The job

  One supervised task per round (`PairingsEngine.ExplanationTaskSupervisor`),
  registered by round id so a second request for the same round is a no-op
  and an unpair can stop it (`cancel/1`). It runs at low scheduler priority:
  the server has two cores, and pages must keep answering while it works.

  The result is written only if the round still holds the pending record it
  was started for - same row id, same `"job"` fingerprint (`store/3`). A
  round unpaired, deleted, re-paired or restored meanwhile no longer does,
  and a late result is dropped rather than written onto a round it does
  not describe. SQLite reuses the highest row id after a delete, so the id
  alone could not tell a re-paired round from the old one; the fingerprint
  carries a random part for exactly that.

  When it is stored - or when the work fails - a
  `{:tournament_changed, id, :explanation}` goes out on the tournament's
  topic, so the Pairings page and the explanation page update in place.

  ## Failure, restart

  A job that raises, exits or runs past `timeout/0` marks the record
  `"failed"`, which the explanation page shows with a "Try again". A job
  lost with the node (a restart, a deploy) leaves the record `"pending"`
  with nobody working on it: the explanation page notices (`running?/1`)
  and starts a recompute from the round's history
  (`PairingsEngine.Pairing.recompute_explanation/2`) - on demand, when
  somebody wants to read it, never a spinner with nothing behind it.

  ## Tests

  `config :pairings_engine, :explanation_jobs, :inline` runs the same work
  in the calling process before `PairingsEngine.Pairing.pair_next_round/2`
  returns, so the suite sees a finished record exactly as it always did.
  The tests of this module switch it to `:async`.
  """

  require Logger
  import Ecto.Query

  alias PairingsEngine.{Repo, Tournaments}
  alias PairingsEngine.Tournaments.Round

  @supervisor PairingsEngine.ExplanationTaskSupervisor
  @registry PairingsEngine.ExplanationJobRegistry

  # Far beyond any real round (the 450-player round above is four minutes
  # on the server), and short enough that a search that has gone wrong
  # ends as "could not be worked out" instead of an explanation that never
  # comes.
  @default_timeout_ms 30 * 60 * 1000

  @doc false
  def mode, do: Application.get_env(:pairings_engine, :explanation_jobs, :async)

  @doc false
  def timeout,
    do: Application.get_env(:pairings_engine, :explanation_job_timeout_ms, @default_timeout_ms)

  @doc """
  A fresh fingerprint for a round about to be stored with a pending record:
  the pairs it explains, and a random part so a round re-paired to the very
  same boards still gets a different one.
  """
  def fingerprint(term) do
    :crypto.hash(:sha256, :erlang.term_to_binary({term, :crypto.strong_rand_bytes(16)}))
    |> binary_part(0, 16)
    |> Base.url_encode64(padding: false)
  end

  @doc """
  Works out `round_id`'s account with `work` (a zero-arity function that
  returns `{:ok, payload}` or `{:error, reason}`) and stores it if the round
  still holds the pending record with `fingerprint`. Asynchronous unless
  configured `:inline`; a job already running for the round wins.
  """
  def run(tournament_id, round_id, fingerprint, work) when is_function(work, 0) do
    case mode() do
      :inline ->
        perform(tournament_id, round_id, fingerprint, work, :inline)

      _async ->
        # Returns once the job is registered, so a page asking `running?/1`
        # straight after the click (the Pairings page does) sees it, rather
        # than starting a second one from the round's history.
        caller = self()
        ref = make_ref()

        {:ok, _pid} =
          Task.Supervisor.start_child(@supervisor, fn ->
            registered = Registry.register(@registry, round_id, fingerprint)
            send(caller, {ref, :registered})

            case registered do
              {:ok, _} -> perform(tournament_id, round_id, fingerprint, work, :async)
              {:error, {:already_registered, _pid}} -> :ok
            end
          end)

        receive do
          {^ref, :registered} -> :ok
        after
          5_000 -> :ok
        end
    end
  end

  @doc "Whether a job is working on `round_id` in this node right now."
  def running?(round_id), do: Registry.lookup(@registry, round_id) != []

  @doc """
  Stops the jobs for these rounds, if any. Unpairing calls this: the result
  could not be stored anyway (see `store/3`), and the server has better
  things to do with its two cores.
  """
  def cancel(round_ids) do
    for round_id <- List.wrap(round_ids), {pid, _} <- Registry.lookup(@registry, round_id) do
      Task.Supervisor.terminate_child(@supervisor, pid)
    end

    :ok
  end

  @doc """
  Writes `payload` onto the round if, and only if, it still holds the
  pending (or failed) record `fingerprint` names. `:stored` or `:stale`.
  """
  def store(round_id, fingerprint, payload) do
    {count, _} =
      Repo.update_all(
        from(r in Round,
          where:
            r.id == ^round_id and
              fragment("json_extract(?, '$.job')", r.explanation) == ^fingerprint
        ),
        set: [explanation: payload]
      )

    if count == 1, do: :stored, else: :stale
  end

  @doc """
  Marks the pending record `"failed"` (same guard as `store/3`), keeping
  everything else on it - the deviation facts are the round's record.
  """
  def mark_failed(round_id, fingerprint) do
    update_status(round_id, fingerprint, "failed")
  end

  @doc """
  Puts a failed record back to pending, for "Try again". Same guard.
  """
  def mark_pending(round_id, fingerprint) do
    update_status(round_id, fingerprint, "pending")
  end

  defp update_status(round_id, fingerprint, status) do
    case Repo.get(Round, round_id) do
      %Round{explanation: %{"job" => ^fingerprint} = record} ->
        store(round_id, fingerprint, Map.put(record, "status", status))

      _ ->
        :stale
    end
  end

  defp perform(tournament_id, round_id, fingerprint, work, how) do
    result =
      case how do
        :inline -> safely(work)
        :async -> with_timeout(work)
      end

    outcome =
      case result do
        {:ok, payload} when is_map(payload) ->
          store(round_id, fingerprint, payload)

        {:error, reason} ->
          Logger.warning(
            "The engine's account of round #{round_id} (tournament #{tournament_id}) " <>
              "could not be worked out: #{inspect(reason)}"
          )

          mark_failed(round_id, fingerprint)
      end

    if outcome == :stored, do: broadcast(tournament_id)
    outcome
  end

  defp with_timeout(work) do
    Process.flag(:priority, :low)

    task =
      Task.async(fn ->
        Process.flag(:priority, :low)
        safely(work)
      end)

    case Task.yield(task, timeout()) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
      {:exit, reason} -> {:error, {:exit, reason}}
    end
  end

  defp safely(work) do
    case work.() do
      {:ok, _payload} = ok -> ok
      {:error, _reason} = error -> error
      other -> {:error, {:unexpected, other}}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # Straight onto the topic, not through
  # `Tournaments.broadcast_tournament_change/2`: that one also queues a
  # publish of the public pages, and the account is not on them.
  defp broadcast(tournament_id) do
    Phoenix.PubSub.broadcast(
      PairingsEngine.PubSub,
      Tournaments.tournament_topic(tournament_id),
      {:tournament_changed, tournament_id, :explanation}
    )
  end
end
