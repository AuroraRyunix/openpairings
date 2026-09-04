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

  ## Two questions, two secrets

  The ingest token above is machine-wide and answers one question: *may this
  machine talk to this server*. It cannot answer the second one - *may it
  touch THIS tournament* - and for a while nothing did. Anything holding the
  token could overwrite any tournament on the server, and nothing could take
  a published tournament down at all: turning the switch off stopped future
  publishes and left player names, ratings, clubs and federations public
  forever, remediable only by SSH and SQLite.

  `tournaments.openresults_key` answers the second question. It is random,
  minted here at the FIRST publish (`ensure_key/1`), sent with every publish
  afterwards, and required by the server to publish again or to delete
  (`take_down/1`).

  Minted at first publish rather than at creation because a key is a claim
  on a slug the server has never heard of until something is actually sent;
  and never regenerated, because the server binds the slug to the first key
  it sees and a fresh key would lock this machine out of its own tournament.
  The one thing that clears it is `take_down/1`, which removed the thing the
  key was a claim on.

  ### The key travels in a header, not in the payload

  This is not a style choice. `OpenResultsWeb.SnapshotController.create/2`
  stores `conn.body_params` verbatim, and `GET /api/tournaments/:slug` hands
  that stored document straight back on an OPEN route. A key inside the
  snapshot body would therefore be published to the public internet by the
  very request that established it. It goes in the `x-openresults-key`
  request header, which the server reads and does not store.

  ## Import carries the key, and import does not adopt it

  `PairingsEngine.TournamentExport` puts the key in the backup envelope on
  purpose - rebuilding a laptop from a backup has to recover the ability to
  manage what that laptop published, and a key left behind strands a
  published tournament forever.

  But an import must not adopt it. Two people importing the same file would
  both believe they own the tournament, both publish to the same slug, and
  either could delete the other's work. So the imported key lands dormant in
  `tournaments.openresults_claim`, which nothing here reads, and becomes real
  only when an arbiter chooses it (`adopt_claim/1`) or throws it away
  (`discard_claim/1`). Starting fresh is the default in the sense that
  matters: an imported copy that is never adopted publishes to a new slug
  under a new key, i.e. it is a different tournament.

  ## The other direction

  `PairingsEngine.Registrations` pulls entries back from the same server.
  That is a different feature with a different failure story - a pull is
  something an arbiter asks for and waits on, so it reports rather than
  queues - but it is the same server, the same token and the same address.
  `request/2`, `describe_transport/1` and `describe_body/1` are public for
  exactly that: one place that knows how to reach OpenResults, so a second
  configuration cannot drift into existence beside this one.
  """

  import Ecto.Query

  alias PairingsEngine.{Meta, Repo, Snapshot, Tournaments}
  alias PairingsEngine.Publishing.{Drain, QueueEntry}
  alias PairingsEngine.Tournaments.Tournament

  require Logger

  # Backoff, in seconds, indexed by the number of failures so far. A venue's
  # wifi comes back in minutes, not milliseconds, so the early steps are not
  # aggressive; the tail is capped so a publish left overnight still goes out
  # in the morning without anyone touching it.
  @backoff [30, 60, 120, 300, 600, 1_800, 3_600]
  @max_backoff 3_600

  # Where the per-tournament key travels. A header rather than a body field,
  # because the server stores the body verbatim and serves it back openly -
  # see the moduledoc.
  @key_header "x-openresults-key"

  @doc """
  The header a tournament key travels in.

  Public so `PairingsEngine.Registrations` can send it on the pull without
  writing the name down a second time. A header name that disagrees between
  two call sites in the same app is the same class of bug as one that
  disagrees between the two repos - and that one nearly shipped.
  """
  def key_header, do: @key_header

  # 256 bits. `public_slug` next door is 72, which is right for a link that
  # only has to resist enumeration; this one authorises deleting a published
  # tournament and every snapshot behind it, so it is sized against guessing
  # rather than against scraping.
  @key_bytes 32

  @doc """
  Where this machine SENDS to, or nil.

  Not necessarily where spectators go - see `public_base/0`.
  """
  def endpoint, do: meta_get("openresults_endpoint")

  @doc """
  The address spectators are given, falling back to `endpoint/0`.

  ## Why these are two settings

  They were one field doing two jobs, and it cost something measurable. On
  the hosted box both applications share a machine, and the publishing check
  still reported ~40 ms - because the one address was the PUBLIC one, so
  every publish left the server, went out to Cloudflare, and came back in
  through the tunnel to reach a process one loopback hop away.

  Pointing that field at `localhost` was the obvious fix and would have
  broken the site: `PairingsEngineWeb.PublicLink` builds every share link,
  QR code and printed URL from the same value, and a spectator cannot follow
  `http://localhost:4004`.

  So: `endpoint/0` is the machine's business - the address it posts to, free
  to be loopback on a box that hosts both. `public_base/0` is what people are
  handed. Leaving the second unset keeps the old behaviour exactly, which is
  what every existing installation wants and gets without touching anything.
  """
  def public_base do
    case stored_public_base() do
      value when is_binary(value) -> value
      nil -> endpoint()
    end
  end

  @doc """
  The public address as actually STORED, without the fallback - nil when none
  is set.

  Two callers need this and both would get the wrong answer from
  `public_base/0`: a settings form would show the send target in a box
  nobody filled in (and saving would make that fallback permanent), and
  `mix pairings.publishing --ensure` would think every installation already
  has a public address and never fill the blank it exists to fill.
  """
  def stored_public_base do
    case meta_get("openresults_public_base") do
      value when is_binary(value) and value != "" -> value
      _unset -> nil
    end
  end

  @doc "The configured ingest token, or nil."
  def token, do: meta_get("openresults_token")

  # Blank clears, rather than storing what `normalize/1` makes of nothing.
  # It turns "" into "https://", which is not an address but IS a non-empty
  # string - so `configured?/0` would call the installation set up, and every
  # send would fail against a URL with no host. The settings form already
  # passes blanks through `blank_to_nil/1`, but that guard lives in the
  # caller, and these are public functions.
  def put_endpoint(url) when is_binary(url), do: put_url("openresults_endpoint", url)
  def put_endpoint(nil), do: meta_delete("openresults_endpoint")

  def put_public_base(url) when is_binary(url), do: put_url("openresults_public_base", url)
  def put_public_base(nil), do: meta_delete("openresults_public_base")

  defp put_url(key, url) do
    case String.trim(url) do
      "" -> meta_delete(key)
      trimmed -> meta_put(key, normalize(trimmed))
    end
  end

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

  Also nudges `PairingsEngine.Publishing.Drain` to send it soon rather than
  waiting for its next tick - see that module's moduledoc. The nudge is an
  async, debounced cast; it does not change what "returns immediately" means
  here.
  """
  def enqueue(%Tournament{publish_to_openresults: true, id: id}) do
    now = DateTime.utc_now()

    Repo.insert!(
      %QueueEntry{tournament_id: id, next_attempt_at: now},
      on_conflict: :nothing,
      conflict_target: :tournament_id
    )

    Drain.nudge()
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

      Drain.nudge()
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
        # The key is minted here rather than at the call site so that every
        # path into a publish - the button, the drain, a future one - gets it
        # without having to know it exists.
        tournament = ensure_key(tournament)
        tournament |> Snapshot.build() |> post(tournament.openresults_key)
    end
  end

  @doc """
  Returns `tournament` with an `openresults_key`, minting one if it has none.

  Idempotent and non-destructive: a tournament that already has a key is
  handed back untouched, and the write that mints one is guarded by
  `is_nil(openresults_key)` in the WHERE clause, so two publishes racing
  cannot end with one of them holding a key the server will never accept
  again. The value is then read back from the database rather than assumed,
  which is what makes that guard mean anything.

  Deliberately silent: no broadcast, no `updated_at` bump. A broadcast would
  re-enter `Tournaments.broadcast_tournament_change/2`, which enqueues a
  publish, from inside a publish - and a key is not a change to the
  tournament that anybody watching the page wants to hear about.
  """
  @spec ensure_key(Tournament.t()) :: Tournament.t()
  def ensure_key(%Tournament{openresults_key: key} = tournament)
      when is_binary(key) and key != "",
      do: tournament

  def ensure_key(%Tournament{} = tournament) do
    Repo.update_all(
      from(t in Tournament, where: t.id == ^tournament.id and is_nil(t.openresults_key)),
      set: [openresults_key: generate_key()]
    )

    stored =
      Repo.one(from t in Tournament, where: t.id == ^tournament.id, select: t.openresults_key)

    %{tournament | openresults_key: stored}
  end

  @doc "A fresh per-tournament publishing key (256 bits, url-safe)."
  def generate_key, do: :crypto.strong_rand_bytes(@key_bytes) |> Base.url_encode64(padding: false)

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

  @doc """
  A `Req` request for `path` on the configured server, carrying the token.

  The one builder for anything that talks to OpenResults. `path` is joined
  onto the configured address, which is already normalised by
  `put_endpoint/1`, so a caller passes `"/api/tournaments/x/registrations"`
  and never has to think about trailing slashes or schemes.

  `opts` are merged last and may override anything here - a POST passes
  `json:`, a longer read passes its own `receive_timeout`.
  """
  @spec request(String.t(), keyword()) :: Req.Request.t()
  def request(path, opts \\ []) when is_binary(path) do
    Req.new(
      url: endpoint() |> String.trim_trailing("/") |> Kernel.<>(path),
      auth: {:bearer, token()},
      # Nothing in the hall waits on a call to OpenResults, and an arbiter
      # who pressed a button would rather be told it did not work than watch
      # a spinner while the venue's wifi decides.
      receive_timeout: 15_000,
      # Req's own retries are off everywhere: publishing has a queue with a
      # backoff and a visible error, and a pull is a button the arbiter can
      # press again. Two retry mechanisms stacked would multiply the delay
      # they see without telling them why.
      retry: false
    )
    |> Req.merge(opts)
    |> maybe_put_test_plug()
  end

  # Built through `request/2` rather than its own `Req.new`, which it used to
  # be. Two builders had already drifted once (the timeout and retry comments
  # were duplicated word for word) and adding the key header to only one of
  # them is exactly the kind of drift that would ship a publish the server
  # refuses.
  defp post(payload, key) do
    request = request("/api/snapshots", json: payload, headers: [{@key_header, key}])
    url = URI.to_string(request.url)

    case Req.post(request) do
      {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
        # Stamped here rather than derived from an empty queue: an empty queue
        # means either "everything has been sent" or "nothing was ever
        # queued", and those look identical from outside.
        #
        # The SIZE goes with it. A snapshot is a whole document rather than a
        # delta, so it is the one number that says how much this machine
        # actually pushes per round - and it moves: publishing the tie-break
        # working multiplied it by about 3.4 on a large event, which nobody
        # would have noticed from a queue depth.
        record_publish(payload_bytes(payload))
        {:ok, resp.body}

      {:ok, %Req.Response{status: 401}} ->
        {:error, "the server rejected the token (401)"}

      # The key was refused. Said in terms of what actually happened rather
      # than as "403", because the situation it describes is a real one an
      # arbiter can be in - two machines restored from the same backup, or a
      # tournament somebody else already published to this slug - and "check
      # your token" would send them to fix the wrong thing.
      {:ok, %Req.Response{status: 403}} ->
        {:error,
         "the results site says a different machine published this tournament (403) - " <>
           "it will not accept an update from here"}

      {:ok, %Req.Response{status: 404}} ->
        {:error, "no snapshot endpoint at #{url} (404) - check the address"}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "the server answered #{status}: #{describe_body(body)}"}

      {:error, reason} ->
        {:error, describe_transport(reason)}
    end
  end

  @doc """
  Deletes this tournament's published copy from OpenResults.

  The other half of the key. Publishing could always create and overwrite;
  until this existed, nothing could withdraw - turning the switch off stopped
  future publishes and left everything already sent public forever, and what
  was sent carries player names, ratings, clubs and federations.

  Destructive on the server and irreversible from here: the public page, every
  earlier snapshot in that tournament's history, and any entries its form
  collected all go. Nothing on this machine's side of the line is touched
  except the publishing state itself - the tournament, its players and its
  results stay exactly as they are, and so do any registrations already pulled
  down and decided, which are this machine's record of who was admitted.

  Returns `{:ok, message}` or `{:error, message}`, both already in words. On
  failure the tournament is left completely alone: publishing stays on, the
  key stays put, and a retry is just pressing the button again. Treating a
  failed delete as a success is the one outcome that would be actively
  dangerous, because it would tell an arbiter their event was withdrawn while
  it was still up.

  Refused on a read-only tournament - archived, or handed off to another
  copy of the app - by the same `writable/1` its neighbours `adopt_claim/1`
  and `discard_claim/1` use. It was not, for a long time, on the reading
  that this deletes something on somebody else's server rather than writing
  here. But it also clears `openresults_key` and `publish_to_openresults`
  and empties the queue (`forget_published/1`), which are writes to a
  tournament the arbiter has frozen; and it is the destructive first step of
  `rotate_address/1`, which used to run it and then discover that the move
  it existed to enable was refused. A handed-off tournament makes that
  sharper still: the copy actually running the event may be publishing, and
  this copy pulling the event off the results site is exactly the kind of
  thing the lock is for.
  """
  @spec take_down(Tournament.t()) :: {:ok, String.t()} | {:error, String.t()}
  def take_down(%Tournament{} = tournament) do
    cond do
      not configured?() ->
        {:error, "no OpenResults server is configured"}

      refusal = writable_refusal(tournament) ->
        refusal

      not is_binary(tournament.openresults_key) ->
        # No key means nothing was ever published FROM HERE. Refusing rather
        # than sending is the honest answer: without the key the server would
        # refuse anyway, and a machine that could delete a tournament it never
        # published is the hole this whole feature closes.
        {:error, "nothing has been published from this machine for this tournament"}

      true ->
        do_take_down(tournament)
    end
  end

  defp do_take_down(%Tournament{} = tournament) do
    slug = tournament.public_slug

    request =
      request("/api/tournaments/#{URI.encode(slug, &URI.char_unreserved?/1)}",
        headers: [{@key_header, tournament.openresults_key}]
      )

    url = URI.to_string(request.url)

    case Req.delete(request) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        forget_published(tournament)
        {:ok, "Removed from the results site. Publishing is now off for this tournament."}

      {:ok, %Req.Response{status: 401}} ->
        {:error, "the server rejected the token (401)"}

      {:ok, %Req.Response{status: 403}} ->
        {:error,
         "the results site refused this tournament's key (403) - it was published by a " <>
           "different machine, which is the one that can remove it"}

      # NOT treated as "already gone, close enough". A 404 here is genuinely
      # ambiguous - the tournament may not be published, or this server may
      # simply have no takedown route yet - and the two want opposite
      # responses. Guessing "already gone" would clear the local publishing
      # state and tell the arbiter their event was withdrawn while an older
      # server was still serving it.
      {:ok, %Req.Response{status: 404}} ->
        {:error,
         "nothing is published at #{url}, or this results site is too old to remove one (404)"}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "the server answered #{status}: #{describe_body(body)}"}

      {:error, reason} ->
        {:error, describe_transport(reason)}
    end
  end

  # Ordering matters. `publish_to_openresults` goes false FIRST, so that the
  # broadcast at the end - which funnels into `enqueue_id/1` - finds a
  # tournament that has opted out and queues nothing. Getting this backwards
  # would re-publish the tournament seconds after deleting it.
  #
  # The key is cleared with it. It was a claim on something that no longer
  # exists, and keeping it would leave the arbiter holding a secret whose only
  # remaining effect is to be leaked. Publishing again later mints a new one,
  # which is a fresh claim on a slug the server has forgotten - so "never
  # regenerated behind the arbiter's back" still holds: the only thing that
  # ever retires a key is the arbiter deleting the thing it was for.
  defp forget_published(%Tournament{} = tournament) do
    {:ok, updated} =
      tournament
      |> Ecto.Changeset.change(publish_to_openresults: false, openresults_key: nil)
      |> Repo.update()

    Repo.delete_all(from q in QueueEntry, where: q.tournament_id == ^tournament.id)
    Tournaments.broadcast_tournament_change(updated.id, :settings)

    updated
  end

  ## ---------- is this thing on ----------

  @doc """
  Everything a connection indicator needs, in one call.

  `state` is one of:

    * `:unconfigured` - no address or no token; nothing will ever be sent
    * `:connected`    - the results site answered and accepted the token
    * `:refused`      - it answered, and did not accept the token
    * `:unreachable`  - it did not answer

  `latency_ms` is the round trip for the check, present only when something
  answered - on a machine sharing a box with the results site it is a
  single-digit number, and saying "2 ms" is a more convincing "yes, really
  connected" than a green dot on its own.

  `pending` is how many tournaments are queued. It is the difference between
  "connected" and "connected and currently sending", which is the thing an
  arbiter actually wants to see after entering a result.

  ## Why this makes a request every time

  Because the question is "can this machine publish RIGHT NOW", and a cached
  answer to that is a different and much less useful question. The caller
  decides how often to ask; `check/0`'s own timeout bounds how long it takes
  to find out it cannot.
  """
  @spec status() :: %{
          state: :unconfigured | :connected | :refused | :unreachable,
          message: String.t(),
          latency_ms: non_neg_integer() | nil,
          endpoint: String.t() | nil,
          pending: non_neg_integer(),
          last_published_at: DateTime.t() | nil
        }
  def status do
    started = System.monotonic_time(:millisecond)
    result = check()
    elapsed = System.monotonic_time(:millisecond) - started

    {state, message, latency} =
      case result do
        {:ok, message} ->
          {:connected, message, elapsed}

        {:error, "No address is set." = message} ->
          {:unconfigured, message, nil}

        {:error, "No token is set." = message} ->
          {:unconfigured, message, nil}

        {:error, message} ->
          # "Reached the server, but it rejected the token" is a working
          # network and a wrong secret, which is a different problem from a
          # server that is not there - and the two want different fixes, so
          # they get different words and different colours.
          if String.starts_with?(message, "Reached"),
            do: {:refused, message, elapsed},
            else: {:unreachable, message, nil}
      end

    %{
      state: state,
      message: message,
      latency_ms: latency,
      endpoint: endpoint(),
      pending: pending_count(),
      last_published_at: last_published_at(),
      last_publish_bytes: last_publish_bytes()
    }
  end

  @doc """
  When this machine last successfully sent anything, or nil.

  Stored rather than derived: a queue that is empty means either "everything
  has been sent" or "nothing was ever queued", and those look identical from
  the outside. An arbiter looking at an indicator wants to know which.
  """
  @spec last_published_at() :: DateTime.t() | nil
  def last_published_at do
    with stamp when is_binary(stamp) <- meta_get("openresults_last_publish_at"),
         {:ok, at, _} <- DateTime.from_iso8601(stamp) do
      at
    else
      _ -> nil
    end
  end

  defp record_publish(bytes) do
    meta_put(
      "openresults_last_publish_at",
      DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    )

    if is_integer(bytes), do: meta_put("openresults_last_publish_bytes", to_string(bytes))
  end

  # What went over the wire, near enough. Re-encoding to measure costs one
  # more pass over a document Req is about to encode anyway - worth it for a
  # number an operator can act on, and cheap next to the HTTP round trip it
  # sits beside. Rescued because a size is a nicety and a publish is not:
  # nothing here may turn a successful send into a failed one.
  defp payload_bytes(payload) do
    payload |> Jason.encode!() |> byte_size()
  rescue
    _ -> nil
  end

  @doc """
  How big the last successfully published document was, in bytes, or nil.

  A snapshot is the whole tournament rather than a delta, so this is the one
  figure that says what a round actually costs to publish - and it is not
  static: it grew about 3.4x on a large event when the tie-break working
  started travelling.
  """
  @spec last_publish_bytes() :: pos_integer() | nil
  def last_publish_bytes do
    case meta_get("openresults_last_publish_bytes") do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {bytes, ""} when bytes >= 0 -> bytes
          _ -> nil
        end

      _ ->
        nil
    end
  end

  ## ---------- reconciling intent with reality ----------

  @doc """
  Enqueues a publish for every tournament that is switched on but has never
  actually published.

  A tournament with `publish_to_openresults` set and no `openresults_key` is
  a promise nothing has kept. The arbiter's Settings page says it is
  published and hands out a share link; the results site has never heard of
  it, so that link 404s. A link that looks right and does not work is worse
  than no link, and nothing in the ordinary flow recovers from it - the queue
  only holds what somebody put there, and the reason it is empty is precisely
  that the enqueue never happened.

  Three ways to arrive in that state, none of them exotic:

    * the 2026-08-29 migration, which switched publishing on for every
      tournament that had local public pages. It is raw SQL and cannot
      enqueue anything;
    * `enqueue_id/1` failing. It rescues and returns `:ok` deliberately - a
      publish must never take down the write that triggered it - which means
      a lost intent is silent by design;
    * a database restored from a backup taken after the switch but before the
      send.

  Run on boot rather than on every drain. This is a reconciliation, not a
  poll: the states it fixes are created by events the app already knows
  about, and a restart is where a machine that has been carrying one has its
  next honest look at itself.

  Skipped entirely when no results site is configured, since a queue entry
  that can only fail is not a repair.
  """
  @spec backfill() :: non_neg_integer()
  def backfill do
    if configured?() do
      ids =
        Repo.all(
          from t in Tournament,
            where:
              t.publish_to_openresults == true and is_nil(t.openresults_key) and
                is_nil(t.deleted_at),
            select: t.id
        )

      Enum.each(ids, &enqueue_id/1)

      if ids != [] do
        Logger.info("OpenResults: queued #{length(ids)} tournament(s) that had never published")
      end

      length(ids)
    else
      0
    end
  end

  ## ---------- moving to a new address ----------

  @doc """
  Moves `tournament` to a fresh address on the results site, revoking the old
  one.

  ## Why this is not just a slug rotation

  `Tournaments.rotate_public_slug/1` changes this machine's idea of the
  address and nothing else. While the local public pages existed that WAS
  revocation - the pages 404'd the moment the slug changed, because they were
  served from the same database the slug lived in.

  With those pages gone the slug is an address on somebody else's server, and
  rotating it alone does the opposite of what the button promises: the leaked
  link keeps working, because the copy at the old address is still there and
  this machine has just forgotten how to reach it. The next publish then
  creates a SECOND copy at the new address, so the tournament is now public
  twice and the arbiter can no longer take down the one they were trying to
  revoke. The key that authorised it has been left pointing at the wrong slug.

  So revoking means: delete the old copy, then move, then publish again.

  ## Ordering, and what a partial failure leaves behind

  The takedown goes first because it is the part the arbiter actually asked
  for. If it fails, nothing else happens and the address is unchanged - a
  failed revocation must not look like a successful one.

  If it succeeds and the re-publish then fails, the tournament is at its new
  address with nothing sent yet. That is a good state to fail into: the
  leaked link is dead, which was the request, and publishing retries by
  itself. The caller is told, because "revoked, not yet re-published" and
  "revoked and back up" are different sentences to put in front of an
  arbiter.

  A tournament that is not published has nothing to revoke and nothing to
  re-send, so it just moves.

  ## The refusal comes first, before anything is destroyed

  The ordering above is only safe while the steps after the takedown cannot
  fail for a reason the takedown could have known about. One could, and did.
  `Tournaments.rotate_public_slug/1` is gated on
  `Tournaments.ensure_writable/1` and `take_down/1` was not - so on a frozen
  tournament (archived, and later handed off as well) this deleted the
  published copy from the server, cleared the key that was the only way to
  manage it, emptied the queue, and THEN refused to move. The destructive
  half of an operation the caller was told had failed, with nothing to roll
  back to: no retry can put the tournament back at the old address, because
  the key that authorised it is gone.

  So writability is checked here, once, before either branch begins. It is
  checked again inside `take_down/1` and again inside
  `rotate_public_slug/1` - the gate belongs on each of those in its own
  right, and a caller that reaches one of them directly has to meet it too.
  """
  @spec rotate_address(Tournament.t()) :: {:ok, Tournament.t(), String.t()} | {:error, String.t()}
  def rotate_address(%Tournament{} = tournament) do
    with :ok <- writable(tournament) do
      do_rotate_address(tournament)
    end
  end

  defp do_rotate_address(%Tournament{} = tournament) do
    if published?(tournament) do
      with {:ok, _msg} <- take_down(tournament) do
        # `take_down/1` switched publishing off and dropped the key, which is
        # right for a takedown and wrong for a move - so it is turned back on
        # here, deliberately, on a tournament that now has a new address and
        # will therefore mint a new key rather than reuse the revoked one.
        tournament.id
        |> Tournaments.get_tournament!()
        |> rotate_and_republish()
      end
    else
      case Tournaments.rotate_public_slug(tournament) do
        {:ok, moved} ->
          {:ok, moved, "This tournament has a new address."}

        # Reached only by losing a race with a hand-off or an archive between
        # the check above and here. Worded rather than passed through: this
        # function's contract is a sentence the caller renders, and the bare
        # `:archived` that used to come out of here was neither.
        {:error, reason} when is_atom(reason) ->
          {:error, refusal_words(reason)}

        {:error, %Ecto.Changeset{}} ->
          {:error, "this tournament could not be moved to a new address"}
      end
    end
  end

  defp rotate_and_republish(%Tournament{} = taken_down) do
    with {:ok, moved} <- Tournaments.rotate_public_slug(taken_down),
         {:ok, live} <- Tournaments.set_publish_to_openresults(moved, true) do
      case publish(live) do
        {:ok, _body} ->
          {:ok, Tournaments.get_tournament!(live.id),
           "The old link is dead and this tournament is published at a new address."}

        {:error, reason} ->
          {:ok, Tournaments.get_tournament!(live.id),
           "The old link is dead. Publishing to the new address did not go through " <>
             "(#{reason}) - it will be retried."}
      end
    else
      # The takedown already happened, so the old link is gone either way and
      # saying otherwise would be a lie. Reported as an error because the
      # tournament is now in a state the arbiter did not ask for.
      {:error, %Ecto.Changeset{}} ->
        {:error, "the old link was revoked, but this tournament could not be moved"}

      {:error, reason} ->
        {:error, "the old link was revoked, but the move failed: #{inspect(reason)}"}
    end
  end

  ## ---------- a key carried in from a backup ----------

  @doc """
  The dormant claim an imported backup left on `tournament`, or nil.

  `%{key: ..., slug: ..., endpoint: ...}` with atom keys - the column stores
  string keys, and every caller here is rendering a sentence or building a
  changeset, so the shape is normalised in one place rather than at each
  `Map.get(claim, "slug")`.
  """
  @spec claim(Tournament.t()) :: %{key: String.t(), slug: String.t(), endpoint: String.t()} | nil
  def claim(%Tournament{openresults_claim: %{} = claim}) do
    with key when is_binary(key) and key != "" <- Map.get(claim, "key"),
         slug when is_binary(slug) and slug != "" <- Map.get(claim, "slug") do
      %{key: key, slug: slug, endpoint: Map.get(claim, "endpoint") || ""}
    else
      # A hand-edited or truncated backup. Nothing to offer, and nothing that
      # should look like an offer.
      _unusable -> nil
    end
  end

  def claim(%Tournament{}), do: nil

  @doc """
  Takes over the published tournament an imported backup carried a key for.

  This is the deliberate act the import deliberately does not perform. It
  moves the file's key and the address it belongs to onto this row, so this
  copy publishes to - and can delete - the tournament already sitting at that
  address, and it takes this copy's own public link with it: the slug IS the
  address, so a takeover that left the slug alone would publish to a second
  tournament while claiming to have taken over the first.

  Refused when this tournament already has a key of its own. That would mean
  abandoning a published copy this machine is responsible for in order to
  claim a different one - two published tournaments, one of them now
  unmanageable. `take_down/1` first, then this.

  Refused, too, when the slug is already in use here: `tournaments.public_slug`
  is uniquely indexed, and two local rows publishing to one address is the
  same double-ownership this whole mechanism exists to prevent, just inside
  one database.
  """
  @spec adopt_claim(Tournament.t()) :: {:ok, Tournament.t()} | {:error, String.t()}
  def adopt_claim(%Tournament{} = tournament) do
    with :ok <- writable(tournament),
         :ok <- no_key_of_its_own(tournament),
         %{key: key, slug: slug} <- claim(tournament) do
      tournament
      |> Ecto.Changeset.change(
        openresults_key: key,
        public_slug: slug,
        openresults_claim: nil
      )
      |> Ecto.Changeset.unique_constraint(:public_slug)
      |> Repo.update()
      |> case do
        {:ok, updated} ->
          Tournaments.broadcast_tournament_change(updated.id, :settings)
          {:ok, updated}

        {:error, _changeset} ->
          {:error,
           "another tournament on this machine already publishes to that address - " <>
             "remove that one from the results site first"}
      end
    else
      {:error, message} when is_binary(message) -> {:error, message}
      nil -> {:error, "this tournament is not carrying a publishing key from a backup"}
    end
  end

  @doc """
  Throws the imported key away, leaving the tournament a fresh one.

  The other branch of the same choice, and the one that is safe to take by
  mistake: this copy keeps its own new link, and publishing it mints a new
  key against a new address. It costs the ability to ever manage the copy the
  backup came from, which is why it is confirmed rather than silent.
  """
  @spec discard_claim(Tournament.t()) :: {:ok, Tournament.t()} | {:error, String.t()}
  def discard_claim(%Tournament{} = tournament) do
    with :ok <- writable(tournament) do
      tournament
      |> Ecto.Changeset.change(openresults_claim: nil)
      |> Repo.update()
      |> case do
        {:ok, updated} ->
          Tournaments.broadcast_tournament_change(updated.id, :settings)
          {:ok, updated}

        {:error, _changeset} ->
          {:error, "could not discard the key"}
      end
    end
  end

  defp no_key_of_its_own(%Tournament{} = tournament) do
    if published?(tournament) do
      {:error,
       "this tournament has already published under a key of its own - remove it from the " <>
         "results site first, then take the other one over"}
    else
      :ok
    end
  end

  # `Tournaments.ensure_writable/1` returns a reason atom; every caller here
  # wants words, so they are turned into them once rather than in each
  # LiveView.
  #
  # Both reasons get a clause. With only `:archived` here, a handed-off
  # tournament did not refuse - it raised `CaseClauseError` out of whichever
  # caller had reached this, which is a 500 where a sentence was meant to be.
  # An exhaustive `case` over a gate that grows is a trap; it is left
  # exhaustive on purpose, so a third reason breaks a test rather than a
  # page.
  # The same refusal as a value a `cond` can bind - `nil` when the write may
  # go ahead. Mirrors `Tournaments.write_refused/1`, for the guards here that
  # are `cond`s rather than `with`s.
  defp writable_refusal(%Tournament{} = tournament) do
    case writable(tournament) do
      :ok -> nil
      {:error, _message} = refusal -> refusal
    end
  end

  defp writable(%Tournament{} = tournament) do
    case Tournaments.ensure_writable(tournament) do
      :ok -> :ok
      {:error, reason} -> {:error, refusal_words(reason)}
    end
  end

  # Both reasons get a clause. While only `:archived` had one, a handed-off
  # tournament did not refuse here - it raised `CaseClauseError` out of
  # whichever caller had reached the gate, which is a 500 where a sentence
  # was meant to be. Deliberately not a catch-all: a third reason to refuse
  # a write should break loudly in this one place rather than be worded
  # wrongly in several.
  defp refusal_words(:archived), do: "this tournament is archived and cannot be changed"

  defp refusal_words(:handed_off),
    do: "this tournament has been handed off to another copy of the app - take it back first"

  @doc """
  Whether `tournament` currently has a published copy this machine can manage.

  The gate the Settings page uses to decide whether to offer a takedown at
  all. A tournament that opted in but has never actually sent anything has no
  key and therefore nothing to withdraw.
  """
  @spec published?(Tournament.t()) :: boolean()
  def published?(%Tournament{openresults_key: key}), do: is_binary(key) and key != ""

  # In prod nothing is configured, so the request goes out over the network.
  # In tests `config/test.exs` points this at a `Req.Test` stub name - the
  # same convention `PairingsEngine.Keycloak` already follows.
  defp maybe_put_test_plug(request) do
    case Application.get_env(:pairings_engine, :publishing_req_plug) do
      nil -> request
      name -> Req.merge(request, plug: {Req.Test, name})
    end
  end

  @doc """
  A server's error body, shortened, as something to show an arbiter.
  """
  def describe_body(%{"error" => error}) when is_binary(error), do: error
  def describe_body(body) when is_binary(body), do: String.slice(body, 0, 200)
  def describe_body(body), do: body |> inspect() |> String.slice(0, 200)

  @doc """
  A transport failure in words.

  Public so every OpenResults call phrases a dead network the same way. The
  rule this enforces is that `%Req.TransportError{reason: :econnrefused}`
  never reaches a page: an arbiter cannot act on a struct, and "the
  connection was refused - is the server running?" is the same fact in a
  form they can.
  """
  def describe_transport(%Req.TransportError{reason: :timeout}), do: "connection timed out"
  def describe_transport(%Req.TransportError{reason: :closed}), do: "connection closed"

  def describe_transport(%Req.TransportError{reason: :nxdomain}),
    do: "the address did not resolve"

  def describe_transport(%Req.TransportError{reason: :econnrefused}),
    do: "the connection was refused - is the server running?"

  def describe_transport(%Req.TransportError{reason: reason}),
    do: "could not connect (#{inspect(reason)})"

  def describe_transport(reason), do: inspect(reason)

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
  #
  # Thin delegation to `PairingsEngine.Meta` - see that module's moduledoc
  # for why the read/write/delete mechanics live there now instead of here.

  defp meta_get(key), do: Meta.get(key)
  defp meta_put(key, value), do: Meta.put(key, value)
  defp meta_delete(key), do: Meta.delete(key)

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
