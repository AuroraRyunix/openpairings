defmodule PairingsEngine.Handoff do
  @moduledoc """
  Moving a whole tournament between two copies of OpenPairings - the hosted
  service and an arbiter's laptop, most often - as a checkout rather than a
  sync.

  ## The model

  A tournament is LIVE in exactly one place at a time, like a book checked
  out of a library. Handing it off locks the copy left behind and produces a
  file; importing that file somewhere else makes the new copy live; returning
  it produces a second file that unlocks the original. There is no merge, and
  there is never meant to be one.

  That is not a simplification to be improved on later. Two copies that both
  accepted writes cannot be reconciled: one machine recorded 1-0 on board 4
  and the other a draw, or both paired round 6 and produced different boards.
  No rule picks a winner, because the disagreement is not about data - it is
  about what happened in a room. A merge would have to invent an answer, and
  an invented answer to "who won that game" is worse than a refusal.

  The lock itself is `PairingsEngine.Tournaments.hand_off/2` /
  `take_back/2` and the `ensure_writable/1` gate every write path in the app
  already funnels through. This module is the flow built on top: it pairs the
  lock with the file, so the two cannot come apart.

      A                                                   B
      hand_off/3   -- lock A, emit envelope ---------->    receive/2   (B live)
                                                           ...event runs...
      release/3    <-- envelope: the event, and the key --  return/2   (lock B)
      (A live, and holding what was played on B)

  ## What this is NOT, honestly

  Four things a reader should know before trusting it:

    * **Releasing REPLACES what is here, and the trail is the exception.**
      `release/3` applies the returning payload and then unlocks, in one
      transaction, so the copy left behind ends up holding the three rounds
      played on the other machine rather than the state it was frozen in.
      That is safe only because the source was read-only for the whole trip
      and so cannot have diverged - which stops being true after a
      break-glass unlock, and `release/3` refuses in exactly that case. What
      it does not bring back is the far side's audit trail: the results come
      home, the record of who typed them over there stays in the file. See
      `release/3` for the full argument, including what it matches on before
      it replaces anything.
    * **Nothing verifies the two ends are the machines they claim to be.**
      The origin block is descriptive text, and the token proves only that
      whoever holds it once held the file. Anyone who can read the returning
      file can unlock the source. The file is a credential; it already was
      one (it carries the OpenResults publishing key), and this adds a
      second reason to treat it like a password.
    * **Nothing enforces the lock across machines.** The source refuses
      writes because its own database says so. A determined operator with
      shell access can clear the columns; the lock is protection against
      mistakes and against every code path in this app, not against its own
      administrator.
    * **Helper phones and collaborator grants do not travel.** Mobile
      enrolments are live access tokens issued on one machine and are
      deliberately excluded from every envelope, so the helpers on the floor
      have to re-enrol on the machine that now holds the event.
      Collaborators arrive as PENDING invitations that each person has to
      accept again - an import must never be a grant. Both are stated on the
      hand-off screen, because both are discovered at the worst possible
      moment otherwise.

  ## The envelope

  An ordinary `PairingsEngine.TournamentExport` envelope built with
  `include_handoff: true` - so it carries the audit trail and the collaborator
  list as well as the tournament - plus one extra top-level block:

      "handoff" => %{
        "format"    => "openpairings-handoff",
        "version"   => 1,
        "direction" => "out" | "back",
        "token"     => "<43 chars>",
        "origin"    => %{"instance" => ..., "address" => ...,
                         "handed_off_at" => ..., "handed_off_to" => ...}
      }

  Reusing the export envelope rather than inventing a format means
  `PairingsEngine.TournamentImport` needs no change and a hand-off file can
  always be salvaged as an ordinary backup. The reverse must not be true, and
  `receive/2` is where that is enforced: an ordinary backup has no `"handoff"`
  block and therefore no token, so receiving one is refused outright rather
  than accepted as a hand-off that would then claim to unlock a source which
  is not locked and never was.

  ## Which end holds what

  `handed_off_at`/`handed_off_to`/`handoff_token` are the SOURCE's lock.
  `handoff_origin` (this module's own column) is the receiving copy's record
  of where it came from and the key that unlocks that source. They are
  opposite states, they can be true at once, and keeping them apart is what
  makes `handed_away?/1` and `received?/1` two different questions - see the
  column's migration for the full argument.
  """

  import Ecto.Query

  alias PairingsEngine.{
    Audit,
    Repo,
    Snapshots,
    TournamentExport,
    TournamentImport,
    Tournaments
  }

  alias PairingsEngine.Accounts.Scope
  alias PairingsEngine.Audit.AuditLog
  alias PairingsEngine.Tournaments.Tournament

  # Its own format tag, separate from the export envelope's. The envelope says
  # "this is OpenPairings tournament data"; this says "and it is a hand-off,
  # with a key in it". A future build that changes what a token means bumps
  # this one and leaves ordinary backups alone.
  @handoff_format "openpairings-handoff"
  @handoff_version 1

  # Free text from another machine, bounded before it is stored. Nothing
  # downstream depends on the length, and an unbounded string from a file is
  # a string an attacker chooses the size of.
  @max_text 300

  @typedoc "A decoded hand-off envelope, ready to be JSON-encoded."
  @type payload :: map()

  @type reason ::
          :already_handed_off
          | :already_received
          | :archived
          | :bad_token
          | :force_unlocked
          | :no_destination
          | :no_restore_point
          | :not_a_handoff
          | :not_a_return
          | :not_one_tournament
          | :not_received
          | :not_this_tournament
          | :origin_not_recorded
          | {:unsupported_version, term()}
          | Ecto.Changeset.t()
          | String.t()

  @doc "The `\"handoff\"` block's format tag."
  def format, do: @handoff_format

  @doc "The `\"handoff\"` block's version number."
  def version, do: @handoff_version

  ## ---------- handing it over ----------

  @doc """
  Locks `tournament` here and returns the envelope that makes it live
  somewhere else.

  `to_label` is the free-text destination an arbiter typed ("the club
  laptop", a hostname); `actor` is the acting `PairingsEngine.Accounts.Scope`
  or user id for the audit row.

  Both halves happen in ONE transaction, and the order matters: the lock is
  taken first, then the payload is built from the locked row. If building the
  payload fails, the lock is rolled back with it - a tournament that is
  read-only here with no file anywhere else is a tournament nobody can run.
  The reverse order would be worse still: a file in the wild for a copy that
  is still accepting writes is the two-live-copies state the whole design
  exists to prevent.

  Refuses `{:error, :no_destination}` for a blank label, before anything is
  locked. `handed_off_to` is the only thing the banner on the copy left
  behind can say, and "handed off to " sends nobody anywhere.

  Otherwise refuses whatever `PairingsEngine.Tournaments.hand_off/2` refuses:
  `{:error, :already_handed_off}` or `{:error, :archived}`.
  """
  @spec hand_off(Tournament.t(), String.t(), Scope.t() | integer() | nil) ::
          {:ok, payload()} | {:error, reason()}
  def hand_off(%Tournament{} = tournament, to_label, actor) when is_binary(to_label) do
    case String.trim(to_label) do
      "" -> {:error, :no_destination}
      label -> Repo.transaction(fn -> lock_and_build(tournament, label, actor) end)
    end
  end

  defp lock_and_build(tournament, label, actor) do
    case Tournaments.hand_off(tournament, label) do
      {:ok, locked} ->
        # Logged BEFORE the payload is built, so the trail that travels
        # already contains the departure. The machine receiving it can then
        # answer "when did this leave, and who sent it" from the file alone.
        Audit.log(locked.id, actor, "handoff.handed_off", %{
          "to" => label,
          "name" => locked.name,
          "at" => DateTime.to_iso8601(locked.handed_off_at)
        })

        envelope(locked, "out", locked.handoff_token, %{
          "instance" => instance_name(),
          "address" => instance_address(),
          "handed_off_at" => DateTime.to_iso8601(locked.handed_off_at),
          "handed_off_to" => label
        })

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  ## ---------- taking it in ----------

  @doc """
  Files a hand-off envelope as a new, live tournament owned by `scope`'s user,
  remembering where it came from and the key that unlocks the copy left
  behind.

  `data` is a JSON-decoded envelope. Everything about the tournament itself is
  `PairingsEngine.TournamentImport`'s job and is unchanged - fresh ids, a fresh
  public link, the publishing key filed dormant, collaborators as pending
  invitations. This adds exactly one thing: `handoff_origin`.

  Refusals, and why each is a refusal rather than a best effort:

    * `{:error, :not_a_handoff}` - no `"handoff"` block, the wrong format tag,
      or no token in it. **An ordinary backup lands here**, and must: it has
      no token, so treating it as a hand-off would produce a copy that
      believes it can release a source which is not locked and never was.
      That belief is only discovered much later, by an arbiter pressing a
      button that cannot work.
    * `{:error, {:unsupported_version, v}}` - a block from a build that means
      something different by "token". Refused rather than read optimistically.
    * `{:error, :not_one_tournament}` - a hand-off is one event moving to one
      machine. A multi-tournament envelope carries one token, which cannot
      say which of them it unlocks.
    * `{:error, :already_received}` - this machine already holds a copy that
      arrived with this token, so importing again would put two live copies of
      one event in one database. Checked across the whole installation, not
      per user: a second account is not a second machine.
    * `{:error, message}` when it is a string - straight from
      `TournamentImport.import/2`, already safe to show.
  """
  @spec receive(term(), Scope.t()) :: {:ok, Tournament.t()} | {:error, reason()}
  def receive(data, %Scope{} = scope) when is_map(data) do
    with {:ok, token} <- handoff_block(data),
         :ok <- exactly_one_tournament(data),
         :ok <- not_already_received(token),
         {:ok, tournament} <- import_one(data, scope) do
      record_origin(tournament, data, token, scope)
    end
  end

  def receive(_data, %Scope{}), do: {:error, :not_a_handoff}

  # The whole distinction between a hand-off and a backup, in one place.
  defp handoff_block(data) do
    with %{} = block <- Map.get(data, "handoff"),
         ^block <- if(Map.get(block, "format") == @handoff_format, do: block, else: nil) do
      case Map.get(block, "version") do
        @handoff_version -> block_token(block)
        other -> {:error, {:unsupported_version, other}}
      end
    else
      _not_a_handoff -> {:error, :not_a_handoff}
    end
  end

  defp block_token(block) do
    case Map.get(block, "token") do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> {:error, :not_a_handoff}
    end
  end

  defp exactly_one_tournament(data) do
    with {:ok, _entry} <- only_entry(data), do: :ok
  end

  # Walked in Elixir rather than queried through SQLite's JSON functions: the
  # rows that have an origin at all are a handful, and the comparison has to
  # be constant-time, which a `WHERE json_extract(...) = ?` is not.
  #
  # Binned tournaments count. A copy in the recycle bin can be restored, and a
  # restore that produced a second live copy of a running event would be the
  # exact failure this check exists for. The cost is that a hand-off received
  # by mistake and then binned cannot be received again without emptying the
  # bin - which is the safe direction to be wrong in.
  defp not_already_received(token) do
    already? =
      Repo.all(
        from t in Tournament, where: not is_nil(t.handoff_origin), select: t.handoff_origin
      )
      |> Enum.any?(&origin_holds_token?(&1, token))

    if already?, do: {:error, :already_received}, else: :ok
  end

  defp origin_holds_token?(%{"release_token" => stored}, presented)
       when is_binary(stored) and is_binary(presented),
       do: Plug.Crypto.secure_compare(stored, presented)

  defp origin_holds_token?(_origin, _presented), do: false

  # Deliberately NOT wrapped in a transaction of this module's own.
  # `TournamentImport.import/2` opens one already, and a nested `Repo.rollback`
  # aborts the outer connection rather than returning cleanly - so an outer
  # transaction here would turn the import's readable `{:error, message}` into
  # a `DBConnection` crash on the very next query. `record_origin/4` picks up
  # the pieces instead.
  defp import_one(data, scope) do
    case TournamentImport.import(data, scope) do
      {:ok, [tournament]} -> {:ok, tournament}
      {:ok, _many} -> {:error, :not_one_tournament}
      {:error, reason} -> {:error, reason}
    end
  end

  # If this write fails, the machine is holding a live copy of somebody's
  # running tournament with no way to give it back - which is worse than not
  # having received it, because the source stays locked forever. So the copy
  # goes to the recycle bin and the caller is told plainly, rather than being
  # handed a tournament with a missing key it will not discover for days.
  defp record_origin(tournament, data, token, scope) do
    changeset = Ecto.Changeset.change(tournament, handoff_origin: origin_record(data, token))

    case Repo.update(changeset) do
      {:ok, updated} ->
        Audit.log(updated.id, scope, "handoff.received", %{
          "from" => updated.handoff_origin["instance"],
          "address" => updated.handoff_origin["address"],
          "name" => updated.name
        })

        {:ok, updated}

      {:error, _changeset} ->
        Tournaments.soft_delete_tournament(tournament)
        {:error, :origin_not_recorded}
    end
  end

  # Rebuilt into a fresh map rather than passed through, on the same reasoning
  # as `TournamentImport`'s dormant OpenResults claim: a hand-edited file must
  # not be able to smuggle extra keys into a column this module reads back.
  defp origin_record(data, token) do
    origin =
      case get_in(data, ["handoff", "origin"]) do
        %{} = block -> block
        _ -> %{}
      end

    %{
      "instance" => text(Map.get(origin, "instance")),
      "address" => text(Map.get(origin, "address")),
      # What THEY called this machine. Kept because it is the phrase the
      # arbiter typed on the other end, and the one they will recognise.
      "label" => text(Map.get(origin, "handed_off_to")),
      "release_token" => token,
      "handed_off_at" => text(Map.get(origin, "handed_off_at")),
      "received_at" => now_iso()
    }
  end

  ## ---------- giving it back ----------

  @doc """
  The mirror of `hand_off/3`: locks this copy and returns the envelope that
  unlocks the one it came from.

  Same single transaction and the same order - this copy stops accepting
  writes before the file exists, so there is no instant at which both copies
  are live. The destination is not asked for: a return goes back where it came
  from, and that is on the row already.

  Refuses `{:error, :not_received}` for a tournament that did not arrive by
  hand-off. There is no key on it, so there is nothing anywhere for a
  returning file to unlock, and producing one would be a promise this machine
  cannot keep.

  Refuses `{:error, :already_handed_off}` on a second attempt, which is
  `hand_off/2`'s lock doing its job: the first return already parked this copy.

  The `handoff_origin` column is deliberately left in place. "Came from A" is
  still true after a return, and after handing this copy on to C both facts
  are true at once - which is why they were never stored in the same place.
  """
  @spec return(Tournament.t(), Scope.t() | integer() | nil) ::
          {:ok, payload()} | {:error, reason()}
  def return(%Tournament{} = tournament, actor) do
    case release_token(tournament) do
      nil -> {:error, :not_received}
      token -> Repo.transaction(fn -> lock_and_return(tournament, token, actor) end)
    end
  end

  defp lock_and_return(tournament, token, actor) do
    origin = tournament.handoff_origin
    destination = return_destination(origin)

    case Tournaments.hand_off(tournament, destination) do
      {:ok, locked} ->
        Audit.log(locked.id, actor, "handoff.returned", %{
          "to" => destination,
          "address" => Map.get(origin, "address"),
          "name" => locked.name
        })

        locked
        |> envelope("back", token, %{
          "instance" => instance_name(),
          "address" => instance_address(),
          "handed_off_at" => DateTime.to_iso8601(locked.handed_off_at),
          "handed_off_to" => destination
        })
        # Where it is going, as the far side described itself when it sent
        # this copy out. Without the release token, which is already in the
        # block's own `"token"` and has no business being in the file twice.
        |> put_in(["handoff", "returning_to"], Map.delete(origin, "release_token"))

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  # Whatever the source called itself, falling back through the things a file
  # might actually carry. Never blank: this becomes `handed_off_to`, i.e. the
  # whole content of the banner on the copy being parked here.
  defp return_destination(origin) do
    [Map.get(origin, "instance"), Map.get(origin, "address"), Map.get(origin, "label")]
    |> Enum.map(&text/1)
    |> Enum.find("the copy it came from", &(&1 != ""))
  end

  @doc """
  Brings `tournament` home: replaces its contents with the returning
  envelope's and unlocks it, in one transaction.

  `data` is the JSON-decoded returning file - the whole envelope, not just its
  token, because the tournament in it is the point. The copy left behind has
  been read-only for the entire trip (`ensure_writable/1` refuses every write
  path while `handed_off_at` is set), so it CANNOT have diverged from what
  went out; the returning file is that same event with more of it played.
  Replacing the frozen state with it therefore loses nothing, and it is the
  only thing that makes the round trip a hand-off rather than a lock with
  extra steps.

  ## The order, and why

  Inside one transaction, all of it or none of it:

    1. a **pinned restore point** of the current (frozen) state, before
       anything is touched - so an arbiter who applies the wrong file, or who
       simply wants to see what was here, can get it back. It is captured
       inside the transaction for the reason `PairingsEngine.Snapshots`
       learned the hard way: committed ahead of it, a restore that then fails
       leaves a snapshot and a moved HEAD hanging off a state that never
       happened. Unlike every other capture in the app this one is NOT
       fire-and-forget - if it cannot be written the release is refused with
       `{:error, :no_restore_point}`, because here the snapshot is the only
       copy of what is about to be destroyed, and refusing costs the arbiter
       nothing: the file is still in their hands and this copy is still
       locked.
    2. `PairingsEngine.Snapshots.wipe_contents/1` then
       `PairingsEngine.TournamentImport.restore_into!/2` - the same pair
       `Snapshots.restore/3` uses, which is why a returning file cannot land
       in a shape a restore point could not.
    3. `PairingsEngine.Tournaments.take_back/2` last, so the copy is up to
       date at the instant it becomes writable and never before. A bad token
       discovered here rolls the whole thing back, contents included.

  ## What it refuses, and why each one

    * `{:error, :not_a_return}` / `{:error, :not_a_handoff}` /
      `{:error, {:unsupported_version, v}}` - `returning_token/1`'s
      refusals, unchanged: an outbound file, an ordinary backup, a file from
      a build that means something else by "token".
    * `{:error, :not_one_tournament}` - one token cannot say which of several
      tournaments it unlocks, and now also which of them to apply.
    * `{:error, :force_unlocked}` - the break-glass was used on this
      tournament for the very trip this file is returning from, so BOTH
      copies have live work and neither can be discarded. See below.
    * `{:error, :not_this_tournament}` - the file is a return, but not this
      one's. See below.
    * `{:error, :bad_token}` - every other way the key fails, including a
      tournament that is not handed off at all: it holds no token, so no
      value unlocks it. Releasing is therefore NOT idempotent - applying the
      same file twice fails the second time, which is deliberate: by then the
      tournament may be legitimately checked out somewhere else.
    * `{:error, message}` when it is a string - straight from
      `restore_into!/2` via `Repo.rollback/1`, already safe to show. The
      source is untouched and still locked.

  ## Identity: what it matches on

  The token authenticates the ENVELOPE. It says nothing about the body, which
  is a separate block of the same file - so before anything is replaced, the
  payload has to name this tournament. Three things have to agree:

    * `handoff.returning_to.handed_off_at` - the far side's record of which
      departure this copy came out on, stored at `receive/2` from the origin
      block we ourselves wrote - must be the instant on this row's
      `handed_off_at`;
    * the payload's own audit trail must contain the `handoff.handed_off` row
      for that same instant and destination. This is the part that binds the
      BODY rather than the envelope: the trail travels inside the tournament
      entry, so a body that never left this machine on that date, for that
      destination, cannot carry it;
    * and the token itself, compared constant-time against this row's, by
      `take_back/2`.

  That is sufficient because a wrong file fails at least one of them and the
  contents are only replaced when all three hold. The residual is worth
  stating: nothing binds the block to the body cryptographically, so a
  hand-edited file that splices one file's token onto another's tournament is
  caught by the trail check and not by mathematics - and a file whose holder
  is willing to edit it already holds the token, which is the thing the lock
  never claimed to resist. Two tournaments locked in the same second to the
  same label would also pass the first two checks; the token then refuses
  them, so the outcome is a `:bad_token` message rather than a wrong replace.

  ## The forced unlock, which is the sharp one

  `PairingsEngine.Tournaments.force_take_back/2` unlocks WITHOUT a token,
  because a laptop at the bottom of a canal would otherwise leave this copy
  read-only forever. After it, this copy is live and CAN diverge - and if the
  lost copy then turns up, applying it would silently destroy everything done
  here since.

  So a returning file for a trip that was force-unlocked here is refused
  outright, and the arbiter is told to import it as a separate tournament and
  reconcile the two by hand. Nothing here guesses which copy wins: that is the
  merge this whole design exists to refuse.

  Detection is the `"tournament.handoff_forced"` audit row
  (`Tournaments.forced_unlock_action/0`), matched to THIS trip by the token
  fingerprint it records (`Tournaments.handoff_token_digest/1`) - the audit
  log is a strong enough signal precisely because the break-glass writes its
  row inside its own transaction rather than leaving it to a call site, so a
  forced unlock cannot happen without one. Rows written before the fingerprint
  existed fall back to the lock's timestamp and destination label, which can
  in principle repeat; the failure direction there is an extra refusal, never
  a silent replace.

  A forced unlock is not a permanent mark. A tournament that was broken open
  and then handed off again cleanly has been read-only for that whole second
  trip, so that trip's file applies normally - only the abandoned trip's file
  is refused.

  ## What still does not come back

  The far side's AUDIT TRAIL. `restore_into!/2` writes contents, not history,
  and re-inserting the file's trail would duplicate the part of it that never
  left this machine. So the results come home and the record of who typed them
  over there does not; the departure and the release are both on this copy's
  trail, and the file itself remains the evidence.

  `actor` is optional; pass the acting scope from a UI so the trail names a
  person rather than "System".
  """
  @spec release(Tournament.t(), term(), Scope.t() | integer() | nil) ::
          {:ok, Tournament.t()} | {:error, reason()}
  def release(%Tournament{} = tournament, data, actor \\ nil) do
    # Re-read the row first: the caller's struct is typically one a LiveView
    # loaded when the panel was opened, and every check below - which lock is
    # current, which token unlocks it - is a question about the row NOW. A
    # stale struct could pass them all and then unlock a lock that has since
    # been taken back and handed somewhere else, which is precisely the
    # two-live-copies state. It narrows the window rather than closing it;
    # `take_back/2` clears by id, so a hand-off in the microseconds between
    # this read and the transaction would still be missed.
    case Repo.reload(tournament) do
      %Tournament{} = current -> do_release(current, data, actor)
      nil -> {:error, :not_this_tournament}
    end
  end

  defp do_release(tournament, data, actor) do
    with {:ok, token} <- returning_token(data),
         {:ok, entry} <- only_entry(data),
         {:ok, trip} <- returning_trip(data),
         :ok <- not_force_unlocked(tournament, token, trip),
         :ok <- this_tournament(tournament, entry, trip) do
      apply_and_unlock(tournament, entry, token, actor)
    end
  end

  # Everything the returning file says about which departure it is coming back
  # from. Written by `hand_off/3` into the origin block, stored verbatim by
  # `receive/2`, and echoed back by `return/2` - so it is this machine's own
  # words returning, which is what makes it worth matching on.
  defp returning_trip(data) do
    with %{} = returning_to <- get_in(data, ["handoff", "returning_to"]),
         {:ok, left_at} <- instant(Map.get(returning_to, "handed_off_at")) do
      {:ok, %{left_at: left_at, label: Map.get(returning_to, "label")}}
    else
      _no_trip -> {:error, :not_this_tournament}
    end
  end

  defp only_entry(data) do
    case Map.get(data, "tournaments") do
      [entry] when is_map(entry) -> {:ok, entry}
      _ -> {:error, :not_one_tournament}
    end
  end

  # Queried straight rather than through `PairingsEngine.Audit.list_for_tournament/2`,
  # which pages: a forced unlock from the start of a long event would sit well
  # past any limit, and missing it is the one failure this check cannot have.
  defp not_force_unlocked(tournament, token, trip) do
    action = Tournaments.forced_unlock_action()
    digest = Tournaments.handoff_token_digest(token)

    forced =
      Repo.all(
        from a in AuditLog,
          where: a.tournament_id == ^tournament.id and a.action == ^action,
          select: a.details
      )

    if Enum.any?(forced, &forced_this_trip?(&1, digest, trip)),
      do: {:error, :force_unlocked},
      else: :ok
  end

  defp forced_this_trip?(%{"was_handoff_token" => recorded}, digest, _trip)
       when is_binary(recorded) and is_binary(digest),
       do: recorded == digest

  # No fingerprint on the row: it was written by a build that did not record
  # one. The lock's instant and its destination label are what is left, and
  # both can legitimately repeat - so this can refuse a file it did not have
  # to. That is the safe direction: the remedy is importing the file as a
  # separate tournament, and the alternative is overwriting live work.
  defp forced_this_trip?(%{} = details, _digest, trip) do
    same_instant?(Map.get(details, "was_handed_off_at"), trip.left_at) and
      Map.get(details, "was_handed_off_to") == trip.label
  end

  defp forced_this_trip?(_details, _digest, _trip), do: false

  # A tournament that is not handed off holds no token, so nothing unlocks it -
  # `:bad_token` rather than a second refusal an arbiter would have to be
  # taught to tell apart (see `take_back/2`).
  defp this_tournament(%Tournament{handed_off_at: nil}, _entry, _trip), do: {:error, :bad_token}

  defp this_tournament(%Tournament{} = tournament, entry, trip) do
    if DateTime.compare(tournament.handed_off_at, trip.left_at) == :eq and
         departure_in_trail?(entry, tournament) do
      :ok
    else
      {:error, :not_this_tournament}
    end
  end

  # The body's own record of leaving here, written by `lock_and_build/3`
  # BEFORE the payload was built precisely so it would travel with it.
  defp departure_in_trail?(entry, tournament) do
    entry
    |> Map.get("audit_log")
    |> List.wrap()
    |> Enum.any?(fn
      %{"action" => "handoff.handed_off", "details" => %{"at" => at, "to" => to}} ->
        to == tournament.handed_off_to and same_instant?(at, tournament.handed_off_at)

      _other_row ->
        false
    end)
  end

  defp apply_and_unlock(tournament, entry, token, actor) do
    # Read before the compare, because `take_back/2` clears it on success and
    # "released from where" is the only interesting thing about the row.
    from_label = tournament.handed_off_to

    result =
      Tournaments.with_broadcast_suppressed(fn ->
        Repo.transaction(fn ->
          restore_point!(tournament, from_label, actor)

          # Written while the tournament is still locked, which is safe only
          # because these two go through `Repo` directly rather than through
          # the `Tournaments` write paths `ensure_writable/1` guards. The lock
          # is lifted below, after the contents are already correct.
          Snapshots.wipe_contents(tournament.id)
          restored = TournamentImport.restore_into!(tournament, entry)

          case Tournaments.take_back(restored, token) do
            {:ok, unlocked} ->
              Audit.log(unlocked.id, actor, "handoff.released", %{
                "from" => from_label,
                "name" => unlocked.name
              })

              unlocked

            {:error, reason} ->
              Repo.rollback(reason)
          end
        end)
      end)

    case result do
      {:ok, unlocked} ->
        Tournaments.broadcast_tournament_change(unlocked.id, :tournament)
        Tournaments.broadcast_tournament_list(unlocked)
        {:ok, Tournaments.refresh_status!(unlocked.id)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp restore_point!(tournament, from_label, actor) do
    summary = "Before the return from #{from_label || "the other copy"}"

    case Snapshots.capture(tournament, "handoff.released", actor,
           summary: summary,
           pinned: true
         ) do
      {:ok, snapshot} -> snapshot
      {:error, _reason} -> Repo.rollback(:no_restore_point)
    end
  end

  defp instant(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> {:ok, DateTime.truncate(at, :second)}
      _unparseable -> :error
    end
  end

  defp instant(_value), do: :error

  defp same_instant?(value, %DateTime{} = at) do
    case instant(value) do
      {:ok, parsed} -> DateTime.compare(parsed, at) == :eq
      :error -> false
    end
  end

  defp same_instant?(_value, _at), do: false

  @doc """
  The token inside a RETURNING envelope.

  `release/3` calls this itself - it takes the whole envelope, because the
  tournament in it is applied as well as the key. This stays public because
  "is this file a return, and for what" is a question worth being able to ask
  without changing anything.

  Refuses `{:error, :not_a_return}` for a file that is a hand-off but points
  the wrong way - which is the mistake worth catching. The outbound envelope
  carries the same token as the returning one, so feeding the original file
  back into "bring it back" would unlock the source while the other machine is
  still running the event on its live copy. That is the two-live-copies state,
  reached by picking the wrong file out of a downloads folder in which both
  are called something similar.

  The check is a field in a JSON file and anybody can edit it, so it stops an
  honest mistake and not an attacker. An attacker holding the file already
  holds the token.
  """
  @spec returning_token(term()) :: {:ok, String.t()} | {:error, reason() | :not_a_return}
  def returning_token(data) when is_map(data) do
    with {:ok, token} <- handoff_block(data) do
      case get_in(data, ["handoff", "direction"]) do
        "back" -> {:ok, token}
        _other -> {:error, :not_a_return}
      end
    end
  end

  def returning_token(_data), do: {:error, :not_a_handoff}

  ## ---------- questions the UI asks ----------

  @doc """
  Whether this copy has been handed AWAY - checked out to another machine, and
  therefore read-only here.

  The counterpart of `received?/1`, and the pair exists so no screen has to
  work it out from raw columns. Saying the wrong one of the two is the most
  damaging thing this feature's UI can do: it either tells an arbiter their
  live tournament is somewhere else, or shows a locked one as if it were
  ready to take results.
  """
  @spec handed_away?(Tournament.t()) :: boolean()
  def handed_away?(%Tournament{} = tournament), do: Tournaments.handed_off?(tournament)

  @doc """
  Whether this copy ARRIVED from another machine and still holds the key that
  unlocks it - i.e. whether `return/2` has anything to do.

  Independent of `handed_away?/1` on purpose: after a return, and after being
  handed on to a third machine, both are true.
  """
  @spec received?(Tournament.t()) :: boolean()
  def received?(%Tournament{} = tournament), do: release_token(tournament) != nil

  @doc """
  Where a received copy came from, as a label a person can read, or nil for a
  tournament that was created here.
  """
  @spec origin_label(Tournament.t()) :: String.t() | nil
  def origin_label(%Tournament{handoff_origin: %{} = origin} = tournament) do
    if received?(tournament), do: return_destination(origin), else: nil
  end

  def origin_label(%Tournament{}), do: nil

  defp release_token(%Tournament{handoff_origin: %{"release_token" => token}})
       when is_binary(token) and token != "",
       do: token

  defp release_token(%Tournament{}), do: nil

  ## ---------- the envelope ----------

  defp envelope(tournament, direction, token, origin) do
    tournament
    |> TournamentExport.export_tournament(include_handoff: true)
    |> Map.put("handoff", %{
      "format" => @handoff_format,
      "version" => @handoff_version,
      "direction" => direction,
      "token" => token,
      "origin" => origin
    })
  end

  ## ---------- this machine, as far as it can tell ----------

  # The hostname, which is what an arbiter looking at two laptops will
  # recognise. Not an identity and not checked by anything - see the
  # moduledoc's second bullet.
  defp instance_name do
    case :inet.gethostname() do
      {:ok, name} -> to_string(name)
      _ -> "an OpenPairings install"
    end
  end

  # The URL this installation believes it serves, which on a laptop is
  # `http://localhost:4000` and means nothing to the far side. Carried anyway,
  # because on a hosted instance it is exactly the address an arbiter needs to
  # get back to, and an empty string is honest about the other case.
  defp instance_address do
    PairingsEngineWeb.Endpoint.url()
  rescue
    _endpoint_not_running -> ""
  end

  defp now_iso, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp text(value) when is_binary(value), do: value |> String.trim() |> String.slice(0, @max_text)
  defp text(_value), do: ""
end
