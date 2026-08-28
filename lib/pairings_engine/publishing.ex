defmodule PairingsEngine.Publishing do
  @moduledoc """
  Sending a tournament snapshot to OpenResults.

  The arbiter's machine is the source of truth and this is the only thing
  that leaves it. `PairingsEngine.Snapshot.build/1` decides *what* travels
  (and, just as importantly, what does not - see its own moduledoc); this
  module decides *when*, *whether it arrived*, and *what happens when it did
  not*.

  ## Why there is a queue

  The whole reason the two halves are separate is that an arbiter's tool and
  a spectator's page want opposite things, and the arbiter's side has to keep
  working with no network at all. A chess venue's wifi - school gyms, hotel
  basements - is exactly where somebody is standing when they pair round 5.

  So a publish never blocks and never fails loudly. It records an intent and
  returns. `drain/0` sends what is due, and a send that does not land leaves
  the row in place with a longer backoff and an error an arbiter can read.

  ## The queue holds intents, not payloads

  One row per tournament, enforced by a unique index. A snapshot is a whole
  document rather than a delta, so five publishes stacked up behind a dead
  connection are not five things to send - they are one send of the current
  state. The payload is therefore rebuilt at send time, which is smaller,
  and more correct than replaying a body that was true twenty minutes ago.

  A consequence worth stating: **a publish that has not gone out yet carries
  no promise about what it will contain.** It will contain whatever is true
  when it leaves. That is the behaviour an arbiter wants (the page should
  catch up to the hall, not to a moment in the past) but it means "queued"
  is not "pending delivery of this version".

  ## Configuration

  Endpoint and token live in the `meta` table rather than in application
  config, because the arbiter types them in once on their own machine. The
  token is a shared secret: anything holding it can publish, and the server
  compares it in constant time and fails closed.
  """

  import Ecto.Query

  alias PairingsEngine.{Repo, Snapshot}
  alias PairingsEngine.Publishing.QueueEntry
  alias PairingsEngine.Tournaments.Tournament

  require Logger

  # Backoff, in seconds, indexed by the number of failures so far. A venue's
  # wifi comes back in minutes, not milliseconds, so the early steps are not
  # aggressive; the tail is capped so a publish left overnight still goes out
  # in the morning without anyone touching it.
  @backoff [30, 60, 120, 300, 600, 1_800, 3_600]
  @max_backoff 3_600

  @doc "The configured OpenResults base URL, or nil."
  def endpoint, do: meta_get("openresults_endpoint")

  @doc "The configured ingest token, or nil."
  def token, do: meta_get("openresults_token")

  def put_endpoint(url) when is_binary(url), do: meta_put("openresults_endpoint", normalize(url))
  def put_endpoint(nil), do: meta_delete("openresults_endpoint")

  def put_token(token) when is_binary(token),
    do: meta_put("openresults_token", String.trim(token))

  def put_token(nil), do: meta_delete("openresults_token")

  @doc """
  Whether publishing can be attempted at all.

  Both halves are required. A configured endpoint with no token would fail
  every send with a 401, which is a worse experience than saying so up front.
  """
  def configured? do
    is_binary(endpoint()) and endpoint() != "" and is_binary(token()) and token() != ""
  end

  @doc """
  Records that `tournament` should be published, and returns immediately.

  Idempotent: enqueueing a tournament that is already queued leaves the
  existing row alone rather than resetting its backoff, so a burst of result
  entries against a dead endpoint does not restart the retry clock over and
  over and turn a backoff into a hot loop.

  A tournament that has not opted in is ignored, silently and on purpose -
  callers are event handlers all over the app and none of them should have to
  ask first.
  """
  def enqueue(%Tournament{publish_to_openresults: true, id: id}) do
    now = DateTime.utc_now()

    Repo.insert!(
      %QueueEntry{tournament_id: id, next_attempt_at: now},
      on_conflict: :nothing,
      conflict_target: :tournament_id
    )

    :ok
  end

  def enqueue(%Tournament{}), do: :ok

  @doc """
  Same as `enqueue/1`, from an id.

  This is what `Tournaments.broadcast_tournament_change/2` calls, so every
  write in the application enqueues without any call site having to remember
  to. The opt-in is checked here rather than by the caller: the flag is false
  for almost every tournament, and this then costs one primary-key lookup and
  writes nothing.
  """
  def enqueue_id(tournament_id) do
    opted_in? =
      Repo.one(
        from t in Tournament,
          where: t.id == ^tournament_id,
          select: t.publish_to_openresults
      )

    if opted_in? == true do
      Repo.insert!(
        %QueueEntry{tournament_id: tournament_id, next_attempt_at: DateTime.utc_now()},
        on_conflict: :nothing,
        conflict_target: :tournament_id
      )
    end

    :ok
  rescue
    # Publishing is a courtesy. It must never be able to stop an arbiter
    # entering a result, and because this hangs off the funnel EVERY write
    # goes through, an exception here would do exactly that.
    #
    # Not hypothetical. On 2026-08-28 a deploy landed this code before its
    # migration and every write in the application raised
    # `no such column: t0.publish_to_openresults`. The site was up and
    # nothing could be saved. That window - code ahead of schema - exists on
    # any deploy that does the two in that order, so the guard belongs here
    # rather than in a deploy checklist.
    #
    # Rescuing everything rather than a specific error is deliberate: the
    # set of ways a database can be unavailable is not one this function
    # should claim to know, and the correct response to all of them is the
    # same - log it, let the write through, publish later.
    error ->
      Logger.warning(
        "could not queue a publish for tournament #{tournament_id}: " <>
          Exception.message(error)
      )

      :ok
  end

  @doc "Queue rows that are due to be attempted now, oldest first."
  def due(now \\ DateTime.utc_now()) do
    Repo.all(
      from q in QueueEntry,
        where: is_nil(q.next_attempt_at) or q.next_attempt_at <= ^now,
        order_by: [asc: q.next_attempt_at, asc: q.id],
        preload: [:tournament]
    )
  end

  @doc "The queue row for `tournament_id`, or nil."
  def queued(tournament_id) do
    Repo.one(from q in QueueEntry, where: q.tournament_id == ^tournament_id)
  end

  @doc "How many publishes are waiting."
  def pending_count, do: Repo.aggregate(QueueEntry, :count, :id)

  @doc """
  Sends every due publish.

  Returns `{sent, failed}`. Never raises: this runs from a timer, and a
  publish failing is an ordinary event rather than an exceptional one.
  """
  def drain do
    Enum.reduce(due(), {0, 0}, fn entry, {sent, failed} ->
      case publish(entry.tournament) do
        {:ok, _} ->
          Repo.delete!(entry)
          {sent + 1, failed}

        {:error, reason} ->
          record_failure(entry, reason)
          {sent, failed + 1}
      end
    end)
  end

  @doc """
  Builds and sends `tournament`'s snapshot right now, bypassing the queue.

  This is what the "Publish now" button calls. It returns the real result so
  the arbiter sees what happened rather than watching a queue depth.
  """
  def publish(%Tournament{} = tournament) do
    cond do
      not configured?() ->
        {:error, "no OpenResults server is configured"}

      not tournament.publish_to_openresults ->
        {:error, "this tournament is not set to publish"}

      true ->
        tournament |> Snapshot.build() |> post()
    end
  end

  @doc """
  Checks the address and token without publishing anything.

  Deliberately a GET against a token-gated route with a slug that cannot
  exist, rather than a POST of a real snapshot. A "test" button that
  published would be a trap: the arbiter presses it to find out whether the
  settings work and a tournament goes live as a side effect.

  Reading the outcome from the status code is the point of the probe:

    * 401 - the address is right and the token is wrong
    * 404 - the token was accepted; the route exists and the slug does not
    * anything else, or a transport error - the address is wrong

  Returns `{:ok, message}` or `{:error, message}`, both already in words an
  arbiter can act on.
  """
  def check do
    cond do
      is_nil(endpoint()) or endpoint() == "" -> {:error, "No address is set."}
      is_nil(token()) or token() == "" -> {:error, "No token is set."}
      true -> do_check()
    end
  end

  defp do_check do
    url =
      endpoint()
      |> String.trim_trailing("/")
      |> Kernel.<>(
        "/api/tournaments/connection-test-#{System.unique_integer([:positive])}/history"
      )

    request =
      Req.new(
        url: url,
        # Required by that route. Without it the server answers 400 before it
        # ever looks the slug up, and the first version of this check read
        # that as "not an OpenResults server" - telling an arbiter their
        # correct settings were wrong. Found by running it against a real
        # one rather than against a stub.
        params: [at: DateTime.to_iso8601(DateTime.utc_now())],
        auth: {:bearer, token()},
        receive_timeout: 15_000,
        retry: false
      )

    case Req.get(maybe_put_test_plug(request)) do
      {:ok, %Req.Response{status: 404}} ->
        {:ok, "Connected. The address and token are both accepted."}

      {:ok, %Req.Response{status: 401}} ->
        {:error, "Reached the server, but it rejected the token."}

      {:ok, %Req.Response{status: status}} ->
        {:error, "Reached #{url} and it answered #{status}, which is not an OpenResults server."}

      {:error, reason} ->
        {:error, describe_transport(reason)}
    end
  end

  defp post(payload) do
    url = endpoint() |> String.trim_trailing("/") |> Kernel.<>("/api/snapshots")

    request =
      Req.new(
        url: url,
        json: payload,
        auth: {:bearer, token()},
        # A publish is a background nicety, not something anyone waits on.
        # Failing fast and retrying later beats holding a connection open
        # while an arbiter is trying to pair.
        receive_timeout: 15_000,
        # Req's own retries are off: this module already has a queue with a
        # backoff and a visible error, and two retry mechanisms stacked would
        # multiply the delay an arbiter sees without telling them why.
        retry: false
      )

    case Req.post(maybe_put_test_plug(request)) do
      {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
        {:ok, resp.body}

      {:ok, %Req.Response{status: 401}} ->
        {:error, "the server rejected the token (401)"}

      {:ok, %Req.Response{status: 404}} ->
        {:error, "no snapshot endpoint at #{url} (404) - check the address"}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "the server answered #{status}: #{describe_body(body)}"}

      {:error, reason} ->
        {:error, describe_transport(reason)}
    end
  end

  # In prod nothing is configured, so the request goes out over the network.
  # In tests `config/test.exs` points this at a `Req.Test` stub name - the
  # same convention `PairingsEngine.Keycloak` already follows.
  defp maybe_put_test_plug(request) do
    case Application.get_env(:pairings_engine, :publishing_req_plug) do
      nil -> request
      name -> Req.merge(request, plug: {Req.Test, name})
    end
  end

  defp describe_body(%{"error" => error}) when is_binary(error), do: error
  defp describe_body(body) when is_binary(body), do: String.slice(body, 0, 200)
  defp describe_body(body), do: body |> inspect() |> String.slice(0, 200)

  defp describe_transport(%Req.TransportError{reason: :timeout}), do: "connection timed out"
  defp describe_transport(%Req.TransportError{reason: :closed}), do: "connection closed"

  defp describe_transport(%Req.TransportError{reason: :nxdomain}),
    do: "the address did not resolve"

  defp describe_transport(%Req.TransportError{reason: :econnrefused}),
    do: "the connection was refused - is the server running?"

  defp describe_transport(%Req.TransportError{reason: reason}),
    do: "could not connect (#{inspect(reason)})"

  defp describe_transport(reason), do: inspect(reason)

  defp record_failure(entry, reason) do
    attempts = entry.attempts + 1
    now = DateTime.utc_now()

    Logger.warning("OpenResults publish failed for tournament #{entry.tournament_id}: #{reason}")

    entry
    |> Ecto.Changeset.change(%{
      attempts: attempts,
      last_error: reason,
      last_attempt_at: now,
      next_attempt_at: DateTime.add(now, backoff_for(attempts), :second)
    })
    |> Repo.update!()
  end

  @doc "Seconds to wait before attempt number `attempts + 1`."
  def backoff_for(attempts) when attempts >= 1 do
    Enum.at(@backoff, attempts - 1, @max_backoff)
  end

  ## ---------- meta ----------

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

  # A pasted address is as likely to be "openresults.example.com" or to carry
  # a trailing slash as it is to be exactly right. Normalising here means the
  # error an arbiter sees is about the server rather than about their typing.
  defp normalize(url) do
    url = String.trim(url) |> String.trim_trailing("/")

    if String.starts_with?(url, ["http://", "https://"]) do
      url
    else
      "https://" <> url
    end
  end
end
