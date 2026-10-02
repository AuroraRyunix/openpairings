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
  hands the rest to `run/4`.

  Since 2026-09-28 that job works out the brackets only (under a second on
  that field), and each alternative is worked out when somebody opens it
  on the explanation page - `run_alternative/5`, the same machinery, one
  job per question - and kept in `round_alternatives` (see "One
  alternative" below).

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
  alias PairingsEngine.Tournaments.{Round, RoundAlternative}

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
    for round_id <- List.wrap(round_ids) do
      account = for {pid, _fingerprint} <- Registry.lookup(@registry, round_id), do: pid
      alternatives = for {_question, pid, _fingerprint} <- alternative_jobs(round_id), do: pid
      Enum.each(account ++ alternatives, &Task.Supervisor.terminate_child(@supervisor, &1))
    end

    :ok
  end

  @doc """
  Writes `payload` onto the round if, and only if, it still holds the
  pending (or failed) record `fingerprint` names. `:stored` or `:stale`.

  A finished account keeps its `"job"` since 2026-09-28 - its alternatives
  are stored against it (`store_alternative/4`) - so the guard asks for the
  status as well: a finished account is never written over by a second job.
  """
  def store(round_id, fingerprint, payload) do
    {count, _} =
      Repo.update_all(
        from(r in Round,
          where:
            r.id == ^round_id and
              fragment("json_extract(?, '$.job')", r.explanation) == ^fingerprint and
              fragment("json_extract(?, '$.status')", r.explanation) in ["pending", "failed"]
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

  ## ---------- one alternative, when somebody opens it ----------
  #
  # Since 2026-09-28 the account a job above stores is the cheap part only:
  # the brackets and the criteria. Each "why him and not me" - one forced
  # re-pairing of the round per candidate - is worked out when somebody
  # opens that question on the explanation page, by the same machinery: a
  # supervised, low-priority task, registered (by round and question, so a
  # second click, or a second viewer, joins the one already running), a
  # timeout, and a guarded write (`store_alternative/4`).
  #
  # Its news goes out on a topic of its own (`alternatives_topic/1`), not
  # the tournament's: a dozen pages reload on anything said there, and an
  # arbiter opening a question changes nothing they show.

  @doc "The PubSub topic of a tournament's alternatives being worked out."
  def alternatives_topic(tournament_id), do: "round_alternatives:#{tournament_id}"

  @doc """
  Works out one alternative of `round_id` with `work` (zero-arity, returning
  `{:ok, result_json}` or `{:error, reason}`) and stores it against
  `fingerprint` and `question`. Broadcasts
  `{:round_alternative, round_id, fingerprint, question, status}` on
  `alternatives_topic/1` - `:running` when it starts, `:ready` when stored,
  `:failed` when it failed or no longer applies. Asynchronous unless
  configured `:inline`; a job already working on the question wins.
  """
  def run_alternative(tournament_id, round_id, fingerprint, question, work)
      when is_function(work, 0) do
    case mode() do
      :inline ->
        broadcast_alternative(tournament_id, round_id, fingerprint, question, :running)
        perform_alternative(tournament_id, round_id, fingerprint, question, work, :inline)

      _async ->
        caller = self()
        ref = make_ref()

        {:ok, _pid} =
          Task.Supervisor.start_child(@supervisor, fn ->
            registered =
              Registry.register(@registry, {:alternative, round_id, question}, fingerprint)

            send(caller, {ref, :registered})

            case registered do
              {:ok, _} ->
                broadcast_alternative(tournament_id, round_id, fingerprint, question, :running)
                perform_alternative(tournament_id, round_id, fingerprint, question, work, :async)

              {:error, {:already_registered, _pid}} ->
                :ok
            end
          end)

        receive do
          {^ref, :registered} -> :ok
        after
          5_000 -> :ok
        end
    end
  end

  @doc """
  The questions of `round_id` a job in this node is working on for the
  account `fingerprint`.
  """
  def running_alternatives(round_id, fingerprint) do
    for {question, _pid, ^fingerprint} <- alternative_jobs(round_id),
        into: MapSet.new(),
        do: question
  end

  defp alternative_jobs(round_id) do
    Registry.select(@registry, [
      {{{:alternative, round_id, :"$1"}, :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}
    ])
  end

  @doc """
  Keeps `result` as the answer to `question` for the account `fingerprint`
  of `round_id` - if, and only if, the round still holds that finished
  account. `:stored` or `:stale`. A second answer to the same question (the
  whole bracket worked out, past the cap) replaces the first.
  """
  def store_alternative(round_id, fingerprint, question, result) do
    Repo.transaction(fn ->
      current =
        Repo.exists?(
          from(r in Round,
            where:
              r.id == ^round_id and
                fragment("json_extract(?, '$.job')", r.explanation) == ^fingerprint and
                is_nil(fragment("json_extract(?, '$.status')", r.explanation))
          )
        )

      if current do
        now = DateTime.utc_now(:second)

        Repo.insert!(
          %RoundAlternative{
            round_id: round_id,
            job: fingerprint,
            question: question,
            result: result,
            inserted_at: now,
            updated_at: now
          },
          on_conflict: [set: [result: result, updated_at: now]],
          conflict_target: [:round_id, :job, :question]
        )

        :stored
      else
        :stale
      end
    end)
    |> case do
      {:ok, outcome} -> outcome
      {:error, _} -> :stale
    end
  end

  @doc "The stored answers of `round_id`'s account `fingerprint`, by question."
  def stored_alternatives(round_id, fingerprint) do
    Repo.all(
      from(a in RoundAlternative,
        where: a.round_id == ^round_id and a.job == ^fingerprint,
        select: {a.question, a.result}
      )
    )
    |> Map.new()
  end

  defp perform_alternative(tournament_id, round_id, fingerprint, question, work, how) do
    result =
      case how do
        :inline -> safely(work)
        :async -> with_timeout(work)
      end

    outcome =
      case result do
        {:ok, answer} when is_map(answer) ->
          store_alternative(round_id, fingerprint, question, answer)

        {:error, reason} ->
          Logger.warning(
            "An alternative of round #{round_id} (tournament #{tournament_id}, #{question}) " <>
              "could not be worked out: #{inspect(reason)}"
          )

          :failed
      end

    status = if outcome == :stored, do: :ready, else: :failed
    broadcast_alternative(tournament_id, round_id, fingerprint, question, status)
    outcome
  end

  defp broadcast_alternative(tournament_id, round_id, fingerprint, question, status) do
    Phoenix.PubSub.broadcast(
      PairingsEngine.PubSub,
      alternatives_topic(tournament_id),
      {:round_alternative, round_id, fingerprint, question, status}
    )
  end

  defp perform(tournament_id, round_id, fingerprint, work, how) do
    result =
      case how do
        :inline -> safely(work)
        :async -> with_timeout(work)
      end

    outcome =
      case result do
        # The fingerprint stays on the finished account: its alternatives,
        # worked out later, are stored against it.
        {:ok, payload} when is_map(payload) ->
          store(round_id, fingerprint, Map.put(payload, "job", fingerprint))

        # The round is no longer pending (it finished, or was re-paired,
        # while this was being asked for): nothing is owed and nothing to
        # mark failed.
        {:error, :not_pending} ->
          :stale

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
