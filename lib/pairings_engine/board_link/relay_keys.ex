defmodule PairingsEngine.BoardLink.RelayKeys do
  @moduledoc """
  Getting the hall box its permission to send moves to the results site,
  without anybody copying anything.

  The results site takes moves from a box that presents a **relay key**: a
  credential for one tournament's live boards and nothing else. It used to
  be made by an administrator of the results site and pasted into
  OpenPairings by the arbiter, which meant an arbiter with a box and a
  round starting had to find an administrator first. This machine already
  holds what publishes the tournament, and the results site hands a relay
  key to exactly that (`POST /api/tournaments/:slug/relay-keys`,
  OpenResults' `docs/live-boards-api.md`). So it asks.

  The box is still never given the publishing credentials. Those can rewrite
  the tournament; a box can be left in a cupboard. It gets the relay key
  over the board link, as before, and nothing else.

  ## When it asks

  A tournament is asked for when all of this is true:

    * it is on the results site (`BoardLink.openresults_target/1`);
    * it holds no key - or holds one for an address it has since left, or
      the arbiter asked for a new one;
    * there is a reason to think a box will want it: a connect code reaches
      it (its own, or its group's), or a board has reported a game of it,
      or the "live link" switch is on.

  That is a condition, not a list of events, and `sweep/1` evaluates it
  every time the publishing drain runs: every thirty seconds, and two
  seconds after anything nudges the drain. Making a code, a box calling for
  the first time, flipping the switch and a publish all nudge it. A trigger
  nobody thought of is therefore late by half a minute, not lost.

  ## Never on the request path

  Nothing here is called from a page or from the box's request. The drain
  process asks; a page reads `status/1` and hears about a change on
  `BoardLink.topic/1`.

  ## When it does not work

    * unreachable, busy, rate limited, or the tournament's first publish has
      not landed yet: asked again by itself, with the publishing queue's
      backoff, and without telling anybody. A hall with no network is the
      normal case;
    * refused (`not_owner`, a hidden tournament, ...): kept as the site's
      own code, shown in words on the settings page, asked again every six
      hours and at once on "Try again";
    * the site has no such route (an OpenResults from before it): the same,
      with the reason `"unsupported"`, and the settings page offers the old
      way - paste a key an administrator made.

  ## Replacing

  The results site keeps a fingerprint and cannot hand the same key out
  twice, so asking again always returns a new key and revokes the one this
  machine was given before. That is what "Replace" does, and what happens by
  itself when the key is missing here (a database restored from before it
  was fetched). The box reads the tournament document again when its version
  changes, and the version covers the key (`Document.version/1`).

  ## Secrets

  The key is written to `tournaments.openresults_relay_key` and to nothing
  else: not to a log line, not to the audit trail (which gets its last four
  characters), not to an export.
  """

  import Ecto.Query

  alias PairingsEngine.{Audit, BoardLink, Publishing, Repo}
  alias PairingsEngine.BoardLink.RelayRequest
  alias PairingsEngine.Publishing.Installation
  alias PairingsEngine.Tournaments.Tournament

  require Logger

  # What this machine calls its key on the results site. One per tournament:
  # asking again under it replaces the previous one there.
  @label "openpairings"

  # The publishing queue's steps, for the same reason: a venue's wifi comes
  # back in minutes.
  @backoff [30, 60, 120, 300, 600, 1_800, 3_600]

  # A refusal is asked about again, but rarely: the answer changes when a
  # person changes something (the site is upgraded, a transfer is made), and
  # "Try again" is there for whoever knows that happened.
  @refused_retry_s 6 * 3_600

  # "Unsupported" is the one refusal that mends itself in minutes: a deploy
  # that restarts this program a moment before the results site answers 404
  # for a route the site is about to have. Asked again every five minutes
  # for the first hour, then on the slow schedule like any other refusal.
  @unsupported_retry_s 300
  @unsupported_quick_tries 12

  @temporary_codes ~w(tournament_not_published rate_limited publishing_paused storage_low
                      registration_closed)

  @doc "The label this machine's keys carry on the results site."
  def label, do: @label

  ## ---------- what the page reads ----------

  @doc """
  Where `tournament` stands, for the settings page:

    * `%{state: :no_site}` - not on a results site, so there is nothing to ask;
    * `%{state: :idle}` - on the site, no box in sight: nothing asked yet;
    * `%{state: :fetching, reason: code | nil}` - being asked for. `reason`
      is why the last try did not land, if one was made;
    * `%{state: :held, origin: :fetched | :pasted, at: DateTime | nil,
      hint: "x9Qa", replacing?: boolean, problem: code | nil}`;
    * `%{state: :refused, reason: code}`.

  Every map also carries `fallback?`: the results site cannot hand a key out
  at all, so pasting one is the only way.
  """
  @spec status(Tournament.t()) :: map()
  def status(%Tournament{} = tournament) do
    row = get(tournament.id)
    key = tournament.openresults_relay_key
    fallback? = match?(%RelayRequest{state: "refused", reason: "unsupported"}, row)

    status =
      cond do
        is_nil(BoardLink.openresults_target(tournament)) ->
          %{state: :no_site}

        is_binary(key) ->
          fetched? = match?(%RelayRequest{state: "held"}, row)

          %{
            state: :held,
            origin: if(fetched?, do: :fetched, else: :pasted),
            at: if(fetched?, do: row.obtained_at),
            hint: String.slice(key, -4, 4),
            replacing?: stale?(tournament, row),
            problem: if(fetched?, do: row.reason)
          }

        match?(%RelayRequest{state: "refused"}, row) ->
          %{state: :refused, reason: row.reason}

        triggered?(tournament, row) ->
          %{state: :fetching, reason: row && row.reason}

        true ->
          %{state: :idle}
      end

    Map.put(status, :fallback?, fallback?)
  end

  @doc "The bookkeeping row of a tournament, or nil."
  def get(tournament_id), do: Repo.get_by(RelayRequest, tournament_id: tournament_id)

  ## ---------- what the arbiter may ask ----------

  @doc """
  Asks again, now: after a refusal ("Try again"), or with `replace: true`
  for a new key while one is held. Only marks the tournament and nudges the
  drain; the asking is `sweep/1`'s. The caller has checked who is asking
  (`BoardLink.retry_relay_key/2`, `BoardLink.replace_relay_key/2`).
  """
  @spec ask_again(Tournament.t(), keyword()) :: :ok
  def ask_again(%Tournament{id: id} = tournament, opts \\ []) do
    replace? = Keyword.get(opts, :replace, false) and is_binary(tournament.openresults_relay_key)
    row = get(id) || %RelayRequest{tournament_id: id}

    row
    |> Ecto.Changeset.change(
      state: if(row.state == "held" and replace?, do: "held", else: "wanted"),
      reason: nil,
      attempts: 0,
      next_attempt_at: nil,
      replace: replace?
    )
    |> Repo.insert_or_update!()

    Publishing.Drain.nudge()
    BoardLink.announce(id)
    :ok
  end

  @doc """
  Forgets everything about `tournament_id`'s key but the key itself, which
  is the caller's to clear: the tournament left the results site, and what
  the key was for is gone there too (a takedown deletes it on the site).
  """
  def forget(tournament_id) do
    Repo.delete_all(from r in RelayRequest, where: r.tournament_id == ^tournament_id)
    :ok
  end

  @doc false
  # A key pasted by hand replaces a fetched one: the row must stop saying
  # "fetched". A row that says the site cannot hand one out stays - that is
  # why the paste field is on the page.
  def pasted(tournament_id) do
    Repo.delete_all(
      from r in RelayRequest, where: r.tournament_id == ^tournament_id and r.state == "held"
    )

    :ok
  end

  ## ---------- the asking ----------

  @doc """
  Asks the results site for every key that is wanted and due. Returns how
  many were fetched. Never raises: it runs from the publishing drain's
  timer, and a results site that is not there is an ordinary evening.

  Sends nothing when this machine holds no credential it may send
  (`Publishing.can_send?/0`), which in a desktop copy includes "the arbiter
  has not agreed to anything yet".
  """
  @spec sweep(DateTime.t()) :: non_neg_integer()
  def sweep(now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)

    if may_send?() do
      now
      |> due()
      |> Enum.reduce_while(0, fn {tournament, row}, fetched ->
        case attempt(tournament, row, now) do
          :fetched -> {:cont, fetched + 1}
          # Nobody is home. The other tournaments would hear the same
          # silence, one timeout each.
          :unreachable -> {:halt, fetched}
          _other -> {:cont, fetched}
        end
      end)
    else
      0
    end
  rescue
    error ->
      # The module's name and nothing else: an exception's message can carry
      # the row it tripped over, and the row carries the key.
      Logger.warning("relay key sweep failed: #{inspect(error.__struct__)}")
      0
  end

  defp may_send? do
    Publishing.can_send?() and not (Publishing.public_mode?() and Installation.halted?())
  end

  # The tournaments that could be asked for now, each with its row. The
  # reasons a box might want one are checked after, in Elixir: they span
  # three tables and a group, and there are never many candidates.
  defp due(now) do
    Repo.all(
      from t in Tournament,
        left_join: r in RelayRequest,
        on: r.tournament_id == t.id,
        where:
          t.publish_to_openresults == true and not is_nil(t.openresults_key) and
            is_nil(t.deleted_at) and is_nil(t.archived_at) and is_nil(t.handed_off_at),
        where:
          is_nil(t.openresults_relay_key) or r.replace == true or
            (r.state == "held" and r.slug != t.public_slug),
        where: is_nil(r.id) or is_nil(r.next_attempt_at) or r.next_attempt_at <= ^now,
        order_by: t.id,
        select: {t, r}
    )
    |> Enum.filter(fn {tournament, row} ->
      not is_nil(BoardLink.openresults_target(tournament)) and triggered?(tournament, row)
    end)
  end

  # Is there a reason to think a box will want this tournament's key?
  defp triggered?(%Tournament{} = tournament, row) do
    stale?(tournament, row) or tournament.public_live_boards == true or
      BoardLink.connected?(tournament.id)
  end

  # A key is held, and it is not the one wanted: the arbiter asked for
  # another, or the tournament has another address on the site now.
  defp stale?(%Tournament{} = tournament, %RelayRequest{} = row) do
    row.replace or
      (row.state == "held" and is_binary(tournament.openresults_relay_key) and
         row.slug != tournament.public_slug)
  end

  defp stale?(_tournament, nil), do: false

  defp attempt(%Tournament{} = tournament, row, now) do
    slug = tournament.public_slug

    request =
      Publishing.request(
        "/api/tournaments/#{URI.encode(slug, &URI.char_unreserved?/1)}/relay-keys",
        json: %{label: @label},
        headers: [{Publishing.key_header(), tournament.openresults_key}]
      )

    case Req.post(request) do
      {:ok, %Req.Response{status: status, body: %{"relay_key" => "orrk_" <> _ = key}}}
      when status in 200..299 ->
        store(tournament, row, key, slug, now)
        :fetched

      # A 2xx that is not this API's answer: something else lives at that
      # address. Not a key, and not worth hammering.
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        refused(tournament, row, "unsupported", now)

      {:ok, %Req.Response{} = response} ->
        answered(tournament, row, response, now)

      {:error, _transport} ->
        later(tournament, row, "unreachable", nil, now)
        :unreachable
    end
  end

  defp answered(tournament, row, %Req.Response{} = response, now) do
    {:rejected, status, code, _detail} = Publishing.rejection_of(response)

    cond do
      code in @temporary_codes ->
        later(tournament, row, code, retry_after(response), now)

      # No such route: an OpenResults from before it. Its 404 is Phoenix's
      # own and carries no code of the API; `tournament_not_published` is
      # the 404 of a server that does know the route, caught above.
      status in [404, 405] ->
        refused(tournament, row, "unsupported", now)

      status >= 500 or status == 429 ->
        later(tournament, row, code || "server_error", retry_after(response), now)

      true ->
        refused(tournament, row, code || "http_#{status}", now)
    end
  end

  defp retry_after(%Req.Response{body: body} = response) do
    from_body = if is_map(body), do: body["retry_after"]

    case {from_body, Req.Response.get_header(response, "retry-after")} do
      {seconds, _header} when is_integer(seconds) and seconds > 0 ->
        seconds

      {_none, [value | _]} ->
        case Integer.parse(value) do
          {seconds, ""} when seconds > 0 -> seconds
          _not_seconds -> nil
        end

      _neither ->
        nil
    end
  end

  defp store(%Tournament{} = tournament, row, key, slug, now) do
    replaced? = is_binary(tournament.openresults_relay_key)

    {:ok, _} =
      Repo.transaction(fn ->
        tournament |> Ecto.Changeset.change(openresults_relay_key: key) |> Repo.update!()

        (row || %RelayRequest{tournament_id: tournament.id})
        |> Ecto.Changeset.change(
          state: "held",
          reason: nil,
          attempts: 0,
          next_attempt_at: nil,
          obtained_at: now,
          slug: slug,
          replace: false
        )
        |> Repo.insert_or_update!()
      end)

    Audit.log(tournament.id, nil, "boards.relay_key_fetched", %{
      hint: String.slice(key, -4, 4),
      replaced: replaced?
    })

    Logger.info("relay key fetched for tournament #{tournament.id}")
    BoardLink.announce(tournament.id)
  end

  # Not now. Silent: nothing is written to the audit trail, and the page
  # keeps saying it is being fetched.
  defp later(%Tournament{} = tournament, row, reason, retry_in, now) do
    row = row || %RelayRequest{tournament_id: tournament.id}
    attempts = row.attempts + 1
    wait = max(retry_in || 0, Enum.at(@backoff, attempts - 1, List.last(@backoff)))
    changed? = row.reason != reason or row.state == "refused"

    row
    |> Ecto.Changeset.change(
      state: if(holding?(tournament, row), do: "held", else: "wanted"),
      reason: reason,
      attempts: attempts,
      next_attempt_at: DateTime.add(now, wait, :second)
    )
    |> Repo.insert_or_update!()

    if changed?, do: BoardLink.announce(tournament.id)
    :later
  end

  defp refused_wait("unsupported", attempts) when attempts <= @unsupported_quick_tries,
    do: @unsupported_retry_s

  defp refused_wait(_reason, _attempts), do: @refused_retry_s

  defp refused(%Tournament{} = tournament, row, reason, now) do
    row = row || %RelayRequest{tournament_id: tournament.id}
    news? = row.reason != reason or row.state == "wanted"

    row
    |> Ecto.Changeset.change(
      state: if(holding?(tournament, row), do: "held", else: "refused"),
      reason: reason,
      attempts: row.attempts + 1,
      next_attempt_at: DateTime.add(now, refused_wait(reason, row.attempts + 1), :second),
      # A replacement that was refused is not asked for again every six
      # hours behind the arbiter's back: the key that is held still works.
      replace: false
    )
    |> Repo.insert_or_update!()

    if news? do
      Audit.log(tournament.id, nil, "boards.relay_key_refused", %{reason: reason})
      BoardLink.announce(tournament.id)
    end

    :refused
  end

  # A fetched key is held and stays held whatever a later request for
  # another one is answered.
  defp holding?(%Tournament{} = tournament, %RelayRequest{} = row),
    do: row.state == "held" and is_binary(tournament.openresults_relay_key)
end
