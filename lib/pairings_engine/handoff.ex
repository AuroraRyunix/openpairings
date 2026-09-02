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
      release/2    <-------- envelope with token -----    return/2     (lock B)
      (A live)

  ## What this is NOT, honestly

  Four things a reader should know before trusting it:

    * **Releasing does not bring the results back.** `release/2` unlocks the
      original and nothing more. The copy that was left behind is frozen at
      the moment it was handed off, so after a release it is writable AND
      stale - it does not know about the three rounds played on the other
      machine. The returning file contains those rounds; getting them onto
      this machine means importing it as a separate tournament and deciding
      which row is the real one by hand. That is the sharpest rough edge in
      the design and the UI says so in as many words.
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

  alias PairingsEngine.{Audit, Repo, TournamentExport, TournamentImport, Tournaments}
  alias PairingsEngine.Accounts.Scope
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
          | :no_destination
          | :not_a_handoff
          | :not_one_tournament
          | :not_received
          | :origin_not_recorded
          | {:unsupported_version, term()}
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
    case Map.get(data, "tournaments") do
      [_only_one] -> :ok
      _ -> {:error, :not_one_tournament}
    end
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
  Unlocks `tournament` with the token a returning envelope carried, and
  records it in the audit trail.

  Thin on purpose - `PairingsEngine.Tournaments.take_back/2` does the
  constant-time compare and the clearing, and this adds the trail entry,
  because "the tournament came back" is exactly the kind of fact a dispute
  turns on later.

  `{:error, :bad_token}` covers every failure, including a tournament that is
  not handed off at all: it holds no token, so no value unlocks it. The
  practical consequence is that releasing is NOT idempotent - a payload
  applied twice fails the second time, because the first attempt erased the
  thing the token is compared against. That is deliberate. By the time
  somebody applies a returning file twice, the tournament may have been handed
  off somewhere else entirely, and silently succeeding would unlock a copy
  that is legitimately checked out.

  **This does not bring the results back.** See the moduledoc: the tournament
  is writable again but still says what it said when it left. The returning
  file holds the newer version of the event, and merging the two is a decision
  no code here makes.

  `actor` is optional so `release/2` reads the way the flow describes it; pass
  the acting scope from a UI so the trail names a person rather than "System".
  """
  @spec release(Tournament.t(), String.t() | nil, Scope.t() | integer() | nil) ::
          {:ok, Tournament.t()} | {:error, :bad_token | Ecto.Changeset.t()}
  def release(%Tournament{} = tournament, token, actor \\ nil) do
    # Read before the compare, because `take_back/2` clears it on success and
    # "released from where" is the only interesting thing about the row.
    from_label = tournament.handed_off_to

    case Tournaments.take_back(tournament, token) do
      {:ok, unlocked} ->
        Audit.log(unlocked.id, actor, "handoff.released", %{
          "from" => from_label,
          "name" => unlocked.name
        })

        {:ok, unlocked}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The token inside a RETURNING envelope, ready to hand to `release/3`.

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
