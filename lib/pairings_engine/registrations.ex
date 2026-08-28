defmodule PairingsEngine.Registrations do
  @moduledoc """
  Entries the public form collected, pulled back for the arbiter to decide.

  The other direction from `PairingsEngine.Publishing`, and the direction is
  the design: **OpenResults never writes to a tournament.** It accepts
  submissions from a form and holds them. This machine pulls that queue, and
  an arbiter says yes or no to each one. A registration is a request, not a
  player, and nothing in this module turns one into a player without
  somebody pressing a button.

  Stated that way it sounds like caution. It is actually the only shape that
  works: the server is a public web app that anyone can post to, the arbiter
  is legally and practically responsible for who is in the event, and an
  entry list that a stranger could write to directly would be worthless.

  ## Not to be confused with the form on this machine

  `Tournaments.register_public_player/2` is a different feature that reads
  almost the same. That one is `/p/:slug/register`, served by this app, and
  it creates a player immediately because the arbiter opened the form on
  their own machine and the entry never left it. This module handles entries
  that arrived somewhere else, so there is a decision in the middle.

  What the two do agree on, deliberately:

    * an entrant lands **absent**. Filling in a web form announces an
      intention to play; it is not the same as being in the room. The
      arbiter clears the flag when the person turns up. Backwards, this
      pairs a no-show and hands their opponent a forfeit win.
    * rounds a stranger asked to sit out are re-derived from the round
      count rather than trusted, so the worst a forged submission can ask
      for is a bye in a round that exists.

  ## Why a local mirror rather than a live list

  `pull/1` copies entries into `openresults_registrations` and every other
  function reads from there. Two reasons.

  A pull needs the network and a decision does not - the same wifi argument
  that gave publishing a queue. And the server has no notion of an entry
  being handled: it holds everything it was ever sent (see
  `OpenResults.Registrations.list_for_tournament/1`, which is exactly
  "everything, oldest first"). "Already decided" is therefore a fact about
  this machine, and it has to be stored on this machine or a discarded entry
  reappears at every pull for the rest of the tournament.

  Re-pulling is consequently safe and boring: an entry already held is left
  exactly as it is, decision included.

  ## Configuration and gates

  Address and token come from `Publishing` - one server, one configuration.
  All three gates apply to pulling and to deciding alike: the server must be
  configured, the tournament must be opted in with `publish_to_openresults`,
  and it must not be archived. Turning publishing off therefore parks any
  undecided entries rather than deleting them; turning it back on brings
  them back.

  ## The email address

  `email` is the one piece of personal data a registration carries, and it
  exists so the arbiter can contact the person. It stops in the `payload`
  column of this table. `accept/1` builds its attrs from a hand-written
  allowlist that does not include it, and `players` has no column that could
  hold it - so it cannot reach a snapshot, a TRF export or a public page
  even if somebody later widens the allowlist by accident.
  """

  import Ecto.Query

  alias PairingsEngine.{Publishing, Repo, Tournaments}
  alias PairingsEngine.Registrations.Registration
  alias PairingsEngine.Tournaments.{Player, Tournament}

  @doc """
  Fetches this tournament's entries from OpenResults and stores the new ones.

  Returns `{:ok, %{new: n, total: n}}` - how many entries the server offered
  and how many of those had not been seen here before - or `{:error,
  message}`, already in words an arbiter can act on. It never raises: a pull
  is a button on a page, and the network being down is the ordinary case
  this whole feature was built around.

  Unlike a publish, a pull is NOT queued and retried. The arbiter asked for
  it and is standing there waiting for the answer, so the honest response to
  a dead server is to say so rather than to promise entries will turn up
  later.
  """
  @spec pull(Tournament.t()) ::
          {:ok, %{new: non_neg_integer(), total: non_neg_integer()}} | {:error, String.t()}
  def pull(%Tournament{} = tournament) do
    with :ok <- ensure_available(tournament),
         {:ok, entries} <- fetch(tournament) do
      {:ok, store(tournament, entries)}
    end
  end

  @doc """
  Entries waiting for a decision, oldest first.

  Oldest first because entry order is what decides a capped field, and an
  arbiter reading this list is reading a queue.
  """
  @spec pending(integer()) :: [Registration.t()]
  def pending(tournament_id) do
    Repo.all(
      from r in Registration,
        where: r.tournament_id == ^tournament_id and r.status == "pending",
        order_by: [asc: r.received_at, asc: r.id]
    )
  end

  @doc """
  Entries already decided, most recently decided first.

  Kept and shown rather than deleted. An arbiter who turned somebody away
  may still need to tell them so, and the email is in this row.
  """
  @spec decided(integer()) :: [Registration.t()]
  def decided(tournament_id) do
    Repo.all(
      from r in Registration,
        where: r.tournament_id == ^tournament_id and r.status in ["accepted", "discarded"],
        order_by: [desc: r.decided_at, desc: r.id],
        preload: [:player]
    )
  end

  @doc "How many entries are waiting for a decision."
  @spec pending_count(integer()) :: non_neg_integer()
  def pending_count(tournament_id) do
    Repo.aggregate(
      from(r in Registration,
        where: r.tournament_id == ^tournament_id and r.status == "pending"
      ),
      :count,
      :id
    )
  end

  @doc """
  Fetches one entry, but only within `tournament_id`.

  Deliberately takes the tournament, exactly as `Tournaments.get_player/2`
  does and for the same reason: the id reaches us in a LiveView event
  payload long after the mount was authorised, so it is attacker-controlled
  and authorising the tournament proves nothing about the row. This is the
  only way to obtain a `Registration` to hand to `accept/1` or `discard/1`,
  which is what makes those two safe to write without a scope argument.

  Returns nil for an id that is not an integer, rather than letting an
  `Ecto.Query.CastError` crash the page.
  """
  @spec get(integer(), term()) :: Registration.t() | nil
  def get(tournament_id, id) do
    case normalize_id(id) do
      nil -> nil
      int_id -> Repo.get_by(Registration, id: int_id, tournament_id: tournament_id)
    end
  end

  @doc """
  Turns an entry into a real player in the tournament.

  Goes through `Tournaments.create_player/2` rather than inserting a row, so
  an accepted entry gets the duplicate-FIDE-ID guard, the archive check and
  the `:players` broadcast that every other player in the app gets. A second
  insert path would be a second set of rules to keep in step.

  The player lands **absent**, which is not a detail: the person filled in a
  web form, and the arbiter marks them present when they actually walk in.

  Returns `{:ok, player}` or `{:error, message}` in words. Words rather than
  atoms because every reason this can fail - a duplicate FIDE ID, a blank
  name from a broken form, an archived tournament - is something the arbiter
  reads and acts on, and there is exactly one caller to phrase them for.
  """
  @spec accept(Registration.t()) :: {:ok, Player.t()} | {:error, String.t()}
  def accept(%Registration{} = registration) do
    case reload(registration) do
      %Registration{status: "pending"} = fresh -> do_accept(fresh)
      %Registration{status: status} -> {:error, already_decided(status)}
      nil -> {:error, "that entry is no longer here"}
    end
  end

  defp do_accept(%Registration{} = registration) do
    tournament = Repo.get(Tournament, registration.tournament_id)

    with :ok <- ensure_available(tournament),
         {:ok, player} <-
           Tournaments.create_player(tournament.id, player_attrs(registration, tournament)) do
      registration
      |> Ecto.Changeset.change(%{
        status: "accepted",
        player_id: player.id,
        decided_at: DateTime.utc_now()
      })
      |> Repo.update!()

      {:ok, player}
    else
      {:error, :duplicate_fide_id} ->
        {:error, "somebody with that FIDE ID is already in this tournament"}

      {:error, :archived} ->
        {:error, "this tournament is archived"}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset_message(changeset)}

      {:error, message} when is_binary(message) ->
        {:error, message}
    end
  end

  @doc """
  Turns an entry down. Creates nothing.

  The row stays, marked, for two reasons: a discarded entry must not come
  back at the next pull, and the arbiter may still need the email to tell
  somebody the field is full.
  """
  @spec discard(Registration.t()) :: {:ok, Registration.t()} | {:error, String.t()}
  def discard(%Registration{} = registration) do
    case reload(registration) do
      %Registration{status: "pending"} = fresh -> decide(fresh, "discarded")
      %Registration{status: status} -> {:error, already_decided(status)}
      nil -> {:error, "that entry is no longer here"}
    end
  end

  @doc """
  Puts a discarded entry back in the pending list.

  Exists because discarding is one click on a stranger's entry and the only
  other way back is asking that person to submit the form again. An accepted
  entry is deliberately NOT restorable: a player exists by then, and the way
  to undo that is to delete the player.
  """
  @spec restore(Registration.t()) :: {:ok, Registration.t()} | {:error, String.t()}
  def restore(%Registration{} = registration) do
    case reload(registration) do
      %Registration{status: "discarded"} = fresh ->
        decide(fresh, "pending")

      %Registration{status: "accepted"} ->
        {:error, "this entry is already a player - delete the player instead"}

      %Registration{} ->
        {:error, "this entry is not discarded"}

      nil ->
        {:error, "that entry is no longer here"}
    end
  end

  # Every decision reads the STORED status, never the struct the caller is
  # holding. A page keeps its list in memory and a double-click delivers the
  # same entry twice: without this, the second click's struct still says
  # "pending" and a second player is created. Only an entry carrying a FIDE
  # ID was ever protected from that, by `create_player/2`'s duplicate guard -
  # and a club player with no FIDE ID is exactly the entry that does not
  # have one.
  defp reload(%Registration{id: id}), do: Repo.get(Registration, id)

  defp decide(registration, status) do
    tournament = Repo.get(Tournament, registration.tournament_id)

    with :ok <- ensure_available(tournament) do
      updated =
        registration
        |> Ecto.Changeset.change(%{
          status: status,
          decided_at: if(status == "pending", do: nil, else: DateTime.utc_now())
        })
        |> Repo.update!()

      {:ok, updated}
    end
  end

  defp already_decided(status), do: "this entry has already been #{status}"

  ## ---------- gates ----------

  # The same three checks for pulling and for deciding. Two of them are
  # phrased exactly as `Publishing.publish/1` phrases them, because an
  # arbiter who has just read "this tournament is not set to publish" on the
  # settings page should not meet a second wording for the same fact here.
  #
  # The archive check is `ensure_writable/1`, NOT `ensure_unlocked/2`. Those
  # two sound interchangeable and are not: `ensure_unlocked/2` guards the
  # handful of tournament SETTINGS that a paired round freezes (the pairing
  # system, the engine, the match format), and takes the attrs being saved
  # to see whether any of them would move. It has nothing to say about
  # adding a player. `ensure_writable/1` is the archive gate, and it is the
  # one `create_player/2` itself applies.
  defp ensure_available(%Tournament{} = tournament) do
    cond do
      not Publishing.configured?() ->
        {:error, "no OpenResults server is configured"}

      not tournament.publish_to_openresults ->
        {:error, "this tournament is not set to publish"}

      Tournaments.ensure_writable(tournament) != :ok ->
        {:error, "this tournament is archived"}

      true ->
        :ok
    end
  end

  # A tournament deleted between the page rendering and the click. Nothing
  # to add a player to, so this is an error rather than a crash.
  defp ensure_available(nil), do: {:error, "this tournament no longer exists"}

  ## ---------- the pull ----------

  # ASSUMED SERVER ROUTE. At the time of writing OpenResults has the
  # `Registrations` context and the storage behind it, but no controller or
  # router entry that exposes a listing - the public form is being built
  # alongside this. So this is written against the shape the contract and
  # that context imply, and is deliberately generous about what comes back.
  #
  # Token-gated for the same reason `/history` is: this listing carries the
  # one personal field in the whole system. A registration list on an open
  # route would publish the email address of everybody who signed up.
  # The queue is the only thing OpenResults holds that carries an email
  # address, so the server gates it on the tournament key as well as the
  # ingest token - otherwise any machine configured to publish could read the
  # entries for every tournament on the server, including ones it has never
  # published. Sending the key is what makes this our queue rather than a
  # queue we happen to be able to reach.
  #
  # A tournament that has never published has no key, and the header is then
  # omitted: the server leaves such a slug unclaimed and answers anyway, which
  # is what keeps a tournament published before keys existed readable by the
  # arbiter running it.
  defp key_headers(%Tournament{openresults_key: key}) when is_binary(key) and key != "",
    do: [{Publishing.key_header(), key}]

  defp key_headers(%Tournament{}), do: []

  defp fetch(%Tournament{} = tournament) do
    path = "/api/tournaments/#{encode_segment(tournament.public_slug)}/registrations"

    case Req.get(Publishing.request(path, headers: key_headers(tournament))) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        parse(body)

      {:ok, %Req.Response{status: 401}} ->
        {:error, "the server rejected the token (401)"}

      {:ok, %Req.Response{status: 403}} ->
        {:error,
         "the server refused this tournament's entries (403) - a different " <>
           "machine published it, so its key is not this one"}

      {:ok, %Req.Response{status: 404}} ->
        {:error,
         "the server has no entry list for this tournament (404) - " <>
           "publish it first, or the server may be older than this feature"}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "the server answered #{status}: #{Publishing.describe_body(body)}"}

      {:error, reason} ->
        {:error, Publishing.describe_transport(reason)}
    end
  end

  # A slug is a generated token today, but it lands in a URL path, so it is
  # escaped rather than trusted to stay one.
  defp encode_segment(slug), do: URI.encode(to_string(slug), &URI.char_unreserved?/1)

  # Both plausible renderings of the listing are accepted: an envelope with
  # a `registrations` key, and a bare array. The reader ignoring what it
  # does not recognise is the contract's own rule, and applying it here
  # costs one clause and means this half does not break if the other half
  # wraps its list.
  defp parse(%{"registrations" => entries}) when is_list(entries), do: {:ok, entries}
  defp parse(entries) when is_list(entries), do: {:ok, entries}

  defp parse(_something_else),
    do: {:error, "the server's reply was not a list of entries"}

  defp store(%Tournament{} = tournament, entries) do
    pulled_at = DateTime.utc_now()

    entries
    |> Enum.filter(&is_map/1)
    |> Enum.reduce(%{new: 0, total: 0}, fn entry, acc ->
      case store_entry(tournament, entry, pulled_at) do
        :new -> %{acc | new: acc.new + 1, total: acc.total + 1}
        :existing -> %{acc | total: acc.total + 1}
      end
    end)
  end

  defp store_entry(%Tournament{} = tournament, entry, pulled_at) do
    key = external_key(entry)

    exists? =
      Repo.exists?(
        from r in Registration,
          where: r.tournament_id == ^tournament.id and r.external_key == ^key
      )

    if exists? do
      :existing
    else
      document = document(entry)

      Repo.insert!(
        %Registration{
          tournament_id: tournament.id,
          external_key: key,
          received_at: received_at(entry, document, pulled_at),
          payload: document,
          status: "pending"
        },
        # The unique index is the real guard. Nothing here runs concurrently
        # today - one arbiter, one button - but a row silently not inserted
        # twice is a better outcome than a constraint error on a page.
        on_conflict: :nothing,
        conflict_target: [:tournament_id, :external_key]
      )

      :new
    end
  end

  # The entry as the listing renders it, versus the registration document
  # inside it. A row-shaped entry nests the payload; a listing that returns
  # stored payloads verbatim (which is how `SnapshotController.show/2`
  # answers, so it is a real possibility) is already the document.
  defp document(%{"payload" => payload}) when is_map(payload), do: payload
  defp document(entry), do: entry

  # What "already seen this one" means, and the only thing standing between
  # an arbiter and re-deciding every entry at every pull.
  #
  # The server's row id when the listing carries one - that is the handle
  # that survives the payload being identical to somebody else's. When it
  # does not, a fingerprint of the whole entry: two submissions by the same
  # person differ in at least their timestamp, and two byte-identical
  # entries are a double-submit that an arbiter should see once.
  defp external_key(%{"id" => id}) when is_integer(id), do: "id:#{id}"

  defp external_key(%{"id" => id}) when is_binary(id) and id != "", do: "id:#{id}"

  defp external_key(entry),
    do: "sha256:" <> (:sha256 |> :crypto.hash(canonical(entry)) |> Base.encode16(case: :lower))

  # A stable byte encoding of a decoded JSON value, used only as the input
  # to that hash. Not JSON: a decoded map has no key order to rely on, so
  # keys are sorted, and every string is length-prefixed so that no two
  # different documents can encode to the same bytes. Hand-rolled rather
  # than re-encoding with Jason because Jason makes no promise about key
  # order, and a key that reordered between two pulls would resurrect an
  # entry the arbiter had already turned away.
  defp canonical(map) when is_map(map) do
    pairs =
      map
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.map(fn {key, value} -> [canonical(to_string(key)), canonical(value)] end)

    ["m", pairs, ";"]
  end

  defp canonical(list) when is_list(list), do: ["l", Enum.map(list, &canonical/1), ";"]

  defp canonical(value) when is_binary(value),
    do: ["s", Integer.to_string(byte_size(value)), ":", value]

  defp canonical(nil), do: "n;"
  defp canonical(true), do: "t;"
  defp canonical(false), do: "f;"
  defp canonical(value) when is_integer(value), do: ["i", Integer.to_string(value), ";"]
  defp canonical(value) when is_float(value), do: ["d", Float.to_string(value), ";"]

  # The server's own stamp first. It uses its clock on arrival precisely
  # because the `received_at` inside the payload is a claim by an
  # unauthenticated submitter; the claimed one is still better than nothing
  # for ordering a queue, and the pull time is the last resort.
  defp received_at(entry, document, fallback) do
    parse_time(Map.get(entry, "received_at")) ||
      parse_time(Map.get(document, "received_at")) ||
      fallback
  end

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      # The column is `:utc_datetime_usec` and Ecto refuses to dump a value
      # of any other precision, so a timestamp written without a fractional
      # part - which is what an ISO 8601 instant usually looks like - has to
      # be widened rather than stored as it parsed.
      {:ok, %DateTime{microsecond: {microsecond, _precision}} = datetime, _utc_offset} ->
        %{datetime | microsecond: {microsecond, 6}}

      {:error, _unparseable} ->
        nil
    end
  end

  defp parse_time(_absent), do: nil

  ## ---------- accepting ----------

  # A hand-written allowlist, never the payload's player object as it stands.
  # The email is the reason: it is the one field in this whole feature that
  # must not travel onward, and an allowlist makes "not published" the
  # default for anything the public form adds later, rather than something
  # somebody has to remember to exclude. `PairingsEngine.Snapshot`'s
  # `player_row/1` is the same decision at the other end of the system.
  defp player_attrs(%Registration{} = registration, %Tournament{} = tournament) do
    player = Registration.player_data(registration)

    %{
      "name" => trimmed(player["name"]),
      "title" => trimmed(player["title"]),
      "fide_id" => whole_number(player["fide_id"]),
      # The contract has one `rating`; this app has `fide_rating` and
      # `national_rating`. It goes to `fide_rating` because it arrives beside
      # `fide_id`, `federation` and `title` in a FIDE-shaped object, and
      # because `Player.rating/1` falls back to the national field rather
      # than the other way round. An arbiter who knows better moves it - and
      # they see the number on the review page before accepting, which is
      # the reason this is safe to decide here at all.
      "fide_rating" => whole_number(player["rating"]),
      "federation" => trimmed(player["federation"]),
      "club" => trimmed(player["club"]),
      # Not in the registration contract. Accepted if it turns up because
      # the form on this machine already collects it (it is what tells two
      # players with the same name apart), and ignoring a field the sender
      # bothered to send would be the additive rule working backwards.
      "birth_year" => whole_number(player["birth_year"]),
      "absent_rounds" => requested_byes(player["requested_byes"], tournament),
      # See the moduledoc: a web form is an intention, not an arrival.
      "absent" => true
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  # `requested_byes` becomes `absent_rounds`, which is this app's ONLY
  # mechanism for a bye a player asked for in advance. That is worth
  # stating, because it looks like a missing feature and is not: a
  # `requested_bye_type` column was added and dropped again on 2026-08-25
  # (see the two migrations) once it became clear there is only one
  # question here. You know a player is absent before a round is paired
  # only because they told you, and an unannounced no-show is paired and
  # forfeits on the board - so every absence the pairing sees is an
  # announced one, valued by `abs_value` with its `abs_nbfois` /
  # `abs_jusque` caps. There is no second kind to record.
  #
  # Every value is re-derived from the round count rather than trusted, for
  # the same reason `Tournaments.register_public_player/2` clamps: "1-999"
  # is a perfectly well-formed request from a form with no login behind it.
  defp requested_byes(rounds, %Tournament{} = tournament) when is_list(rounds) do
    last = tournament.rounds_count || 0

    rounds
    |> Enum.map(&round_number/1)
    |> Enum.filter(&(is_integer(&1) and &1 >= 1 and &1 <= last))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.join(",")
  end

  defp requested_byes(_absent_or_wrong_shape, _tournament), do: ""

  defp round_number(value) when is_integer(value), do: value

  defp round_number(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _not_a_number -> nil
    end
  end

  defp round_number(_value), do: nil

  @doc """
  The rounds an entry asked to sit out, as a sorted list of numbers.

  For the review page, which shows the request whether or not this
  tournament has those rounds - an arbiter looking at "rounds 3, 9" for a
  seven-round event needs to see that the person asked for something
  impossible, not a silently shortened list.
  """
  @spec requested_rounds(Registration.t()) :: [integer()]
  def requested_rounds(%Registration{} = registration) do
    case registration |> Registration.player_data() |> Map.get("requested_byes") do
      rounds when is_list(rounds) ->
        rounds
        |> Enum.map(&round_number/1)
        |> Enum.filter(&is_integer/1)
        |> Enum.uniq()
        |> Enum.sort()

      _absent_or_wrong_shape ->
        []
    end
  end

  ## ---------- odds and ends ----------

  # Rating, FIDE ID and birth year land in `:integer` columns, and Ecto's
  # cast refuses a float or a numeric string outright. The contract says
  # these are numbers and they normally are - but the sender is a web form,
  # and a form that posts `"1804"` or `1804.0` would otherwise produce an
  # entry the arbiter cannot accept AT ALL, with no way out but discarding
  # it and typing the player in by hand. Coercing is the same tolerance the
  # server applies on the way in, one column further along.
  #
  # Anything that is not a number at all becomes nil and the field is simply
  # not set, which is what "not known" already means everywhere else here.
  defp whole_number(value) when is_integer(value), do: value
  defp whole_number(value) when is_float(value), do: trunc(value)

  defp whole_number(value) when is_binary(value) do
    case value |> String.trim() |> Integer.parse() do
      {number, ""} -> number
      _not_a_whole_number -> nil
    end
  end

  defp whole_number(_value), do: nil

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trimmed(_not_a_string), do: nil

  defp normalize_id(id) when is_integer(id), do: id

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _not_an_integer -> nil
    end
  end

  defp normalize_id(_id), do: nil

  # A changeset turned into one sentence. The alternative - handing the
  # changeset to the page - would put "can't be blank" next to no field name
  # on a screen that has no form for it.
  defp changeset_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end
end
