defmodule PairingsEngine.Tournaments do
  @moduledoc """
  Tournament, player, team and round management, plus ownership/access
  control - who owns a tournament, and who else it's been shared with (see
  `PairingsEngine.Tournaments.Collaborator` and `docs/teams.md` for the
  full "share a tournament by email" feature).
  """

  import Ecto.Query
  alias PairingsEngine.Audit
  alias PairingsEngine.BusyWrite
  alias PairingsEngine.Repo
  alias PairingsEngine.Tiebreaks
  alias PairingsEngine.Standings
  alias PairingsEngine.PlayerStats
  alias PairingsEngine.PairingDisplay
  alias PairingsEngine.Accounts
  alias PairingsEngine.Accounts.{Scope, User}

  alias PairingsEngine.Tournaments.{
    Tournament,
    Player,
    Team,
    Round,
    Pairing,
    Collaborator,
    ForbiddenPairing
  }

  ## ---------- Live updates (PubSub) ----------
  #
  # Every write in this module (and in the other modules that mutate
  # tournament-scoped data directly, namely PairingsEngine.Pairing and
  # PairingsEngine.Federations.BEL.SwarImport) broadcasts on the tournament's topic so any
  # open LiveView showing that tournament can reload instantly instead of
  # polling. `hint` is a lightweight atom describing what changed
  # (:players, :pairings, :results, :settings, :rounds, :tournament) - most
  # subscribers just reload their data regardless of the exact hint, but it
  # keeps the message self-documenting.

  @doc "PubSub topic for live updates scoped to a single tournament."
  def tournament_topic(tournament_id), do: "tournament:#{tournament_id}"

  @doc "PubSub topic for a user's tournament list (create/update/delete)."
  def user_tournaments_topic(user_id), do: "tournaments_user:#{user_id}"

  @doc "Broadcasts `{:tournament_changed, tournament_id, hint}` on the tournament's topic."
  def broadcast_tournament_change(tournament_id, hint) do
    unless broadcast_suppressed?() do
      Phoenix.PubSub.broadcast(
        PairingsEngine.PubSub,
        tournament_topic(tournament_id),
        {:tournament_changed, tournament_id, hint}
      )

      # Anything worth telling an open LiveView about is worth telling the
      # public page about, so publishing hangs off the same funnel rather
      # than off a list of call sites somebody has to keep in step. It is a
      # no-op unless this tournament opted in, and the queue dedupes, so a
      # burst of writes is one publish rather than one per keystroke.
      #
      # Deliberately inside the `unless`: a bulk import suppresses these and
      # broadcasts once after committing, and enqueueing per row inside an
      # uncommitted transaction would be both wasteful and, if the drain ran
      # at the wrong moment, a snapshot of a half-imported tournament.
      PairingsEngine.Publishing.enqueue_id(tournament_id)
    end

    :ok
  end

  @doc """
  Tells everyone whose tournament LIST just changed - the owner and every
  accepted collaborator.

  ## Why this exists separately

  `broadcast_user_tournaments/1` reaches one person. Seven lifecycle writes
  called it with the owner's id and nobody else's, so an owner deleting,
  archiving or restoring a shared tournament left every collaborator's
  Tournaments page showing a row that was gone, or missing one that was
  back, until they happened to reload.

  The collaborator-specific functions - `add_collaborator/3`,
  `remove_collaborator/3`, `leave_tournament/2`, `accept_invitation/2` -
  always did fan out to the other party. It was only the tournament's own
  lifecycle that forgot the other party existed.

  Accepted only: a pending invitation is not on anybody's list yet, so
  there is nothing to refresh. A collaborator row can also carry an email
  with no `user_id` (invited before that person had an account), and those
  have no topic to broadcast on - `broadcast_user_tournaments/1` already
  answers `:ok` for a nil id, which is why this can pass them straight
  through.
  """
  def broadcast_tournament_list(%Tournament{} = tournament) do
    broadcast_user_tournaments(tournament.user_id)

    Repo.all(
      from c in Collaborator,
        where: c.tournament_id == ^tournament.id and c.status == "accepted",
        select: c.user_id
    )
    |> Enum.each(&broadcast_user_tournaments/1)
  end

  @doc "Broadcasts `{:tournaments_changed, user_id}` on the user's tournament-list topic."
  def broadcast_user_tournaments(nil), do: :ok

  def broadcast_user_tournaments(user_id) do
    unless broadcast_suppressed?() do
      Phoenix.PubSub.broadcast(
        PairingsEngine.PubSub,
        user_tournaments_topic(user_id),
        {:tournaments_changed, user_id}
      )
    end

    :ok
  end

  @suppress_key :pairings_engine_suppress_tournament_broadcast

  @doc """
  Runs `fun` with per-write broadcasting suppressed for the current
  process. Used by bulk operations that wrap many individual writes in a
  single `Repo.transaction` (e.g. `PairingsEngine.Federations.BEL.SwarImport`) - broadcasting
  from inside an uncommitted transaction would let a subscriber query the
  database before the writes are actually visible. The caller is
  responsible for broadcasting once, after the transaction has committed.
  """
  def with_broadcast_suppressed(fun) do
    previous = Process.get(@suppress_key, false)
    Process.put(@suppress_key, true)

    try do
      fun.()
    after
      Process.put(@suppress_key, previous)
    end
  end

  defp broadcast_suppressed?, do: Process.get(@suppress_key, false)

  ## Tournaments

  @doc """
  Lists the tournaments the scope's user owns or collaborates on (see
  `add_collaborator/3`), most recently created first.

  Returns `{tournament, player_count, owner?}` tuples - `owner?` is `true`
  when `scope.user` is the tournament's owner and `false` when it's shared
  with them as a collaborator, so the UI can tell the two apart (e.g. a
  "shared" badge).

  Excludes both recycle-binned (`deleted_at`) and archived (`archived_at`)
  tournaments - each has its own listing (`list_deleted_tournaments/1`,
  `list_archived_tournaments/1`) and its own panel on the Tournaments page.
  Note the two are independent flags, so an archived tournament that is
  later deleted correctly disappears from the archive list too (see
  `list_archived_tournaments/1`'s own `deleted_at` check).
  """
  def list_tournaments(%Scope{} = scope) do
    user = scope.user

    Repo.all(
      from t in Tournament,
        left_join: p in assoc(t, :players),
        where:
          is_nil(t.deleted_at) and is_nil(t.archived_at) and
            (t.user_id == ^user.id or t.id in subquery(collaborator_tournament_ids(user))),
        group_by: t.id,
        select: {t, count(p.id), t.user_id == ^user.id},
        order_by: [desc: t.inserted_at]
    )
  end

  @doc "True if `scope.user` is the tournament's owner (as opposed to a collaborator)."
  def owner?(%Tournament{} = tournament, %Scope{} = scope),
    do: tournament.user_id == scope.user.id

  @doc """
  Gets a tournament by id, excluding soft-deleted (recycle-binned) ones -
  see `soft_delete_tournament/1`. Raises `Ecto.NoResultsError` if the
  tournament doesn't exist or is currently in the recycle bin.
  """
  def get_tournament!(id) do
    Repo.one!(from t in Tournament, where: t.id == ^id and is_nil(t.deleted_at))
  end

  @doc "Like `get_tournament!/1` but returns nil instead of raising when absent/deleted."
  def get_tournament(id) do
    Repo.one(from t in Tournament, where: t.id == ^id and is_nil(t.deleted_at))
  end

  @doc """
  Finds an existing, non-deleted tournament (owned by or shared with
  `scope`'s user) that was already imported from the same `.swar` file -
  matched on `swar_guid`, the persistent per-tournament id SWAR itself
  stamps into every export of the same tournament (see
  `PairingsEngine.Federations.BEL.SwarImport.parse/1`'s `:guid`). Used to warn before a
  re-upload of the same tournament silently creates a duplicate - see
  docs/import-export.md. `nil` for a blank guid or no match; only ever
  matches within the uploading user's own accessible tournaments, never
  across unrelated accounts.
  """
  def find_tournament_by_swar_guid(%Scope{} = scope, guid) when guid not in [nil, ""] do
    user = scope.user

    Repo.one(
      from t in Tournament,
        where:
          t.swar_guid == ^guid and is_nil(t.deleted_at) and
            (t.user_id == ^user.id or t.id in subquery(collaborator_tournament_ids(user))),
        limit: 1
    )
  end

  def find_tournament_by_swar_guid(_scope, _guid), do: nil

  @doc """
  Gets a tournament owned by the scope's user.

  Raises `Ecto.NoResultsError` if the tournament doesn't exist or isn't
  owned by the scope's user (so URL guessing can't leak other users' data).
  """
  def get_user_tournament!(%Scope{} = scope, id) do
    Repo.one!(
      from t in Tournament,
        where: t.id == ^id and t.user_id == ^scope.user.id and is_nil(t.deleted_at)
    )
  end

  @doc """
  Same as `get_user_tournament!/2`, but returns `nil` instead of raising -
  useful when reloading after a PubSub notification, since the tournament
  may have been deleted (by another tab/user) in the meantime.
  """
  def get_user_tournament(%Scope{} = scope, id) do
    Repo.one(
      from t in Tournament,
        where: t.id == ^id and t.user_id == ^scope.user.id and is_nil(t.deleted_at)
    )
  end

  @doc """
  Gets tournament `id`, owned by the scope's user, **including** ones
  currently in the recycle bin (`deleted_at` set) - the counterpart to
  `get_user_tournament!/2` for the Recycle bin panel's Restore/Delete
  permanently actions, which need to load the very row `list_tournaments/1`
  now hides. Raises `Ecto.NoResultsError` if the tournament doesn't exist or
  isn't owned by the scope's user.
  """
  def get_owned_tournament_including_deleted!(%Scope{} = scope, id) do
    Repo.get_by!(Tournament, id: id, user_id: scope.user.id)
  end

  @doc """
  Gets a tournament the scope's user is authorized to access - either
  because they own it, or because they collaborate on it (matched by
  `user_id`, or by `email` for a not-yet-linked pending invite; see
  `link_pending_collaborators/1`).

  Use this (instead of `get_user_tournament!/2`) for every tournament-scoped
  view/action a collaborator should also be able to use - everything except
  managing collaborators and deleting the tournament, which stay
  owner-only via `get_user_tournament!/2`.

  Raises `Ecto.NoResultsError` if the tournament doesn't exist or the
  scope's user has no access to it, so URL guessing 404s exactly like
  `get_user_tournament!/2` does for non-owners.
  """
  def get_authorized_tournament!(%Scope{} = scope, id) do
    Repo.one!(authorized_tournament_query(scope, id))
  end

  @doc """
  Same as `get_authorized_tournament!/2`, but returns `nil` instead of
  raising - useful when reloading after a PubSub notification, since the
  tournament may have been deleted (or the caller's access revoked) in the
  meantime.
  """
  def get_authorized_tournament(%Scope{} = scope, id) do
    Repo.one(authorized_tournament_query(scope, id))
  end

  defp authorized_tournament_query(%Scope{} = scope, id) do
    user = scope.user

    from t in Tournament,
      where:
        t.id == ^id and is_nil(t.deleted_at) and
          (t.user_id == ^user.id or t.id in subquery(collaborator_tournament_ids(user)))
  end

  # Only *accepted* collaborator rows grant access - a pending invite (added
  # but not yet accepted via `/invites/:token`, see `accept_invitation/2`)
  # must not unlock the tournament for anyone. This is the single choke
  # point both `authorized_tournament_query/2` and `list_tournaments/1` go
  # through, so it's the only place that needs to know about `status`.
  defp collaborator_tournament_ids(%User{} = user) do
    from c in Collaborator,
      where: c.status == "accepted" and (c.user_id == ^user.id or c.email == ^user.email),
      select: c.tournament_id
  end

  ## Collaborators (tournament sharing by email - see docs/teams.md)

  @doc "Lists a tournament's collaborators (pending and active), most recently added first."
  def list_collaborators(%Tournament{} = tournament) do
    Repo.all(
      from c in Collaborator,
        where: c.tournament_id == ^tournament.id,
        order_by: [desc: c.inserted_at]
    )
  end

  @doc """
  Invites `email` to collaborate on `tournament`. Owner-only - returns
  `{:error, :not_owner}` unless `scope.user` is the tournament's owner.

  This grants **no access by itself** - it creates a `status: "pending"`
  row with a fresh `invite_token` and emails that person a link to
  `/invites/:token` (see `PairingsEngineWeb.InviteLive`), where they must
  explicitly accept (`accept_invitation/2`) before `collaborator_tournament_ids/1`
  will count them. If a user with this email already exists, `user_id` is
  linked immediately (a courtesy for `list_pending_invitations/1`,
  irrelevant to access); otherwise it stays `nil` until that person logs in
  (see `link_pending_collaborators/1`) or accepts. Rejects the owner's own
  email and a duplicate email gracefully rather than raising.

  Returns `{:ok, collaborator}` on success, where `collaborator.mail_status`
  (a virtual field, not persisted) is `:sent` or `:failed` - the row is
  still created even if the invitation email couldn't be delivered (e.g. an
  SMTP hiccup), so the owner can share `/invites/<invite_token>` manually.
  """
  def add_collaborator(%Scope{} = scope, %Tournament{} = tournament, email) do
    email = normalize_email(email)
    owner_email = normalize_email(scope.user.email)

    cond do
      tournament.user_id != scope.user.id ->
        {:error, :not_owner}

      # Gated, unlike `leave_tournament/2`, `accept_invitation/2` and
      # `decline_invitation/2` further down this module - see the comment
      # above `leave_tournament/2` for the full argument. The short version:
      # this changes the invitation LIST, and the tournament that list
      # belongs to is not here (see `PairingsEngine.Handoff`). An invite
      # minted on the copy left behind grants access to a frozen read-only
      # snapshot, not to the live event running on the other machine, so the
      # person invited never gets the access the owner meant to give them -
      # and once the tournament comes back, the live copy has no idea the
      # invite exists. `remove_collaborator/3` below is gated the same way,
      # for the mirror reason: revoking someone here would not actually
      # revoke anything on the machine that matters.
      (writable = ensure_writable(tournament)) != :ok ->
        writable

      email == "" ->
        {:error, :blank_email}

      email == owner_email ->
        {:error, :cannot_add_owner}

      Repo.exists?(
        from c in Collaborator, where: c.tournament_id == ^tournament.id and c.email == ^email
      ) ->
        {:error, :already_added}

      true ->
        user = Accounts.get_user_by_email(email)

        %Collaborator{tournament_id: tournament.id, user_id: user && user.id}
        |> Collaborator.changeset(%{
          email: email,
          status: "pending",
          invite_token: generate_invite_token()
        })
        |> Repo.insert()
        |> case do
          {:ok, collaborator} ->
            broadcast_tournament_change(tournament.id, :collaborators)
            if collaborator.user_id, do: broadcast_user_tournaments(collaborator.user_id)

            {:ok,
             %{
               collaborator
               | mail_status: deliver_invitation_email(scope.user, tournament, collaborator)
             }}

          error ->
            error
        end
    end
  end

  # Never lets a mailer exception (e.g. an SMTP hiccup) crash the caller -
  # the collaborator row above is already committed, so a failed send just
  # means the owner has to share the invite link manually.
  defp deliver_invitation_email(owner, tournament, collaborator) do
    PairingsEngine.Accounts.UserNotifier.deliver_invitation(
      collaborator.email,
      owner.email,
      tournament.name,
      invite_url(collaborator.invite_token)
    )

    :sent
  rescue
    _ -> :failed
  end

  defp invite_url(token), do: PairingsEngineWeb.Endpoint.url() <> "/invites/" <> token

  defp generate_invite_token,
    do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

  @doc """
  Removes a collaborator from `tournament` - whether still pending or
  already accepted. Owner-only - returns `{:error, :not_owner}` unless
  `scope.user` is the tournament's owner, and `{:error, :not_found}` if
  `collaborator_id` isn't one of this tournament's collaborators. For a
  pending row, this revokes the invitation outright.
  """
  def remove_collaborator(%Scope{} = scope, %Tournament{} = tournament, collaborator_id) do
    cond do
      tournament.user_id != scope.user.id ->
        {:error, :not_owner}

      # See the comment on the matching clause in `add_collaborator/3`: this
      # changes the invitation list, and the tournament it belongs to is not
      # here.
      (writable = ensure_writable(tournament)) != :ok ->
        writable

      true ->
        case Repo.get_by(Collaborator, id: collaborator_id, tournament_id: tournament.id) do
          nil ->
            {:error, :not_found}

          collaborator ->
            Repo.delete(collaborator)
            |> tap_ok(fn deleted ->
              broadcast_tournament_change(tournament.id, :collaborators)
              if deleted.user_id, do: broadcast_user_tournaments(deleted.user_id)
            end)
        end
    end
  end

  @doc """
  Lets a collaborator remove *themselves* from a shared tournament - the
  self-service counterpart to `remove_collaborator/3`, which is owner-only
  (an owner can't "leave" their own tournament; they delete it instead).

  Returns `{:error, :owner}` if `scope.user` owns `tournament`, or
  `{:error, :not_found}` if they have no (accepted or pending) collaborator
  row on it at all.

  Deliberately NOT behind `ensure_writable/1`, unlike `add_collaborator/3`
  and `remove_collaborator/3` above - and the same is true of
  `accept_invitation/2` and `decline_invitation/2` below. Those two change
  the invitation LIST: the roster the owner controls, which the live copy
  elsewhere never sees a checked-out edit to. This changes only the
  caller's OWN relationship to a collaborator row that already exists in
  THIS database, which needs nothing from the other machine to be correct -
  there is no roster for it to disagree with, only one person's yes or no.
  It is also no more consequential than the read access a handed-off
  tournament already grants everywhere else (`hand_off/2`'s doc: "the
  tournament stays fully readable"). Refusing it would trade a real
  improvement for a cosmetic one: someone declining, or leaving, or finally
  accepting an invitation to a tournament they may not open again for weeks
  is not a conflict with the copy that is actually live, it is a decision
  about their own inbox - and forcing them to carry a stale invite until an
  arbiter happens to take the tournament back is worse than just letting
  them act on it.
  """
  def leave_tournament(%Scope{} = scope, %Tournament{} = tournament) do
    cond do
      tournament.user_id == scope.user.id ->
        {:error, :owner}

      true ->
        case Repo.get_by(Collaborator, tournament_id: tournament.id, user_id: scope.user.id) do
          nil ->
            {:error, :not_found}

          collaborator ->
            Repo.delete(collaborator)
            |> tap_ok(fn _deleted ->
              broadcast_tournament_change(tournament.id, :collaborators)
              broadcast_user_tournaments(scope.user.id)
            end)
        end
    end
  end

  @doc """
  Lists the scope's user's pending invitations - collaborator rows with
  `status: "pending"` matched by `user_id` (already linked, see
  `link_pending_collaborators/1`) or by `email` (not yet linked). Returns
  `%{collaborator: Collaborator.t(), tournament: Tournament.t(), owner_email: String.t()}`
  maps, most recently invited first, for the "Pending invitations" section
  on the Tournaments page.
  """
  def list_pending_invitations(%Scope{} = scope) do
    user = scope.user
    email = normalize_email(user.email)

    Repo.all(
      from c in Collaborator,
        join: t in assoc(c, :tournament),
        join: owner in assoc(t, :user),
        where: c.status == "pending" and (c.user_id == ^user.id or c.email == ^email),
        order_by: [desc: c.inserted_at],
        select: %{collaborator: c, tournament: t, owner_email: owner.email}
    )
  end

  @doc """
  Accepts a pending invitation, identified by its `invite_token` or its
  `id` - see `find_invitation/1`. Requires the scope's user's email to
  match the invitation's email (case-insensitively); returns
  `{:error, :email_mismatch}` otherwise, so a logged-in user can't accept an
  invite that was sent to someone else. Returns `{:error, :not_found}` if
  the token/id doesn't match a pending row.

  On success, sets `status: "accepted"`, links `user_id` to the scope's
  user, and clears `invite_token` (it's single-use). Broadcasts on both the
  tournament's topic and the user's tournament-list topic so any open
  LiveView refreshes live.

  Deliberately NOT behind `ensure_writable/1` even when the tournament is
  handed off - see the comment on `leave_tournament/2` above for the full
  reasoning.
  """
  def accept_invitation(%Scope{} = scope, token_or_id) do
    with %Collaborator{status: "pending"} = collaborator <- find_invitation(token_or_id),
         true <- normalize_email(collaborator.email) == normalize_email(scope.user.email) do
      collaborator
      |> Collaborator.changeset(%{status: "accepted", user_id: scope.user.id, invite_token: nil})
      |> Repo.update()
      |> tap_ok(fn updated ->
        broadcast_tournament_change(updated.tournament_id, :collaborators)
        broadcast_user_tournaments(scope.user.id)
      end)
    else
      false -> {:error, :email_mismatch}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Declines a pending invitation, identified by its `invite_token` or its
  `id` - deletes the row outright. Requires the scope's user's email to
  match the invitation's email (case-insensitively), same as
  `accept_invitation/2`. Returns `{:error, :not_found}` or
  `{:error, :email_mismatch}`.

  Deliberately NOT behind `ensure_writable/1` even when the tournament is
  handed off - see the comment on `leave_tournament/2` above for the full
  reasoning.
  """
  def decline_invitation(%Scope{} = scope, token_or_id) do
    with %Collaborator{status: "pending"} = collaborator <- find_invitation(token_or_id),
         true <- normalize_email(collaborator.email) == normalize_email(scope.user.email) do
      tournament_id = collaborator.tournament_id

      Repo.delete(collaborator)
      |> tap_ok(fn _deleted ->
        broadcast_tournament_change(tournament_id, :collaborators)
        broadcast_user_tournaments(scope.user.id)
      end)
    else
      false -> {:error, :email_mismatch}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Finds a collaborator row by its `invite_token` (a URL-safe base64 string)
  or, as a fallback, its numeric `id`. Returns `nil` if neither matches.

  Only ever call this where the caller then proves the row is the current
  user's - `accept_invitation/2` and `decline_invitation/2` both check the
  logged-in email against the invitation's, which is what makes the `id`
  branch safe for the in-app accept/decline buttons (they carry a
  collaborator id, not a token). Anything that *renders* an invitation must
  use `find_invitation_by_token/1` instead: an id is guessable, so looking
  one up from a URL segment let any logged-in user walk `/invites/1`,
  `/invites/2`, ... and read every pending invitee's email address.
  """
  def find_invitation(token_or_id) do
    case Integer.parse(to_string(token_or_id)) do
      {id, ""} -> Repo.get(Collaborator, id)
      _ -> Repo.get_by(Collaborator, invite_token: token_or_id)
    end
  end

  @doc """
  Finds a collaborator row by its `invite_token` only - never by id, so a
  guessed URL segment can't reach someone else's invitation. Returns `nil`
  for a blank token, so an empty segment can't match rows whose token has
  been cleared (`accept_invitation/2` nils it out).
  """
  def find_invitation_by_token(token) when is_binary(token) and token != "" do
    Repo.get_by(Collaborator, invite_token: token)
  end

  def find_invitation_by_token(_token), do: nil

  @doc """
  Links any pending `tournament_collaborators` rows (invited by email before
  that person had an account) to `user`, by matching `email`. Call this on
  every login (see `PairingsEngineWeb.UserAuth.log_in_user/3`) so a
  freshly-registered invitee can find their invitation under `user_id` too,
  and so `list_pending_invitations/1` picks it up without needing an exact
  email match. This alone still grants **no access** - the invite stays
  `status: "pending"` until explicitly accepted. Idempotent - a no-op once
  every matching row is already linked.
  """
  def link_pending_collaborators(%User{} = user) do
    email = normalize_email(user.email)

    pending_query =
      from c in Collaborator, where: c.email == ^email and is_nil(c.user_id)

    tournament_ids = Repo.all(from c in pending_query, select: c.tournament_id)

    if tournament_ids != [] do
      Repo.update_all(pending_query, set: [user_id: user.id])

      Enum.each(tournament_ids, &broadcast_tournament_change(&1, :collaborators))
      broadcast_user_tournaments(user.id)
    end

    :ok
  end

  defp normalize_email(email), do: email |> to_string() |> String.trim() |> String.downcase()

  @doc """
  Creates an unowned tournament (no `user_id`).

  Kept for internal callers that don't have a scope (e.g. the SWAR
  importer). Prefer `create_tournament/2` from user-facing code so the
  tournament is owned by whoever created it.
  """
  def create_tournament(attrs) do
    type = attrs["type"] || attrs[:type] || "swiss"

    %Tournament{tiebreaks: Tiebreaks.fide_defaults(type)}
    |> Tournament.changeset(attrs)
    |> Repo.insert()
    |> tap_ok(fn tournament -> broadcast_user_tournaments(tournament.user_id) end)
  end

  @doc "Creates a tournament owned by the scope's user."
  def create_tournament(%Scope{} = scope, attrs) do
    type = attrs["type"] || attrs[:type] || "swiss"

    %Tournament{tiebreaks: Tiebreaks.fide_defaults(type), user_id: scope.user.id}
    |> Tournament.changeset(attrs)
    |> Repo.insert()
    |> tap_ok(fn tournament -> broadcast_user_tournaments(tournament.user_id) end)
  end

  def update_tournament(%Tournament{} = tournament, attrs) do
    with :ok <- ensure_writable(tournament),
         :ok <- ensure_unlocked(tournament, attrs) do
      tournament
      |> Tournament.changeset(attrs)
      |> Repo.update()
      |> tap_ok(fn updated ->
        broadcast_tournament_change(updated.id, :settings)
        broadcast_tournament_list(updated)
      end)
    end
  end

  ## ---------- settings frozen once the tournament is under way ----------
  #
  # Some settings decide the SHAPE of rounds that already exist, so changing
  # them afterwards silently reinterprets history: flipping `pairing_system`
  # from Swiss to Keizer changes how the rounds already on the board are
  # scored and paired; `rr_cycles` changes how long the schedule is supposed
  # to be; the "Pt ABSENT" trio rewrites what past absences were worth.
  #
  # These were previously enforced only by the Settings LiveViews (disabled
  # inputs plus a strip of the submitted params). That is not enforcement:
  # any other caller - another LiveView, a script, a future code path -
  # went straight through. Same lesson as the archive guard: the check has
  # to live where the write does.
  #
  # `Snapshots.restore/3` deliberately does NOT come through here (it writes
  # via `TournamentImport.restore_into!/2`), because restoring a snapshot
  # legitimately sets every field back at once, locks included.

  @doc """
  Which settings are currently frozen for `tournament`, as a list of field
  atoms. Empty before the first round is paired.

  The single source of truth for both the context guard in
  `update_tournament/2` and the Settings pages' disabled/locked rendering,
  so the two can't drift apart.
  """
  @spec locked_fields(Tournament.t()) :: [atom()]
  def locked_fields(%Tournament{} = tournament) do
    paired = PairingsEngine.Pairing.paired_rounds_count(tournament.id)

    if paired == 0 do
      []
    else
      # A round robin's cycle count only locks once the rounds already paired
      # reach what the current setting implies the schedule needs - before
      # that, switching single/double is still harmless (see
      # `RoundRobin.schedule/3`: round N is identical either way while N is
      # inside cycle 1).
      rr_implied_limit = max(count_players(tournament.id) - 1, 1) * tournament.rr_cycles

      # `pairing_engine` belongs here for the same reason `pairing_system`
      # does, one level down: JaVaFo and Ainalrami are two independent Dutch
      # implementations, and a round already on the board was decided by
      # whichever one was configured at the time. Swapping engines mid-event
      # hands the new one a history it did not produce, and every colour /
      # float / rematch judgement from then on is made against a bracket
      # shape the previous engine chose - the same "silently reinterprets
      # rounds that already exist" failure this whole list guards.
      base = ~w(pairing_system pairing_engine rr_match_format swiss_match_format
                pair_by_category abs_value abs_jusque abs_nbfois)a

      if paired >= rr_implied_limit, do: [:rr_cycles | base], else: base
    end
  end

  @doc """
  `:ok` unless `attrs` would actually *change* one of `locked_fields/1`.

  Compares against the current value rather than merely spotting the key, so
  a form that round-trips an unchanged locked field (the ordinary case - the
  input is disabled but still submitted) is not refused.
  """
  @spec ensure_unlocked(Tournament.t(), map()) :: :ok | {:error, :locked_after_pairing}
  def ensure_unlocked(%Tournament{} = tournament, attrs) when is_map(attrs) do
    locked = locked_fields(tournament)

    changed? =
      Enum.any?(locked, fn field ->
        case fetch_attr(attrs, field) do
          :error -> false
          {:ok, value} -> changes_value?(tournament, field, value)
        end
      end)

    if changed?, do: {:error, :locked_after_pairing}, else: :ok
  end

  defp fetch_attr(attrs, field) do
    case Map.fetch(attrs, Atom.to_string(field)) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, field)
    end
  end

  # Params arrive as strings from a form but as native types from a script,
  # so compare through the schema's own cast rather than by raw equality -
  # otherwise `"keizer"` vs `:keizer`, or `"2"` vs `2`, reads as a change
  # when it isn't (or worse, as no change when it is).
  defp changes_value?(tournament, field, value) do
    changeset = Tournament.changeset(tournament, %{Atom.to_string(field) => value})

    case Ecto.Changeset.fetch_change(changeset, field) do
      {:ok, _new} -> true
      :error -> false
    end
  end

  @doc """
  The hard delete, cascading to everything linked to the tournament. The
  owner reaches it through `purge_tournament/1`; nothing else should call it
  directly.

  Refuses `{:error, :handed_off}` for a tournament that is checked out to
  another copy of the app. Deleting is not a write to the tournament and is
  deliberately not behind `ensure_writable/1` - archiving one has never been
  a reason you cannot throw it away. Hand-off is different, and it is
  different for one concrete reason: the row carries `handoff_token`, which
  is the only thing `take_back/2` compares the returning payload against.
  Delete the row and the copy actually running the event has nowhere to come
  home to - not a lost tournament here, a stranded one there.
  """
  @spec delete_tournament(Tournament.t()) ::
          {:ok, Tournament.t()} | {:error, :handed_off | Ecto.Changeset.t()}
  def delete_tournament(%Tournament{} = tournament) do
    if handed_off?(tournament) do
      {:error, :handed_off}
    else
      Repo.delete(tournament)
      |> tap_ok(fn deleted ->
        broadcast_tournament_change(deleted.id, :tournament)
        broadcast_tournament_list(deleted)
      end)
    end
  end

  ## ---------- Logo (SWAR parity #14-16 - place cards) ----------
  #
  # Per-tournament print logo, stored as a DB blob (`tournaments.logo_data`
  # + `logo_content_type`) so backups/deploys carry it - no filesystem or
  # upload-dir question. Both fields are deliberately NOT cast by
  # `Tournament.changeset/2` (see that schema's comment), so an ordinary
  # settings-form save can never clobber the blob; these two functions are
  # the only writers.

  # A print logo has no business being larger than this - it's stored in
  # the DB and shipped in every JSON backup.
  @max_logo_bytes 2_000_000

  @doc """
  Sets `tournament`'s print logo (embedded as a base64 `data:` URI by
  `PairingsEngineWeb.PrintController` - see `docs/printing.md`) after
  verifying `binary` is actually one of the accepted raster image types, by
  its real file signature (magic bytes) - never by a filename extension or
  the browser-supplied content-type, both of which are attacker-controlled.
  SVG is deliberately never accepted, no matter how it's labelled: it's an
  XML document that can carry scripts, and this blob is rendered straight
  back into pages we serve, so raster-only removes that whole class of
  problem. See `detect_image_type/1` for the exact signatures checked and
  the size cap.

  Returns `{:error, :invalid_image}` (never touching the row) for anything
  that fails validation - the caller (`SettingsLive`) turns that into a
  friendly flash rather than ever storing unvalidated bytes.
  """
  @spec set_logo(Tournament.t(), binary()) ::
          {:ok, Tournament.t()} | {:error, :invalid_image} | {:error, Ecto.Changeset.t()}
  def set_logo(%Tournament{} = tournament, binary) when is_binary(binary) do
    with :ok <- ensure_writable(tournament) do
      do_set_logo(tournament, binary)
    end
  end

  defp do_set_logo(%Tournament{} = tournament, binary) do
    case detect_image_type(binary) do
      {:ok, content_type} ->
        tournament
        |> Ecto.Changeset.change(logo_data: binary, logo_content_type: content_type)
        |> Repo.update()
        |> tap_ok(fn updated -> broadcast_tournament_change(updated.id, :settings) end)

      :error ->
        {:error, :invalid_image}
    end
  end

  @doc "Removes `tournament`'s print logo. Broadcasts `:settings`, same as `set_logo/2`."
  @spec clear_logo(Tournament.t()) :: {:ok, Tournament.t()} | {:error, Ecto.Changeset.t()}
  def clear_logo(%Tournament{} = tournament) do
    with :ok <- ensure_writable(tournament) do
      tournament
      |> Ecto.Changeset.change(logo_data: nil, logo_content_type: nil)
      |> Repo.update()
      |> tap_ok(fn updated -> broadcast_tournament_change(updated.id, :settings) end)
    end
  end

  @doc """
  Turns publishing this tournament to OpenResults on or off.

  **The public switch.** Since the local `/p/:slug/...` pages were removed on
  2026-08-29 this is the only thing that makes a tournament readable by
  anybody without a login: the results site is where the public reads, so
  "published" and "public" are now one state rather than two.

  A controlled setter rather than a `changeset/2` field, for the same reason
  as `set_registration_open/2` and with a sharper edge - this decides whether
  a copy of the tournament, with its players' names, ratings and clubs, leaves
  the machine at all. An ordinary settings save must not be able to start
  that.

  Turning it ON enqueues an immediate publish, so the arbiter's next look at
  the public page shows the tournament rather than a 404 they have to wait
  out. Turning it OFF does not un-publish anything already sent: this app
  cannot reach into the server and withdraw a document, and pretending
  otherwise in a toggle label would be a lie. Removing a published
  tournament is a separate, deliberate act.
  """
  @spec set_publish_to_openresults(Tournament.t(), boolean()) ::
          {:ok, Tournament.t()} | {:error, Ecto.Changeset.t()} | {:error, atom()}
  def set_publish_to_openresults(%Tournament{} = tournament, enabled?)
      when is_boolean(enabled?) do
    with :ok <- ensure_writable(tournament) do
      tournament
      |> Ecto.Changeset.change(publish_to_openresults: enabled?)
      |> Repo.update()
      |> tap_ok(fn updated ->
        if enabled?, do: PairingsEngine.Publishing.enqueue(updated)
        broadcast_tournament_change(updated.id, :settings)
      end)
    end
  end

  @doc """
  Opens or closes public self-registration.

  The form itself lives on the results site, not here - so this flag only
  reaches anyone by riding along in the published snapshot, and it only means
  anything for a tournament that is actually published. Closing it is
  therefore not instant the way it was when this app served the form: the
  next publish carries the closure. `PairingsEngine.Publishing.enqueue/1` is
  called on the way out for exactly that reason.

  Deliberately a controlled setter rather than a `changeset/2` field, like
  `set_publish_to_openresults/2` and `rotate_public_slug/1`: it is the one
  flag that lets strangers write into an arbiter's tournament, so an ordinary
  settings save must not be able to open it by accident. Broadcasts
  `:settings`.
  """
  @spec set_registration_open(Tournament.t(), boolean()) ::
          {:ok, Tournament.t()} | {:error, Ecto.Changeset.t()}
  def set_registration_open(%Tournament{} = tournament, open?) when is_boolean(open?) do
    with :ok <- ensure_writable(tournament) do
      tournament
      |> Ecto.Changeset.change(registration_open: open?)
      |> Repo.update()
      |> tap_ok(fn updated ->
        # On BOTH edges, unlike `set_publish_to_openresults/2` above, which
        # only publishes when switching on. Closing a form is the urgent
        # direction here: an arbiter shuts entries at the door and the site
        # must stop taking them, whereas nothing bad happens if an opening
        # takes a moment to arrive. `enqueue/1` is a no-op for a tournament
        # that does not publish, so this costs unpublished ones nothing.
        PairingsEngine.Publishing.enqueue(updated)
        broadcast_tournament_change(updated.id, :settings)
      end)
    end
  end

  @doc """
  Shows or hides `tournament` in the results site's index.

  Enqueues a publish on both edges: this only reaches anybody by riding along
  in the snapshot, and an arbiter who has just unlisted an event expects it
  off the front page now rather than whenever the next result comes in.

  Not a security control, and the settings page is explicit about that. An
  unlisted tournament is still world-readable to anyone holding its address.
  """
  @spec set_public_listed(Tournament.t(), boolean()) ::
          {:ok, Tournament.t()} | {:error, Ecto.Changeset.t()}
  def set_public_listed(%Tournament{} = tournament, listed?) when is_boolean(listed?) do
    with :ok <- ensure_writable(tournament) do
      tournament
      |> Ecto.Changeset.change(public_listed: listed?)
      |> Repo.update()
      |> tap_ok(fn updated ->
        PairingsEngine.Publishing.enqueue(updated)
        broadcast_tournament_change(updated.id, :settings)
      end)
    end
  end

  @doc """
  Sets which columns the public page may show - see
  `PairingsEngine.PublicDisplay`.

  Takes the raw checkbox params and normalises them there rather than here,
  so the one place that knows the key list is the one place that validates
  against it.

  Enqueues a publish for the same reason as `set_public_listed/2`, and with
  more urgency: an arbiter unticking "Clubs" is taking something off a public
  page, and "it will go when the next result is entered" is not an answer.
  """
  @spec set_public_display(Tournament.t(), map(), map() | nil) ::
          {:ok, Tournament.t()} | {:error, Ecto.Changeset.t()} | {:error, :archived}
  def set_public_display(tournament, params, tiebreak_params \\ nil)

  def set_public_display(%Tournament{} = tournament, params, tiebreak_params)
      when is_map(params) do
    with :ok <- ensure_writable(tournament) do
      changes = [public_display: PairingsEngine.PublicDisplay.cast(params)]

      # `nil` means "this caller is not editing the tie-break list", which is
      # not the same as "hide none" - an older form, or a caller changing only
      # the ordinary toggles, must not silently unhide everything.
      changes =
        case tiebreak_params do
          nil ->
            changes

          ticked ->
            Keyword.put(changes, :public_hidden_tiebreaks, hidden_codes(tournament, ticked))
        end

      tournament
      |> Ecto.Changeset.change(changes)
      |> Repo.update()
      |> tap_ok(fn updated ->
        PairingsEngine.Publishing.enqueue(updated)
        broadcast_tournament_change(updated.id, :settings)
      end)
    end
  end

  # The form sends one param per TICKED box and omits the rest, so the hidden
  # set is the tournament's own codes minus what came back. Codes the
  # tournament no longer uses are dropped rather than remembered: a tie-break
  # that is put back later starts shown, which is the same
  # absent-means-shown rule everything else here follows.
  defp hidden_codes(%Tournament{} = tournament, ticked) when is_map(ticked) do
    Enum.reject(tournament.tiebreaks || [], &Map.has_key?(ticked, &1))
  end

  ## ---------- The public address ----------

  @doc """
  Rotates `tournament`'s `public_slug` to a fresh random token.

  The slug is this tournament's address on the results site, so rotating it
  moves the tournament to a new one. Deliberately outside `changeset/2`, so
  an ordinary settings save cannot move a published tournament by accident.

  **This alone does not revoke a leaked link.** A published tournament still
  has a copy at the OLD address, which this does not touch; rotating without
  removing that copy leaves the leaked link working and publishes a second
  copy alongside it. `PairingsEngine.Publishing.rotate_address/1` is the
  operation an arbiter actually wants, and it calls this in the middle.
  Broadcasts `:settings`.
  """
  @spec rotate_public_slug(Tournament.t()) ::
          {:ok, Tournament.t()} | {:error, Ecto.Changeset.t()}
  def rotate_public_slug(%Tournament{} = tournament) do
    with :ok <- ensure_writable(tournament) do
      tournament
      |> Ecto.Changeset.change(public_slug: Tournament.generate_public_slug())
      |> Repo.update()
      |> tap_ok(fn updated -> broadcast_tournament_change(updated.id, :settings) end)
    end
  end

  @doc """
  Sniffs `binary`'s real file-format signature and returns
  `{:ok, verified_content_type}` for one of the accepted raster types, or
  `:error` for anything else - including a well-formed SVG (never accepted,
  see `set_logo/2`) or anything over #{@max_logo_bytes} bytes.

  Signatures checked (first matching bytes win, order doesn't matter - the
  four are mutually exclusive):

    * PNG  - the 8-byte PNG signature `\\x89 P N G \\r \\n \\x1a \\n`
    * JPEG - the `\\xFF \\xD8 \\xFF` SOI marker
    * GIF  - `GIF87a` or `GIF89a`
    * WebP - a RIFF container carrying a `WEBP` fourcc (`RIFF????WEBP`)
  """
  @spec detect_image_type(binary()) :: {:ok, String.t()} | :error
  def detect_image_type(binary) when is_binary(binary) do
    if byte_size(binary) > @max_logo_bytes do
      :error
    else
      case binary do
        <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _rest::binary>> -> {:ok, "image/png"}
        <<0xFF, 0xD8, 0xFF, _rest::binary>> -> {:ok, "image/jpeg"}
        <<"GIF87a", _rest::binary>> -> {:ok, "image/gif"}
        <<"GIF89a", _rest::binary>> -> {:ok, "image/gif"}
        <<"RIFF", _size::binary-size(4), "WEBP", _rest::binary>> -> {:ok, "image/webp"}
        _ -> :error
      end
    end
  end

  def detect_image_type(_binary), do: :error

  @doc "The `data:` URI for `tournament`'s print logo, or `nil` if none is set."
  @spec logo_data_uri(Tournament.t()) :: String.t() | nil
  def logo_data_uri(%Tournament{logo_data: nil}), do: nil
  def logo_data_uri(%Tournament{logo_content_type: nil}), do: nil

  def logo_data_uri(%Tournament{logo_data: data, logo_content_type: content_type}) do
    "data:#{content_type};base64,#{Base.encode64(data)}"
  end

  ## ---------- Recycle bin (soft delete, 3-month retention) ----------
  #
  # Deleting a tournament from the Tournaments page no longer hard-deletes
  # it outright - it sets `deleted_at`, which every normal listing/fetch
  # path above (`list_tournaments/1`, `get_tournament!/1`,
  # `get_user_tournament!/2`,
  # `get_user_tournament/2`, `get_authorized_tournament!/2`,
  # `get_authorized_tournament/2`) now excludes, so a binned tournament's
  # own pages, public pages and exports all 404/disappear exactly as if it
  # had been hard-deleted. The row (and everything cascade-linked to it)
  # only actually goes away via `purge_tournament/1`, either picked by the
  # owner from the bin or swept up automatically by
  # `purge_expired_tournaments/0` once it's more than 90 days old.

  @recycle_bin_retention_days 90

  @doc """
  Moves `tournament` to the recycle bin - sets `deleted_at` to now (truncated
  to the second) instead of deleting the row. From this point on every
  normal fetch/listing path treats it as gone; `restore_tournament/1` undoes
  this, `purge_tournament/1` finishes the job for real. Broadcasts on the
  owner's tournament-list topic, same as `delete_tournament/1` did, so the
  Tournaments page refreshes live.

  Refuses `{:error, :handed_off}` for a tournament that is checked out to
  another copy of the app, for the same reason `delete_tournament/1` does.
  The bin looks reversible and mostly is, but it is a purge on a 90-day
  timer, and in the meantime every fetch and listing path treats the
  tournament as gone - so the copy running the event would find the way home
  closed long before the row actually went. Take it back first; then bin it
  if that is still what you want.
  """
  @spec soft_delete_tournament(Tournament.t()) ::
          {:ok, Tournament.t()} | {:error, :handed_off | Ecto.Changeset.t()}
  def soft_delete_tournament(%Tournament{} = tournament) do
    if handed_off?(tournament) do
      {:error, :handed_off}
    else
      tournament
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now() |> DateTime.truncate(:second))
      |> Repo.update()
      |> tap_ok(fn updated ->
        broadcast_tournament_change(updated.id, :tournament)
        broadcast_tournament_list(updated)
      end)
    end
  end

  @doc """
  Restores `tournament` out of the recycle bin - clears `deleted_at`, so it
  reappears everywhere `soft_delete_tournament/1` made it disappear from.
  Broadcasts the same as `soft_delete_tournament/1`.
  """
  def restore_tournament(%Tournament{} = tournament) do
    tournament
    |> Ecto.Changeset.change(deleted_at: nil)
    |> Repo.update()
    |> tap_ok(fn updated ->
      broadcast_tournament_change(updated.id, :tournament)
      broadcast_tournament_list(updated)
    end)
  end

  @doc """
  The real, irreversible hard delete - cascades exactly like
  `delete_tournament/1` (which this now backs), used both for the owner's
  "Delete permanently" action from the recycle bin and by
  `purge_expired_tournaments/0`'s automatic sweep.

  Inherits that function's `{:error, :handed_off}` refusal, which is the one
  that matters most here: this is the call that would actually destroy the
  `handoff_token` row the returning copy needs.
  """
  @spec purge_tournament(Tournament.t()) ::
          {:ok, Tournament.t()} | {:error, :handed_off | Ecto.Changeset.t()}
  def purge_tournament(%Tournament{} = tournament), do: delete_tournament(tournament)

  @doc """
  Lists the scope's user's own recycle-binned tournaments (`deleted_at` set),
  most recently deleted first - collaborator-shared tournaments never show
  up here, since only the owner can delete (and therefore restore/purge)
  one. Used by the "Recycle bin" panel on the Tournaments page.
  """
  def list_deleted_tournaments(%Scope{} = scope) do
    Repo.all(
      from t in Tournament,
        where: t.user_id == ^scope.user.id and not is_nil(t.deleted_at),
        order_by: [desc: t.deleted_at]
    )
  end

  @doc """
  Hard-deletes every tournament that's been in the recycle bin for more than
  #{@recycle_bin_retention_days} days. Meant to be called lazily (see
  `TournamentsLive`'s mount/handle_params) rather than on a schedule - cheap
  enough to run on every page load, and self-correcting if a deploy misses a
  few days. Returns the number of tournaments purged.

  Counts what was actually purged rather than what was found. A handed-off
  tournament refuses (`purge_tournament/1`), and it must: this sweep runs
  unattended on a page load, and eating that row would strand the copy
  running the event with nobody watching. It stays in the bin until it is
  taken back, and a stale count would have hidden that it had.
  """
  def purge_expired_tournaments do
    cutoff = DateTime.utc_now() |> DateTime.add(-@recycle_bin_retention_days, :day)

    Repo.all(from t in Tournament, where: not is_nil(t.deleted_at) and t.deleted_at < ^cutoff)
    |> Enum.count(&match?({:ok, _}, purge_tournament(&1)))
  end

  ## ---------- Archive (frozen read-only, kept forever) ----------
  #
  # Distinct from the recycle bin above in both intent and mechanics. The bin
  # is "on its way out" - hidden everywhere, auto-purged after 90 days.
  # Archiving is "done with this one, keep it forever, just stop anyone
  # changing it by accident": the tournament stays fully readable (its own
  # pages, its public pages, its exports and prints all keep working), it just
  # refuses every write until it's unarchived.
  #
  # The read-only part is enforced by `ensure_writable/1` at each write path
  # rather than by hiding the tournament, precisely because it must stay
  # viewable - a listing-level filter (the bin's mechanism) would be the wrong
  # tool.

  @doc """
  Archives `tournament` - sets `archived_at` to now (truncated to the
  second). From this point every write path refuses with `{:error, :archived}`
  until `unarchive_tournament/1` clears it; reads are entirely unaffected.
  Broadcasts on both the tournament topic and the owner's list topic so open
  pages flip to read-only live.

  Refuses `{:error, :handed_off}` for a tournament that is checked out to
  another copy of the app. Unlike binning and purging, this destroys nothing
  the returning payload needs - the refusal is about what the app would then
  be able to say. Three reasons, in order:

    * `hand_off/2` already refuses an archived tournament. Gating only that
      direction would make "archived and handed off" reachable by pressing
      two buttons in one order and unreachable in the other, which is a
      state nobody designed and everybody would have to reason about.
    * `ensure_writable/1` deliberately reports `:archived` first when a
      tournament is both. So every refusal in the app would tell the
      arbiter to unarchive - and once they had, every write would still be
      refused, this time for the reason they were never shown. One state,
      two truths, only one of them on screen.
    * Archiving means "this one is finished, nobody changes it again". A
      tournament that is handed off is being PLAYED somewhere else right
      now. Saying it is finished is a claim about a room this machine is
      not in.

  `unarchive_tournament/1` is deliberately not gated in return: rows
  predating this refusal can be both, and a state with no way out is worse
  than the state itself.
  """
  @spec archive_tournament(Tournament.t()) ::
          {:ok, Tournament.t()} | {:error, :handed_off | Ecto.Changeset.t()}
  def archive_tournament(%Tournament{} = tournament) do
    if handed_off?(tournament) do
      {:error, :handed_off}
    else
      tournament
      |> Ecto.Changeset.change(archived_at: DateTime.utc_now() |> DateTime.truncate(:second))
      |> Repo.update()
      |> tap_ok(fn updated ->
        broadcast_tournament_change(updated.id, :tournament)
        broadcast_tournament_list(updated)
      end)
    end
  end

  @doc """
  Unarchives `tournament` - clears `archived_at`, making it writable again.
  Broadcasts the same as `archive_tournament/1`.
  """
  @spec unarchive_tournament(Tournament.t()) ::
          {:ok, Tournament.t()} | {:error, Ecto.Changeset.t()}
  def unarchive_tournament(%Tournament{} = tournament) do
    tournament
    |> Ecto.Changeset.change(archived_at: nil)
    |> Repo.update()
    |> tap_ok(fn updated ->
      broadcast_tournament_change(updated.id, :tournament)
      broadcast_tournament_list(updated)
    end)
  end

  @doc "Whether `tournament` is currently archived (and therefore read-only)."
  @spec archived?(Tournament.t()) :: boolean()
  def archived?(%Tournament{archived_at: nil}), do: false
  def archived?(%Tournament{}), do: true

  @doc """
  Lists archived tournaments the scope's user owns or collaborates on, most
  recently archived first - the archived counterpart to `list_tournaments/1`,
  same shape: `{tournament, owner?}` tuples so the UI can show a "shared"
  badge and gate Delete (owner-only) vs Leave (collaborator-only) the same
  way the main table does. Unlike the recycle bin (`list_deleted_tournaments/1`,
  still owner-only - deleting is destructive and stays an owner-only call),
  archiving is a shared-tournament action collaborators can take too (see
  `archive_tournament/1`'s callers), so they need to be able to find the
  tournament again afterward.
  """
  @spec list_archived_tournaments(Scope.t()) :: [{Tournament.t(), boolean()}]
  def list_archived_tournaments(%Scope{} = scope) do
    user = scope.user

    Repo.all(
      from t in Tournament,
        where:
          not is_nil(t.archived_at) and is_nil(t.deleted_at) and
            (t.user_id == ^user.id or t.id in subquery(collaborator_tournament_ids(user))),
        select: {t, t.user_id == ^user.id},
        order_by: [desc: t.archived_at]
    )
  end

  ## ---------- Hand-off (live in exactly one place at a time) ----------
  #
  # An arbiter must be able to move a tournament between the hosted service
  # and a copy running on their own laptop - the venue's wifi dies, or the
  # event was set up centrally and is run from the floor. The ONLY safe model
  # for that is a hand-off with a lock, not a sync.
  #
  # Two copies that both accepted writes cannot be reconciled afterwards. One
  # machine recorded 1-0 on board 4 and the other a draw; both paired round 6
  # and produced different boards. No merge rule picks a winner, because the
  # disagreement is not about data, it is about what happened in a room. So
  # the tournament is live in exactly one place at a time, like a book
  # checked out of a library, and the copy left behind goes read-only.
  #
  # The read-only part costs one clause in `ensure_writable/1` below, which
  # every write path in the app already funnels through - the same mechanism
  # archiving uses, and the reason adding a second reason-to-refuse is a
  # one-line change rather than an audit of thirty call sites.
  #
  # The break-glass writes its own action code, and `PairingsEngine.Handoff`
  # reads it back: a returning file for a trip that was force-unlocked here
  # must be refused, because after a forced unlock this copy could diverge.
  @forced_unlock_action "tournament.handoff_forced"

  # `hand_off/2` and `take_back/2` are the only writers of the three columns;
  # none of them is in `Tournament.changeset/2`'s cast list, so no form,
  # import or snapshot restore can mint or clear a lock (see the fields'
  # comments in `PairingsEngine.Tournaments.Tournament`).

  @doc """
  Hands `tournament` over to another copy of the app, identified by the
  human label `to_label` ("this laptop", a hostname, a server address).

  Mints a fresh token, stamps `handed_off_at`, and from that moment every
  write path here refuses with `{:error, :handed_off}`. The tournament stays
  fully readable - it is the record of an event that is still running
  somewhere else, so viewing, printing and exporting must all keep working.

  Refuses `{:error, :already_handed_off}` for a tournament that is already
  checked out. That refusal is the lock: handing off twice would mint a
  second token and orphan the first, leaving the copy that actually holds
  the tournament unable to give it back. The check is made again inside the
  UPDATE's `WHERE`, so two callers racing cannot both win - a `cond` on a
  struct read a moment ago is a check, not a lock.

  Refuses `{:error, :archived}` for an archived tournament: archiving says
  "nobody changes this again", and handing it to a machine that would be
  allowed to is the opposite of that.

  Broadcasts on both the tournament topic and every affected user's list
  topic, same as `archive_tournament/1`, so open pages flip to read-only
  live rather than on the next reload.
  """
  @spec hand_off(Tournament.t(), String.t()) ::
          {:ok, Tournament.t()} | {:error, :already_handed_off | :archived}
  def hand_off(%Tournament{} = tournament, to_label) when is_binary(to_label) do
    cond do
      handed_off?(tournament) -> {:error, :already_handed_off}
      archived?(tournament) -> {:error, :archived}
      true -> claim_hand_off(tournament, String.trim(to_label))
    end
  end

  # Conditional UPDATE rather than `Ecto.Changeset.change/2` + `Repo.update/1`
  # (which is what `archive_tournament/1` uses): the `is_nil(handed_off_at)`
  # in the WHERE is what makes "hand off exactly once" true rather than
  # merely usually true. Archiving twice is idempotent and harmless; handing
  # off twice destroys the token the other copy is holding.
  #
  # `updated_at` is set by hand because `Repo.update_all/3` does not run the
  # schema's autogenerated timestamps, and a lifecycle write that left the
  # row's mtime behind would be a lie to everything that reads it.
  defp claim_hand_off(%Tournament{} = tournament, to_label) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    result =
      Repo.update_all(
        from(t in Tournament, where: t.id == ^tournament.id and is_nil(t.handed_off_at)),
        set: [
          handed_off_at: now,
          handed_off_to: to_label,
          handoff_token: generate_handoff_token(),
          updated_at: now
        ]
      )

    case result do
      {1, _} ->
        updated = Repo.reload!(tournament)
        broadcast_tournament_change(updated.id, :tournament)
        broadcast_tournament_list(updated)
        {:ok, updated}

      {0, _} ->
        {:error, :already_handed_off}
    end
  end

  @doc """
  Takes `tournament` back from wherever it was handed off to, clearing all
  three hand-off columns and making it writable here again.

  `token` must be the value `hand_off/2` minted, carried back by the
  returning payload; anything else is `{:error, :bad_token}`. Compared with
  `Plug.Crypto.secure_compare/2` - the same constant-time compare the deploy
  notice and the FIDE-lookup token use - because a token that can be
  discovered a byte at a time is not a lock.

  A tournament that is not handed off at all also answers `{:error,
  :bad_token}`: it holds no token, so there is no value that unlocks it, and
  saying so in one word beats inventing a second failure an arbiter would
  have to be taught to tell apart. The practical consequence worth knowing
  is that taking back is NOT idempotent - a second attempt with the same
  token fails, because the first one erased the thing it is compared against.
  """
  @spec take_back(Tournament.t(), String.t() | nil) ::
          {:ok, Tournament.t()} | {:error, :bad_token | Ecto.Changeset.t()}
  def take_back(%Tournament{} = tournament, token) do
    if handoff_token_matches?(tournament, token) do
      tournament
      |> Ecto.Changeset.change(handed_off_at: nil, handed_off_to: nil, handoff_token: nil)
      |> Repo.update()
      |> tap_ok(fn updated ->
        broadcast_tournament_change(updated.id, :tournament)
        broadcast_tournament_list(updated)
      end)
    else
      {:error, :bad_token}
    end
  end

  @doc """
  Break glass: clears the hand-off lock WITHOUT the token, on the owner's
  say-so.

  ## Why this has to exist

  `take_back/2` needs the token, and the token lives in exactly one place -
  the copy the tournament was handed to. That is the whole point of it, and
  it is fine until that copy is stolen, wiped, or dropped in a canal. With
  no way in, this copy is read-only forever: the round it is holding can
  never be paired and the event is finished as a working document. A lock
  whose failure mode is "the tournament cannot continue" has traded a
  recoverable problem for an unrecoverable one, which is the opposite of a
  safety feature.

  ## What it does not do

  It does not make divergence safe. The other copy still exists, still holds
  what it holds, and must never be opened again - once this returns, any
  work done over there is lost, and any work done over here after it is
  work the other copy does not have. Nothing can undo that; the honest goal
  is to make the choice DELIBERATE and to write down who made it. So the
  caller is expected to confirm in words first (see
  `PairingsEngineWeb.SettingsSupport.force_unlock_panel/1`, which is
  deliberately awkward to use), and this writes its own audit row either
  way.

  ## The rules

    * **Owner only.** A collaborator can archive, pair and enter results;
      abandoning a copy of a live event is not on that list. Refused with
      `{:error, :not_owner}`.
    * **Only on a tournament that is actually handed off.** Refused with
      `{:error, :not_handed_off}` otherwise - a button that silently
      succeeds on a live tournament invites being pressed to find out what
      it does, and this is the one button nobody should learn by pressing.
    * **The audit row and the unlock are one transaction.** Unusually for
      this codebase, the row is written HERE rather than at the LiveView
      call site (see `PairingsEngine.Audit`'s note on where writes come
      from). Two reasons, both specific to this function: the acting user
      is already an argument, because ownership has to be checked; and when
      two divergent copies surface months later, "which one was forced?" is
      answerable only from this row. A call site that forgot to log would
      leave a forced unlock indistinguishable from a clean take-back, so it
      is not left to a call site.

  The action code is `"tournament.handoff_forced"` (`forced_unlock_action/0`),
  deliberately distinct from whatever an ordinary take-back records. The token
  is NOT put in the details: it is dead by then, but a dead credential in a
  log an administrator reads on screen is still a credential in a log. What
  the row does carry is `handoff_token_digest/1` of it, under
  `"was_handoff_token"` - a one-way fingerprint, useless as a key, and the
  only thing that lets `PairingsEngine.Handoff.release/3` tell "this is the
  return for the very trip we broke open" from "this is some other trip".
  Without it that question can only be answered from the timestamp and the
  destination label, which are both second-resolution free text and can
  legitimately repeat.
  """
  @spec force_take_back(Tournament.t(), Scope.t()) ::
          {:ok, Tournament.t()} | {:error, :not_owner | :not_handed_off | Ecto.Changeset.t()}
  def force_take_back(%Tournament{} = tournament, %Scope{} = actor) do
    cond do
      not owner?(tournament, actor) -> {:error, :not_owner}
      not handed_off?(tournament) -> {:error, :not_handed_off}
      true -> do_force_take_back(tournament, actor)
    end
  end

  defp do_force_take_back(%Tournament{} = tournament, %Scope{} = actor) do
    Repo.transaction(fn ->
      with {:ok, unlocked} <-
             tournament
             |> Ecto.Changeset.change(
               handed_off_at: nil,
               handed_off_to: nil,
               handoff_token: nil
             )
             |> Repo.update(),
           {:ok, _row} <-
             Audit.log(tournament.id, actor, @forced_unlock_action, %{
               name: tournament.name,
               was_handed_off_to: tournament.handed_off_to,
               was_handed_off_at: tournament.handed_off_at,
               was_handoff_token: handoff_token_digest(tournament.handoff_token)
             }) do
        unlocked
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> tap_ok(fn unlocked ->
      broadcast_tournament_change(unlocked.id, :tournament)
      broadcast_tournament_list(unlocked)
    end)
  end

  @doc """
  The audit action `force_take_back/2` writes, so the one module that has to
  recognise a forced unlock (`PairingsEngine.Handoff`) does not carry its own
  copy of the string.
  """
  @spec forced_unlock_action() :: String.t()
  def forced_unlock_action, do: @forced_unlock_action

  @doc """
  A one-way fingerprint of a hand-off token, short enough to sit in an audit
  row a person reads.

  Not a credential and not reversible: it identifies WHICH hand-off a row or a
  file belongs to, and unlocks nothing. Truncated because 64 bits is already
  far more than "these two are the same trip" needs, and a full digest in a
  log is noise somebody has to scroll past.

  Returns nil for a tournament that holds no token, so a caller can compare
  nils away rather than crashing on one.
  """
  @spec handoff_token_digest(String.t() | nil) :: String.t() | nil
  def handoff_token_digest(token) when is_binary(token) and token != "" do
    :sha256
    |> :crypto.hash(token)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  def handoff_token_digest(_token), do: nil

  @doc "Whether `tournament` is currently handed off (and therefore read-only here)."
  @spec handed_off?(Tournament.t()) :: boolean()
  def handed_off?(%Tournament{handed_off_at: nil}), do: false
  def handed_off?(%Tournament{}), do: true

  # Only a tournament that is actually handed off has a token to match, so a
  # live one (both columns nil) falls through to `false` rather than reaching
  # `secure_compare/2`, which raises on a nil argument.
  defp handoff_token_matches?(%Tournament{handed_off_at: nil}, _presented), do: false

  defp handoff_token_matches?(%Tournament{handoff_token: stored}, presented)
       when is_binary(stored) and is_binary(presented) do
    Plug.Crypto.secure_compare(stored, presented)
  end

  defp handoff_token_matches?(%Tournament{}, _presented), do: false

  # 32 bytes from the CSPRNG, url-safe so it survives a JSON envelope, a
  # query string and a copy-paste into a terminal unmangled. Same shape as
  # `PairingsEngine.Publishing.generate_key/0` and `Tournament.generate_public_slug/0`.
  defp generate_handoff_token,
    do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  @doc """
  The write gate: `:ok` when `tournament` may be written to, `{:error,
  :archived}` when it's archived, `{:error, :handed_off}` when it is checked
  out to another copy of the app.

  Called at the top of every state-changing function in this module (and by
  `PairingsEngine.Pairing`), rather than relying on the UI to hide buttons -
  a stale open tab, a queued LiveView event, or a direct context call from
  a script must all be refused too.

  Two different reasons, one gate. That is the point: the hand-off lock is
  one clause here rather than a second guard threaded through thirty write
  paths, and a write path that is safe against archiving is automatically
  safe against a hand-off.

  Archiving is reported first when a tournament is somehow both. It is the
  more permanent of the two states and the one whose remedy an arbiter
  controls locally; a tournament that is handed off AND archived would
  otherwise tell them to go and fetch it back, only to refuse the write
  anyway.

  Accepts a `%Tournament{}`, a tournament id, or (for the write paths that
  only hold a child row) `nil`, which is treated as writable since there is
  no tournament to check - callers that can resolve one should.
  """
  @spec ensure_writable(Tournament.t() | integer() | nil) ::
          :ok | {:error, :archived | :handed_off}
  def ensure_writable(nil), do: :ok
  def ensure_writable(%Tournament{archived_at: nil, handed_off_at: nil}), do: :ok
  def ensure_writable(%Tournament{archived_at: nil}), do: {:error, :handed_off}
  def ensure_writable(%Tournament{}), do: {:error, :archived}

  def ensure_writable(tournament_id) when is_integer(tournament_id) do
    Repo.one(
      from t in Tournament,
        where: t.id == ^tournament_id,
        select: {t.archived_at, t.handed_off_at}
    )
    |> case do
      # No such tournament: nothing to protect. Distinct from `{nil, nil}`,
      # which is a real row that is simply live - the previous single-column
      # version of this query could not tell the two apart, and did not need
      # to since both answer `:ok`.
      nil -> :ok
      {nil, nil} -> :ok
      {nil, _handed_off_at} -> {:error, :handed_off}
      _ -> {:error, :archived}
    end
  end

  @doc """
  `ensure_writable/1`'s refusal as a truthy value, or `false` when the write
  may go ahead.

  For the `cond`-shaped guards in this module, which - unlike `with :ok <-
  ensure_writable(...)` - cannot bind the reason they matched on. Nine of
  them answered a hardcoded `{:error, :archived}` no matter what the gate
  actually said, which was true while archiving was the only way to lose
  write access and became a lie the moment hand-off was a second one. Telling
  an arbiter to unarchive a tournament that is not archived sends them to a
  button that does nothing.

  Used as `cond do refusal = write_refused(id) -> refusal; ...` - the
  binding is visible in the clause body, and keeps the gate the first branch,
  which is the shape the 2026-08-26 sweep asked every write path to have.

  The call sites that answer with a plain string rather than an atom (the
  pairing entry points) use `ensure_writable/1` with `refusal_message/2`
  instead.
  """
  @spec write_refused(Tournament.t() | integer() | nil) ::
          false | {:error, :archived | :handed_off}
  def write_refused(target) do
    case ensure_writable(target) do
      :ok -> false
      {:error, _reason} = refusal -> refusal
    end
  end

  @doc """
  The plain-English refusal for a write path that answers with a string
  rather than an atom - the pairing entry points, whose `{:error, message}`
  the UI renders as-is. `action` completes "…before %{action}.", e.g.
  `"pairing"` or `"unpairing"`.
  """
  @spec refusal_message(:archived | :handed_off, String.t()) :: String.t()
  def refusal_message(:archived, action),
    do: "This tournament is archived - unarchive it before #{action}."

  def refusal_message(:handed_off, action),
    do: "This tournament has been handed off - take it back before #{action}."

  def change_tournament(%Tournament{} = tournament, attrs \\ %{}) do
    Tournament.changeset(tournament, attrs)
  end

  @doc """
  Freezes `PairingDisplay`'s board labels/classification for every pairing
  in `round_id`, using each player's `fixed_board` value AS OF RIGHT NOW.

  Call this exactly once, right after a round's pairings are inserted -
  ordinary pairing, round-robin, Keizer, or an import/restore - and never
  again for that round afterward. This is what stops a later edit to a
  player's `fixed_board` (e.g. on the Players page) from retroactively
  renumbering an already-paired round's boards while people are already
  seated: `PairingDisplay.with_display_boards/1` and `board_labels/1` only
  ever read the columns this writes, never `Player.fixed_board` directly.
  See `PairingsEngine.PairingDisplay`'s moduledoc for the full rationale.
  """
  @spec freeze_round_display_boards!(integer()) :: :ok
  def freeze_round_display_boards!(round_id) do
    pairings =
      Repo.all(
        from p in Pairing,
          where: p.round_id == ^round_id,
          preload: [:white_player, :black_player]
      )

    labels = PairingDisplay.compute_labels(pairings)

    Enum.each(pairings, fn pairing ->
      %{display_board: display_board, display_special: display_special} =
        Map.fetch!(labels, pairing.id)

      Repo.update_all(
        from(p in Pairing, where: p.id == ^pairing.id),
        set: [display_board: display_board, display_special: display_special]
      )
    end)

    :ok
  end

  @doc """
  Freezes the label for ONE pairing just inserted into an
  already-frozen round, leaving every other row in that round untouched.

  For `pair_from_pool/4`, the one path that adds a board to a round that
  was paired earlier. It deliberately does NOT call
  `freeze_round_display_boards!/1`: that recomputes every label in the
  round from each player's `fixed_board` as it stands right now, and this
  round has already been printed and sat down at. Re-freezing it would
  renumber boards under people mid-round - the exact retroactive
  renumbering `PairingsEngine.PairingDisplay`'s moduledoc exists to
  forbid, and a mid-round pin on the Players page is enough to trigger
  it. Leaving the row unfrozen (what happened before) is not an option
  either: `PairingDisplay.fallback_label/1` then prints its REAL board
  number, which is a different numbering space from the round's frozen
  labels, so the sheet gains a visible gap - or, if the arbiter types a
  free board number from low in the range, a duplicate nobody signed off
  on.

  So the new row gets one label, computed to fit what the round already
  shows: a pinned player's own fixed-table label if either side has one
  (from `compute_labels/1`, still the only reader of `fixed_board`), and
  otherwise one past the highest ordinary label already frozen in the
  round - continuing the printed sequence rather than recomputing it.
  """
  @spec freeze_new_pairing_display_board!(Pairing.t()) :: :ok
  def freeze_new_pairing_display_board!(%Pairing{} = pairing) do
    # Handed just this one pairing, `compute_labels/1` answers the two
    # questions that ARE decidable in isolation - is this a special board,
    # and what does a special board here get called. The ordinary NUMBER it
    # returns for a non-special row is meaningless from one pairing (it is
    # always "1", the row being alone in the list), and is replaced below.
    %{display_board: label, display_special: special?} =
      [pairing]
      |> Repo.preload([:white_player, :black_player])
      |> PairingDisplay.compute_labels()
      |> Map.fetch!(pairing.id)

    label = if special?, do: label, else: next_ordinary_display_board(pairing)

    Repo.update_all(
      from(p in Pairing, where: p.id == ^pairing.id),
      set: [display_board: label, display_special: special?]
    )

    :ok
  end

  # One past the highest ordinary label frozen in this pairing's round.
  # Reads the frozen `display_board` column, never the real `board` numbers:
  # the two are different numbering spaces the moment the round holds a
  # fixed-table board, and it is the printed sequence this has to continue.
  #
  # Special labels are skipped - "1001", or the slash-joined "5/6" of a board
  # where two fixed-table players meet, do not order like ordinary numbers -
  # and so is any label that doesn't parse as a plain integer. A round with
  # no ordinary frozen label at all (one that predates the freeze entirely,
  # every `display_board` still nil) falls back to this pairing's own real
  # board number, which is exactly what `PairingDisplay` prints for every
  # other row in such a round.
  defp next_ordinary_display_board(%Pairing{} = pairing) do
    highest =
      Repo.all(
        from p in Pairing,
          where:
            p.round_id == ^pairing.round_id and p.id != ^pairing.id and
              p.display_special == false and not is_nil(p.display_board),
          select: p.display_board
      )
      |> Enum.map(&ordinary_label_number/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> nil end)

    if highest, do: Integer.to_string(highest + 1), else: Integer.to_string(pairing.board)
  end

  defp ordinary_label_number(label) when is_binary(label) do
    case Integer.parse(label) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp ordinary_label_number(_), do: nil

  # Runs `fun` (for its broadcast side effect) when the write succeeded,
  # then passes the `{:ok, _} | {:error, _}` result through unchanged. Never
  # broadcasts on a failed changeset.
  defp tap_ok({:ok, value} = result, fun) do
    fun.(value)
    result
  end

  defp tap_ok(error, _fun), do: error

  ## Players

  def list_players(tournament_id) do
    Repo.all(
      from p in Player,
        where: p.tournament_id == ^tournament_id,
        order_by: [
          desc:
            fragment(
              "CASE WHEN ? > 0 THEN ? ELSE ? END",
              p.fide_rating,
              p.fide_rating,
              p.national_rating
            ),
          asc: p.name
        ]
    )
  end

  def count_players(tournament_id) do
    Repo.aggregate(from(p in Player, where: p.tournament_id == ^tournament_id), :count)
  end

  @doc """
  Fetches a player by id, but only within `tournament_id`.

  Deliberately takes the tournament rather than offering a bare `get_player!(id)`:
  a player id reaches us in an event payload, long after
  `get_authorized_tournament!/2` gated the mount, so it is attacker-controlled
  and authorising the tournament proves nothing about the row. Raises
  `Ecto.NoResultsError` for a player in some other arbiter's tournament, exactly
  as it does for one that doesn't exist - a caller cannot tell the difference,
  and cannot act on the row either way.
  """
  def get_player!(tournament_id, id),
    do: Repo.get_by!(Player, id: id, tournament_id: tournament_id)

  @doc """
  Like `get_player!/2` but returns `nil` instead of raising when the player
  doesn't exist in this tournament - and, unlike the bang version, tolerates
  a non-integer `id` string (a stale or crafted client value) by treating it
  as "not found" rather than letting an `Ecto.Query.CastError` crash the
  caller. Use this in LiveView event handlers, which receive `id` straight
  from the client.
  """
  def get_player(tournament_id, id) do
    case normalize_id(id) do
      nil -> nil
      int_id -> Repo.get_by(Player, id: int_id, tournament_id: tournament_id)
    end
  end

  defp normalize_id(id) when is_integer(id), do: id

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp normalize_id(_), do: nil

  def create_player(tournament_id, attrs) do
    # Through `normalize_id/1`, which is defined directly above and was not
    # being used here. `Player.fide_id` is an `:integer` column, so pinning
    # the raw form value into the query made Ecto cast it - and anything that
    # does not parse cleanly (letters, a dash, a pasted value with a stray
    # space) raised `Ecto.Query.CastError` from the planner before
    # `Player.changeset/2` could return the ordinary "is invalid" error.
    #
    # The reachable path is the arbiter's own add-player form, not an import.
    # A value that is not an integer cannot match an integer column, so the
    # right answer is "no duplicate" and let the changeset reject it.
    fide_id = normalize_id(attrs["fide_id"] || attrs[:fide_id])

    # The range bound matters here as much as the parse: a 40-digit string
    # parses cleanly to an integer and then blows up inside the driver
    # (`Exqlite.Error: argument error`) when it is pinned into SQL. A number
    # the column cannot hold cannot be a duplicate of anything in it, so skip
    # the check and let `Player.changeset/2` return the ordinary error.
    storable? = is_integer(fide_id) and fide_id > 0 and fide_id <= Player.max_fide_id()

    duplicate? =
      storable? and
        Repo.exists?(
          from p in Player,
            where: p.tournament_id == ^tournament_id and p.fide_id == ^fide_id
        )

    cond do
      refusal = write_refused(tournament_id) ->
        refusal

      duplicate? ->
        {:error, :duplicate_fide_id}

      true ->
        %Player{tournament_id: tournament_id}
        |> Player.changeset(attrs)
        |> Repo.insert()
        |> tap_ok(fn player -> broadcast_tournament_change(player.tournament_id, :players) end)
    end
  end

  def update_player(%Player{} = player, attrs) do
    with :ok <- ensure_writable(player.tournament_id) do
      player
      |> Player.changeset(attrs)
      |> guard_pairing_number_freeze(player)
      |> Repo.update()
      |> tap_ok(fn updated -> broadcast_tournament_change(updated.tournament_id, :players) end)
    end
  end

  # FIDE C.04.2.B.3: a player's pairing number (TPN) may be adjusted while
  # the "List of Participants" is still effectively open (late entries,
  # early data-entry corrections), but "no modification of a TPN ... is
  # allowed after the fourth round has been paired" - every already-played
  # round's opponent references are keyed on that number, so reshuffling it
  # later silently corrupts what "round 2, board 5" actually meant.
  #
  # Only guards an *existing* number being changed to a different one -
  # `Pairing.ensure_pairing_numbers/2` assigning a fresh number to a player
  # who never had one (nil -> N, e.g. a late entry joining after round 4)
  # is unaffected, exactly as FIDE's own rule allows.
  defp guard_pairing_number_freeze(changeset, %Player{pairing_number: current})
       when not is_nil(current) do
    case Ecto.Changeset.get_change(changeset, :pairing_number) do
      nil ->
        changeset

      ^current ->
        changeset

      _new ->
        if PairingsEngine.Pairing.paired_rounds_count(changeset.data.tournament_id) >= 4 do
          Ecto.Changeset.add_error(
            changeset,
            :pairing_number,
            "cannot be changed after round 4 has been paired (FIDE C.04.2.B.3)"
          )
        else
          changeset
        end
    end
  end

  defp guard_pairing_number_freeze(changeset, %Player{}), do: changeset

  def delete_player(%Player{} = player) do
    with :ok <- ensure_writable(player.tournament_id) do
      Repo.delete(player)
      |> tap_ok(fn deleted -> broadcast_tournament_change(deleted.tournament_id, :players) end)
    end
  end

  @doc """
  Applies `updates` (a list of `{%Player{}, attrs}` pairs) in a single
  transaction and fires exactly one `tournament_changed` broadcast on
  success - used by `PairingsEngine.RatingRefresh.apply/2` so a bulk rating
  refresh doesn't flood open LiveViews with one broadcast per player.
  Rolls back (returning `{:error, changeset}`) if any single update fails
  validation.
  """
  def bulk_update_players(tournament_id, updates) do
    with :ok <- ensure_writable(tournament_id) do
      result =
        Repo.transaction(fn ->
          Enum.map(updates, fn {player, attrs} ->
            case player |> Player.changeset(attrs) |> Repo.update() do
              {:ok, updated} -> updated
              {:error, changeset} -> Repo.rollback(changeset)
            end
          end)
        end)

      case result do
        {:ok, _players} = ok ->
          broadcast_tournament_change(tournament_id, :players)
          ok

        error ->
          error
      end
    end
  end

  @doc """
  Sets the whole-tournament `absent` flag on every player in `tournament_id`
  to `absent?` - the "All Absent" / "All Present" right-click action on the
  Players grid's Pr. column header.

  Deliberately touches ONLY that one boolean. `absent_rounds` (the
  per-round SWAR notation, see `PairingsEngineWeb.PlayersLive`'s `cell/2`
  "pr" clause) is left exactly as each player had it - this is the
  generally-present/generally-absent switch, not a bulk edit of who is
  out for which specific round. One transaction, one broadcast, via
  `bulk_update_players/2`.
  """
  def set_all_players_absent(tournament_id, absent?) when is_boolean(absent?) do
    players = list_players(tournament_id)
    updates = for p <- players, do: {p, %{"absent" => absent?}}
    bulk_update_players(tournament_id, updates)
  end

  @doc """
  Sets the registration-fee status on every player in `tournament_id` - the
  "All ..." right-click action on the Players grid's Paid column header, the
  same shape as `set_all_players_absent/2` above.

  `status` is one of `"nopaid"`, `"paid"`, `"gratis"` (SWAR §5.20); anything
  else returns `{:error, :invalid_paid_status}` rather than reaching the
  changeset, so a malformed client event cannot half-apply across the
  roster. One transaction, one broadcast, via `bulk_update_players/2`.
  """
  def set_all_players_paid(tournament_id, status) when status in ~w(nopaid paid gratis) do
    players = list_players(tournament_id)
    updates = for p <- players, do: {p, %{"paid" => status}}
    bulk_update_players(tournament_id, updates)
  end

  def set_all_players_paid(_tournament_id, _status), do: {:error, :invalid_paid_status}

  def change_player(%Player{} = player, attrs \\ %{}), do: Player.changeset(player, attrs)

  @doc """
  Applies `tournament.extra_points_bands` (SWAR parity #12 Elo-band
  auto-assign - see `PairingsEngine.Tournaments.Tournament.band_extra_points/2`
  and `docs/extra-points.md`) to every player in the tournament, **overwriting**
  each player's `extra_points` - a player matching no band is set back to
  `0.0`, not left alone, so re-running after a rating change (or a bands
  edit) always reflects the current rule rather than layering on top of a
  stale prior run. A single transaction, one `tournament_changed` broadcast
  (via `bulk_update_players/2`), same pattern as `PairingsEngine.RatingRefresh.apply/2`.

  Returns `{:ok, %{matched: n, total: m}}` - `matched` counts players whose
  rating fell under at least one band (bonus > 0.0), `total` every player in
  the tournament - for the "Set extra points for N of M players" summary on
  the Settings page. Returns `{:error, :invalid_bands}` if
  `extra_points_bands` doesn't parse (shouldn't happen for a value that went
  through `Tournament.changeset/2`, but this function doesn't assume that).
  """
  @spec apply_extra_points_bands(Tournament.t()) ::
          {:ok, %{matched: non_neg_integer(), total: non_neg_integer()}} | {:error, term()}
  def apply_extra_points_bands(%Tournament{} = tournament) do
    case Tournament.parse_extra_points_bands(tournament.extra_points_bands) do
      {:ok, bands} ->
        players = list_players(tournament.id)

        updates =
          Enum.map(players, fn player ->
            extra = Tournament.band_extra_points(bands, Player.rating(player))
            {player, %{extra_points: extra}}
          end)

        matched = Enum.count(updates, fn {_player, attrs} -> attrs.extra_points > 0.0 end)

        case bulk_update_players(tournament.id, updates) do
          {:ok, _updated} -> {:ok, %{matched: matched, total: length(players)}}
          error -> error
        end

      :error ->
        {:error, :invalid_bands}
    end
  end

  @doc """
  Applies `tournament.category_rules` to every player, **overwriting**
  each player's `category` - same shape as `apply_extra_points_bands/1`.
  Unconditional: a player who matches no rule is set back to `""`, not
  left alone, so re-running after a rating update (or a rule edit) always
  reflects the current rules rather than a stale prior run - and, as a
  direct consequence, running this DOES clear any category the arbiter
  set by hand that doesn't happen to also be a ruled category's match.
  Only meant for tournaments where category is fully rule-driven; a mix
  of ruled and hand-picked categories doesn't survive a re-run.

  Reuses `preview_auto_assign_categories/1` for the actual assignment
  decisions - this function's only job beyond that is turning the preview
  into writes, so the preview shown to the arbiter and what actually gets
  written can never drift apart. One transaction, one broadcast
  (`bulk_update_players/2`). Returns `{:ok, %{matched: n, total: m}}` -
  `matched` counts players who landed in a RULED category (not `""`) - for
  the same "Assigned N of M players" summary `ExtraPointsLive` shows for its
  own bulk rule application.
  """
  @spec auto_assign_categories(Tournament.t()) ::
          {:ok, %{matched: non_neg_integer(), total: non_neg_integer()}} | {:error, term()}
  def auto_assign_categories(%Tournament{} = tournament) do
    changes = preview_auto_assign_categories(tournament)

    updates =
      Enum.map(changes, fn %{player: player, to: category} -> {player, %{category: category}} end)

    matched = Enum.count(changes, fn %{to: category} -> category != "" end)

    case bulk_update_players(tournament.id, updates) do
      {:ok, _updated} -> {:ok, %{matched: matched, total: length(changes)}}
      error -> error
    end
  end

  @doc """
  Computes what `auto_assign_categories/1` WOULD do to every player,
  without writing anything - the single source of truth for "what does the
  rule decide" that both the dry-run preview and the real write path share,
  so they can never drift apart. Read-only: does not check `ensure_writable/1`
  itself, since previewing an archived tournament is harmless (only the
  eventual apply is blocked, by `bulk_update_players/2` inside
  `auto_assign_categories/1`).

  Returns one entry per player, in `list_players/1` order:
  `%{player: player, from: player.category, to: rule_decision}`. A player
  whose `from == to` is not filtered out here - callers that only want the
  players who'd actually change (e.g. the confirm-modal diff) should filter
  on that themselves; callers that want the full roster (e.g. computing
  `matched`/`total`) get it as-is.
  """
  @spec preview_auto_assign_categories(Tournament.t()) :: [
          %{player: Player.t(), from: String.t(), to: String.t()}
        ]
  def preview_auto_assign_categories(%Tournament{} = tournament) do
    tournament.id
    |> list_players()
    |> Enum.map(fn player ->
      category =
        PlayerStats.assign_category(player, tournament.categories, tournament.category_rules)

      %{player: player, from: player.category || "", to: category}
    end)
  end

  ## ---------- Manual standings override (SWAR parity #23) ----------
  #
  # See docs/manual-standings.md for the full write-up: seeding, the
  # staleness mechanism, and why Keizer tournaments don't offer this. Short
  # version: `tournament.manual_ranking` lets the arbiter hand-order the
  # standings display via `players.manual_rank` - always a plain positive
  # `1..N` value (or `nil` for a never-placed player), never sign-encoded.
  # Staleness lives on `tournaments.manual_ranking_stale` (one row, set by
  # `invalidate_manual_ranking/1` below and read back by
  # `PairingsEngine.Standings.manual_ranking_stale?/1`). This never touches
  # points/tiebreaks, only which `:rank` gets displayed
  # (`PairingsEngine.Standings.apply_manual_ranking/2`). Nothing here
  # special-cases Keizer - the only caller of these functions
  # (`StandingsLive`) simply never shows the controls when
  # `pairing_system == "keizer"`.

  @doc """
  Turns manual ranking on for `tournament` and seeds every player's
  `manual_rank` from the current computed standings order (SWAR parity #23
  requirement: seed from the real standings, not an empty/arbitrary list).
  Safe to call even when manual ranking is already on - always reseeds
  fresh, same effect as `reseed_manual_ranking/1` (kept as a separate name
  because the call site reads better either way: "turn it on" vs. "fix it
  up").
  """
  def enable_manual_ranking(%Tournament{} = tournament) do
    with {:ok, tournament} <- set_manual_ranking_flag(tournament, true) do
      reseed_manual_ranking(tournament)
    end
  end

  @doc """
  Turns manual ranking off. Leaves every player's `manual_rank` value in
  place (harmless while off - nothing reads it) so switching back on later
  starts from a familiar state before `enable_manual_ranking/1` reseeds it
  fresh, rather than needing to be rebuilt from scratch.
  """
  def disable_manual_ranking(%Tournament{} = tournament),
    do: set_manual_ranking_flag(tournament, false)

  defp set_manual_ranking_flag(tournament, value) do
    with :ok <- ensure_writable(tournament) do
      do_set_manual_ranking_flag(tournament, value)
    end
  end

  defp do_set_manual_ranking_flag(tournament, value) do
    tournament
    |> Ecto.Changeset.change(manual_ranking: value)
    |> Repo.update()
    |> tap_ok(fn updated -> broadcast_tournament_change(updated.id, :settings) end)
  end

  @doc """
  Re-seeds `tournament`'s manual order from the current computed standings
  (`PairingsEngine.Standings.standings/1`) - every player's `manual_rank`
  is set to their current tiebreak rank (a plain positive `1..N` value),
  and `tournaments.manual_ranking_stale` is cleared. This is both how
  `enable_manual_ranking/1` seeds the first time and the arbiter's explicit
  "re-seed from current order" action once the banner reports the hand-set
  order is stale (SWAR parity #23 requirement 5) or incomplete (a player
  joined after the mode was switched on and was never placed).
  """
  def reseed_manual_ranking(%Tournament{} = tournament) do
    with :ok <- ensure_writable(tournament) do
      do_reseed_manual_ranking(tournament)
    end
  end

  defp do_reseed_manual_ranking(%Tournament{} = tournament) do
    Repo.transaction(fn ->
      tournament
      |> Standings.standings()
      |> Enum.each(fn e ->
        Repo.update_all(from(p in Player, where: p.id == ^e.player.id),
          set: [manual_rank: e.rank]
        )
      end)

      Repo.update_all(from(t in Tournament, where: t.id == ^tournament.id),
        set: [manual_ranking_stale: false]
      )
    end)

    broadcast_tournament_change(tournament.id, :players)
    {:ok, %{tournament | manual_ranking_stale: false}}
  end

  @doc """
  Moves `player` one position up or down (`direction :up | :down`) in
  `tournament`'s manual order. Returns `{:error, :edge}` at the top of
  "up" or the bottom of "down", `{:error, :not_found}` if `player` has no
  current position at all (shouldn't happen once seeded, but the roster
  can move while manual ranking is off).

  An explicit reorder also confirms the whole list is fresh - even from a
  stale (or partially-unseeded) state, moving a player renumbers every
  player 1..N from the *current* display order and clears
  `tournaments.manual_ranking_stale`. The arbiter looking at the list and
  acting on it is exactly the confirmation the stale flag exists to prompt
  for; see docs/manual-standings.md.
  """
  def move_manual_rank(%Tournament{} = tournament, %Player{} = player, direction)
      when direction in [:up, :down] do
    ordered = manual_rank_ordered_players(tournament.id)
    idx = Enum.find_index(ordered, &(&1.id == player.id))

    swap_idx = if idx, do: if(direction == :up, do: idx - 1, else: idx + 1)

    cond do
      refusal = write_refused(tournament) ->
        refusal

      idx == nil ->
        {:error, :not_found}

      swap_idx < 0 or swap_idx >= length(ordered) ->
        {:error, :edge}

      true ->
        reordered =
          ordered |> List.delete_at(idx) |> List.insert_at(swap_idx, Enum.at(ordered, idx))

        write_manual_ranks(tournament.id, reordered)
        broadcast_tournament_change(tournament.id, :players)
        {:ok, tournament}
    end
  end

  # Current manual order, nulls (never-seeded players) last - the same
  # "rank, nil-last" ordering `PairingsEngine.Standings.apply_manual_ranking/2`
  # displays, computed here directly off `manual_rank` since we need the
  # actual `%Player{}` structs to write back, not just display entries.
  # `manual_rank` is always a plain positive `1..N` value (or `nil`) - no
  # sign smuggling, see the moduledoc above.
  defp manual_rank_ordered_players(tournament_id) do
    tournament_id
    |> list_players()
    |> Enum.sort_by(fn p -> if p.manual_rank, do: {0, p.manual_rank}, else: {1, p.name} end)
  end

  defp write_manual_ranks(tournament_id, ordered_players) do
    Repo.transaction(fn ->
      ordered_players
      |> Enum.with_index(1)
      |> Enum.each(fn {p, rank} ->
        Repo.update_all(from(pl in Player, where: pl.id == ^p.id), set: [manual_rank: rank])
      end)

      Repo.update_all(from(t in Tournament, where: t.id == ^tournament_id),
        set: [manual_ranking_stale: false]
      )
    end)
  end

  @doc """
  SWAR parity #23 requirement 5: a result (or bye - see
  `PairingsEngine.Pairing`) changing invalidates a previously hand-set
  manual order without discarding it. Sets `tournaments.manual_ranking_stale`
  to `true` in a single one-row update - the hand-set `players.manual_rank`
  values are left completely untouched, so the order itself survives
  intact; only the "is this still trustworthy" flag changes. This is
  exactly the bit `PairingsEngine.Standings.manual_ranking_stale?/1` reads.
  Idempotent - setting an already-true flag is a no-op write, just like
  the sign-flip approach it replaced was WHERE-clause idempotent.
  See docs/manual-standings.md.

  Gated on `manual_ranking` so a tournament that never uses this feature
  (or has switched it off) never pays for the extra write on every
  result/bye write, and so a since-disabled tournament's flag doesn't get
  needlessly marked stale - irrelevant anyway since
  `enable_manual_ranking/1` always reseeds fresh (and clears staleness).

  Public (not just called from this module's own `update_pairing_result/2`)
  because `PairingsEngine.Pairing` - the pairing engine, which is where
  byes are written - needs the same hook. Both call sites are required to
  invalidate **before** broadcasting `:tournament_changed` on the
  tournament's topic: a subscriber (StandingsLive, PublicStandingsLive,
  ...) reacts to that broadcast by immediately re-reading the DB, so
  committing this write first means every reload the broadcast triggers
  already observes the stale flag - never a race where a subscriber
  renders one look-fresh frame before the flag lands.
  """
  def invalidate_manual_ranking(tournament_id) do
    if Repo.exists?(from t in Tournament, where: t.id == ^tournament_id and t.manual_ranking) do
      Repo.update_all(from(t in Tournament, where: t.id == ^tournament_id),
        set: [manual_ranking_stale: true]
      )
    end

    :ok
  end

  ## Teams

  def list_teams(tournament_id) do
    Repo.all(from t in Team, where: t.tournament_id == ^tournament_id, order_by: t.name)
  end

  ## Forbidden pairings (arbiter-configured "never pair these two" - see
  ## docs/forbidden-pairings.md). A tournament-configuration write like
  ## `update_tournament/2` above: any authorized user (owner or accepted
  ## collaborator, per `get_authorized_tournament!/2`) may manage these, not
  ## just the owner - there's no separate ownership check here, same as the
  ## general Settings form.

  @doc """
  Lists `tournament`'s forbidden pairings, most recently added first, with
  both players preloaded as `:player_a` / `:player_b` so the UI can render
  "Name A - Name B" without a second query per row.
  """
  def list_forbidden_pairings(tournament_id) do
    Repo.all(
      from f in ForbiddenPairing,
        where: f.tournament_id == ^tournament_id,
        order_by: [desc: f.id],
        preload: [:player_a, :player_b]
    )
  end

  @doc """
  Forbids `player_a_id` and `player_b_id` from ever being paired against
  each other in `tournament`. Returns `{:error, reason}` without writing
  anything for any of these:

    * `:same_player` - `player_a_id == player_b_id`
    * `:invalid_player` - either id doesn't belong to `tournament`
    * `:already_forbidden` - the pair is already forbidden, in either order
      (`{a, b}` and `{b, a}` are the same pair)

  Otherwise inserts the row and broadcasts `:settings` on the tournament's
  topic (same hint `update_tournament/2` uses - both are tournament
  configuration, so the Settings page reload path is identical).
  """
  def add_forbidden_pairing(%Tournament{} = tournament, player_a_id, player_b_id) do
    cond do
      refusal = write_refused(tournament) ->
        refusal

      player_a_id == player_b_id ->
        {:error, :same_player}

      not both_players_belong_to_tournament?(tournament.id, player_a_id, player_b_id) ->
        {:error, :invalid_player}

      pair_already_forbidden?(tournament.id, player_a_id, player_b_id) ->
        {:error, :already_forbidden}

      true ->
        %ForbiddenPairing{}
        |> ForbiddenPairing.changeset(%{
          tournament_id: tournament.id,
          player_a_id: player_a_id,
          player_b_id: player_b_id
        })
        |> Repo.insert()
        |> tap_ok(fn inserted ->
          broadcast_tournament_change(inserted.tournament_id, :settings)
        end)
    end
  end

  # One player's half of `both_players_belong_to_tournament?/3`. Same reason
  # it exists: an id from an event payload is attacker-controlled, and
  # authorising the tournament at mount proves nothing about the row.
  defp player_belongs_to_tournament?(tournament_id, player_id) do
    Repo.exists?(
      from p in Player, where: p.id == ^player_id and p.tournament_id == ^tournament_id
    )
  end

  defp both_players_belong_to_tournament?(tournament_id, player_a_id, player_b_id) do
    ids = Enum.uniq([player_a_id, player_b_id])

    count =
      Repo.aggregate(
        from(p in Player, where: p.tournament_id == ^tournament_id and p.id in ^ids),
        :count
      )

    count == length(ids)
  end

  defp pair_already_forbidden?(tournament_id, player_a_id, player_b_id) do
    Repo.exists?(
      from f in ForbiddenPairing,
        where:
          f.tournament_id == ^tournament_id and
            ((f.player_a_id == ^player_a_id and f.player_b_id == ^player_b_id) or
               (f.player_a_id == ^player_b_id and f.player_b_id == ^player_a_id))
    )
  end

  @doc """
  Removes forbidden pairing `id` from `tournament`. Returns
  `{:error, :not_found}` if `id` doesn't identify a forbidden pairing row
  belonging to `tournament` (so a stale/forged id from another tournament's
  page can't reach across).
  """
  def remove_forbidden_pairing(%Tournament{} = tournament, id) do
    with :ok <- ensure_writable(tournament) do
      do_remove_forbidden_pairing(tournament, id)
    end
  end

  defp do_remove_forbidden_pairing(%Tournament{} = tournament, id) do
    case Repo.get_by(ForbiddenPairing, id: id, tournament_id: tournament.id) do
      nil ->
        {:error, :not_found}

      forbidden_pairing ->
        Repo.delete(forbidden_pairing)
        |> tap_ok(fn deleted -> broadcast_tournament_change(deleted.tournament_id, :settings) end)
    end
  end

  ## Rounds & pairings (round lifecycle is filled in by the pairing engine)

  def get_round(tournament_id, number) do
    Repo.one(
      from r in Round,
        where: r.tournament_id == ^tournament_id and r.number == ^number,
        preload: [pairings: [:white_player, :black_player]]
    )
  end

  ## ---------- Public pairings publish delay ----------
  #
  # How long after pairing a round reaches the public, controlled by the
  # tournament's `publish_mode`. Per-round, and on TOP of
  # `publish_to_openresults` - that switch decides whether the tournament is
  # public at all, this decides when each round joins it.

  @doc """
  What `round.published_at` should be set to at the moment a round is
  paired, given `tournament.publish_mode` - called once, by every
  pairing-engine call site that inserts a `%Round{}`
  (`PairingsEngine.Pairing`/`RoundRobin`/`Keizer`), never recomputed
  afterward. `nil` means "not published" (only reachable under "manual",
  since the other three modes always resolve to a concrete instant).

  - `"immediate"` - `now`. Also what `round_published?/2` treats EVERY
    round as regardless of this value (see that function's own comment),
    so the exact instant doesn't actually matter for visibility here -
    computed anyway for a truthful `published_at` if anything ever reads
    it directly.
  - `"manual"` - `nil`. Stays that way until `publish_round_now/1`.
  - `"timed"` - `now + publish_delay_minutes`.
  - `"scheduled"` - midnight UTC on that round's own date from
    `tournament.round_dates` (1-indexed by `round_number`). Falls back to
    `now` when that date is missing/blank/unparseable - pairing must
    never silently produce a round that can never become visible because
    nobody filled in a date.
  """
  @spec compute_published_at(Tournament.t(), pos_integer()) :: DateTime.t() | nil
  def compute_published_at(%Tournament{} = tournament, round_number) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case tournament.publish_mode do
      "manual" ->
        nil

      "timed" ->
        DateTime.add(now, (tournament.publish_delay_minutes || 0) * 60, :second)

      "scheduled" ->
        with date_str when is_binary(date_str) and date_str != "" <-
               Enum.at(tournament.round_dates || [], round_number - 1),
             {:ok, date} <- Date.from_iso8601(date_str) do
          DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
        else
          _ -> now
        end

      _ ->
        now
    end
  end

  @doc """
  Whether `round` is currently visible on the public pairings page.

  "immediate" mode ignores `round.published_at` entirely and always
  returns `true` - deliberately, not an oversight: it's both today's
  actual behaviour (a round has always been public the instant it
  exists) AND what makes this feature safe to ship with no backfill.
  `rounds.published_at` was added with no data migration, so every round
  paired before this feature existed has `published_at: nil`; without
  this special case they'd all retroactively vanish from public pages
  the moment this shipped. Every OTHER mode is a real timestamp
  comparison - a round from "manual"/"timed"/"scheduled" is public once
  `published_at` exists and isn't in the future.
  """
  @spec round_published?(Tournament.t(), Round.t()) :: boolean()
  def round_published?(%Tournament{publish_mode: "immediate"}, %Round{}), do: true

  def round_published?(%Tournament{}, %Round{published_at: nil}), do: false

  def round_published?(%Tournament{}, %Round{published_at: at}) do
    DateTime.compare(at, DateTime.utc_now()) != :gt
  end

  @doc """
  The highest round `n` such that rounds 1..n are ALL published.

  The bound every public surface computes standings through, and the reason
  it is the contiguous prefix rather than the highest published number: with
  round 3 published and round 2 held back, standings through 3 would carry
  round 2's results anyway, and withholding a round would withhold only its
  pairings while its results leaked out of the table beside them.

  One definition, used by both public surfaces. `PairingsEngine.Snapshot`
  had this privately first, which meant OpenResults enforced the gate and
  the page served from this app did not - the two publics disagreeing about
  what "not published yet" means.
  """
  @spec published_through_round(Tournament.t()) :: non_neg_integer()
  def published_through_round(%Tournament{} = tournament) do
    published =
      tournament.id
      |> list_rounds()
      |> Enum.filter(&round_published?(tournament, &1))
      |> MapSet.new(& &1.number)

    contiguous_from(published, 0)
  end

  defp contiguous_from(published, n) do
    if MapSet.member?(published, n + 1), do: contiguous_from(published, n + 1), else: n
  end

  @doc """
  Makes `round` visible right now, regardless of `publish_mode` - the
  manual override available in every mode, not just "manual" (a
  "scheduled" or "timed" round can always be published early by hand;
  nothing about picking an automatic mode should mean you're stuck
  waiting on it). Broadcasts `:settings` so the public page (subscribed
  to the same topic) refreshes live the moment this lands, not on its
  own next poll.
  """
  @spec publish_round_now(Round.t()) :: {:ok, Round.t()} | {:error, Ecto.Changeset.t()}
  def publish_round_now(%Round{} = round) do
    with :ok <- ensure_writable(round.tournament_id) do
      round
      |> Round.changeset(%{published_at: DateTime.utc_now() |> DateTime.truncate(:second)})
      |> Repo.update()
      |> tap_ok(fn updated -> broadcast_tournament_change(updated.tournament_id, :settings) end)
    end
  end

  @doc """
  Hides `round` from the public pairings page again - clears
  `published_at` back to `nil`. Available regardless of mode, same
  reasoning as `publish_round_now/1`'s own doc: an arbiter who published
  something by mistake (or too early) needs a way back, not just a way
  forward. A no-op in "immediate" mode as far as the public page is
  concerned (`round_published?/2` never looks at `published_at` there),
  which is intentional, not a bug to work around - "immediate" means
  "always public", full stop; hiding a round is only meaningful once
  you've opted into one of the other three modes.
  """
  @spec unpublish_round(Round.t()) :: {:ok, Round.t()} | {:error, Ecto.Changeset.t()}
  def unpublish_round(%Round{} = round) do
    with :ok <- ensure_writable(round.tournament_id) do
      round
      |> Round.changeset(%{published_at: nil})
      |> Repo.update()
      |> tap_ok(fn updated -> broadcast_tournament_change(updated.tournament_id, :settings) end)
    end
  end

  @doc """
  The highest round NUMBER currently visible on the public pairings
  page - `PublicPairingsLive`'s equivalent of
  `PairingsEngine.Pairing.paired_rounds_count/1`, which only knows about
  PAIRED rounds, not published ones. `0` when nothing is public yet
  (including "nothing paired at all", same as `paired_rounds_count/1`).
  """
  @spec latest_published_round_number(Tournament.t()) :: non_neg_integer()
  def latest_published_round_number(%Tournament{publish_mode: "immediate"} = tournament) do
    PairingsEngine.Pairing.paired_rounds_count(tournament.id)
  end

  def latest_published_round_number(%Tournament{} = tournament) do
    now = DateTime.utc_now()

    Repo.one(
      from r in Round,
        where:
          r.tournament_id == ^tournament.id and not is_nil(r.published_at) and
            r.published_at <= ^now,
        select: max(r.number)
    ) || 0
  end

  @doc """
  Byes-table rows (`"requested-half"` / `"requested-zero"` / `"absent"` -
  see `PairingsEngine.Standings.add_bye_records/3` for the exact scoring
  rule per type) for `tournament_id` in round `number`, each with its
  `%Player{}` preloaded as `:player`.

  These are DIFFERENT from a pairing-allocated bye (a real `Pairing` row
  with `black_player_id: nil, result: "bye"`, already visible via
  `get_round/2`'s `round.pairings`) - a byes-table row never appears in
  `round.pairings`, so callers that only render `round.pairings` (as
  PairingsLive/LiveRoundLive/PublicPairingsLive all did before this
  function existed) silently drop every SWAR-imported or round-specific
  absentee bye from the pairings list.
  """
  def list_byes_for_round(tournament_id, number) do
    from(b in "byes",
      join: p in Player,
      on: p.id == b.player_id,
      where: b.tournament_id == ^tournament_id and b.round == ^number,
      select: %{player_id: b.player_id, round: b.round, type: b.type, player: p}
    )
    |> Repo.all()
  end

  def list_rounds(tournament_id) do
    Repo.all(from r in Round, where: r.tournament_id == ^tournament_id, order_by: r.number)
  end

  def update_pairing_result(%Pairing{} = pairing, result) do
    with :ok <- ensure_writable(round_tournament_id(pairing.round_id)) do
      do_update_pairing_result(pairing, result)
    end
  end

  defp do_update_pairing_result(%Pairing{} = pairing, result) do
    # Wrapped because this is the write an arbiter makes most often, under the
    # most time pressure, and it is the one that must never fail quietly. A
    # locked database raises rather than returning {:error, _}, which would
    # crash the LiveView and show a generic "something went wrong" - see
    # PairingsEngine.BusyWrite.
    BusyWrite.run(fn ->
      pairing
      |> Pairing.changeset(%{result: result})
      |> Repo.update()
    end)
    |> tap_ok(fn updated ->
      tournament_id = round_tournament_id(updated.round_id)
      # Invalidate *before* broadcasting: a subscriber (StandingsLive,
      # PublicStandingsLive, ...) reacts to `broadcast_tournament_change/2`
      # by immediately re-reading the DB. If the `manual_ranking_stale`
      # write happened after the broadcast, a subscriber's reload could
      # race it and render the old (fresh-looking) manual order for one
      # frame, with nothing left to trigger a second re-render once the
      # flag actually commits - exactly the "silently serving stale as
      # fresh" failure this feature exists to prevent. Committing the flag
      # first means every reload triggered by this write already sees it.
      invalidate_manual_ranking(tournament_id)
      broadcast_tournament_change(tournament_id, :results)
      refresh_status!(tournament_id)
    end)
  end

  defp round_tournament_id(round_id) do
    Repo.one(from r in Round, where: r.id == ^round_id, select: r.tournament_id)
  end

  @doc """
  Swaps two players' SEATS in `round` - the SWAR "swap players" move.
  Whatever slot each player currently occupies (board, colour, opponent
  or bye), the two trade: the slot itself - its board number and which
  colour sits there - never moves, only WHO fills it does. Everyone else
  in the round is untouched.

      round has  1. A-B   2. C-D
      swap(A, D) gives  1. D-B   2. C-A

  Passing a player's own opponent swaps only that one board's colours -
  the same operation, since both players are already in the same
  pairing's two seats.

  Allowed against a bye (`black_player_id: nil`) - the player swapped IN
  simply inherits the bye, the one swapped OUT inherits whatever seat the
  other player came from. A recorded RESULT is cleared on any row the
  swap touches, because a game's result describes what THOSE TWO PLAYERS
  did, and after the swap it no longer describes what's shown; the "bye"
  marker is the one exception, since a bye is a scoring rule for an empty
  seat, not a fact about who fills it, so it doesn't need clearing.

  Returns `{:error, :not_in_round}` if either player has no seat in this
  round, `{:error, :same_player}` for swapping a player with themselves,
  or whatever `Ecto.Changeset` validation error the underlying update
  hits.
  """
  def swap_players_in_round(%Round{} = round, player_a_id, player_b_id) do
    cond do
      refusal = write_refused(round.tournament_id) ->
        refusal

      player_a_id == player_b_id ->
        {:error, :same_player}

      true ->
        with {:ok, seat_a} <- find_player_seat(round.pairings, player_a_id),
             {:ok, seat_b} <- find_player_seat(round.pairings, player_b_id) do
          do_swap_seats(round.tournament_id, seat_a, player_b_id, seat_b, player_a_id)
        end
    end
  end

  defp find_player_seat(pairings, player_id) do
    Enum.find_value(pairings, {:error, :not_in_round}, fn pairing ->
      cond do
        pairing.white_player_id == player_id -> {:ok, {pairing, :white_player_id}}
        pairing.black_player_id == player_id -> {:ok, {pairing, :black_player_id}}
        true -> nil
      end
    end)
  end

  defp do_swap_seats(
         tournament_id,
         {pairing, field_a},
         new_a_occupant,
         {pairing, field_b},
         new_b_occupant
       ) do
    # Same row on both sides - A and B are already each other's opponent,
    # so this is a plain colour swap: one update, both fields at once.
    attrs = clear_stale_result(%{field_a => new_a_occupant, field_b => new_b_occupant}, pairing)
    update_result = pairing |> Pairing.changeset(attrs) |> Repo.update()
    finish_swap(tournament_id, update_result)
  end

  defp do_swap_seats(
         tournament_id,
         {pairing_a, field_a},
         new_a_occupant,
         {pairing_b, field_b},
         new_b_occupant
       ) do
    result =
      Repo.transaction(fn ->
        with {:ok, updated_a} <-
               pairing_a
               |> Pairing.changeset(clear_stale_result(%{field_a => new_a_occupant}, pairing_a))
               |> Repo.update(),
             {:ok, updated_b} <-
               pairing_b
               |> Pairing.changeset(clear_stale_result(%{field_b => new_b_occupant}, pairing_b))
               |> Repo.update() do
          {updated_a, updated_b}
        else
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)

    finish_swap(tournament_id, result)
  end

  # A bye's "result" is a scoring rule for the empty seat, not a claim
  # about who's IN it, so it survives a swap untouched. Any other
  # non-blank result describes a specific game between the two players
  # who WERE there and is cleared - see the moduledoc on
  # `swap_players_in_round/3`.
  defp clear_stale_result(attrs, %Pairing{result: r}) when r not in ["", "bye"],
    do: Map.put(attrs, :result, "")

  defp clear_stale_result(attrs, %Pairing{}), do: attrs

  defp finish_swap(tournament_id, {:ok, updated}) do
    invalidate_manual_ranking(tournament_id)
    broadcast_tournament_change(tournament_id, :results)
    refresh_status!(tournament_id)
    {:ok, updated}
  end

  defp finish_swap(_tournament_id, {:error, _reason} = error), do: error

  # Same invalidate + broadcast + status refresh as `finish_swap/2`, with
  # the arguments the other way round so it can sit at the end of a pipe.
  defp finish_round_write(result, tournament_id), do: finish_swap(tournament_id, result)

  ## ---------- Vacancies: absent-on-the-board, and the round's pool ----------
  #
  # An arbiter who learns at board 4 that someone hasn't turned up doesn't
  # want the round re-paired - they want THAT seat emptied and, if
  # possible, refilled from whoever is sitting the round out. So a seat can
  # be VACANT: `white_player_id`/`black_player_id` is `nil` while
  # `result` is `""`.
  #
  # That shape is deliberately the one the rest of the codebase already
  # copes with, rather than a new flag:
  #
  #   * `Standings.pairing_records/3` returns `[]` for `result: ""`, so a
  #     vacant board contributes nothing to anyone's score - true, since
  #     no game has happened and the arbiter hasn't yet said what should
  #     happen instead.
  #   * `Pairing.round_complete?/2` looks for exactly `result == ""`, so a
  #     vacant board blocks the next round from being paired until the
  #     arbiter resolves it. That's the safety net: a vacancy can't be
  #     silently forgotten.
  #   * TRF export's `bye_safe_result/2` already normalises a row with no
  #     opponent into a legal bye code.
  #
  # A vacancy is resolved exactly two ways - `fill_seat/4` (someone takes
  # the seat) or `award_bye_for_vacancy/2` (the player left behind gets a
  # bye). Both land on shapes with well-defined FIDE scoring; neither
  # invents a "forfeit against nobody", which is the one combination the
  # tiebreak code has no rule for (see `Standings.dummy_score/3`'s note).

  @doc """
  Everyone in `tournament_id` who is NOT sitting at a board in round
  `number` - the round's pool. `type` is the `"byes"`-table type when
  they have a row there (`"requested-half"`, `"requested-zero"`,
  `"absent"`), or `nil` for a player who is simply unpaired.

  Each entry carries `player_id` and `round` alongside the preloaded
  `player`, so an entry IS a `"byes"`-table row as far as
  `Standings.bye_points_for_row/2` is concerned - the pool panel can ask
  it what a given absence scores without a second, parallel notion of
  what byes are worth. `absent?` reports the player's tournament-wide
  `absent` flag, which is separate from any per-round `"byes"` row and is
  why a listed player may carry no `type` at all.

  This is what the Pairings page's "Not playing this round" panel lists,
  and the set a vacant seat can be filled from.
  """
  def list_round_pool(tournament_id, number) do
    seated =
      from(p in Pairing,
        join: r in Round,
        on: p.round_id == r.id,
        where: r.tournament_id == ^tournament_id and r.number == ^number,
        select: [p.white_player_id, p.black_player_id]
      )
      |> Repo.all()
      |> List.flatten()
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    bye_types =
      from(b in "byes",
        where: b.tournament_id == ^tournament_id and b.round == ^number,
        select: {b.player_id, b.type}
      )
      |> Repo.all()
      |> Map.new()

    # The pool exists so the arbiter can put someone back IN, which
    # decides who belongs in it. `absent` is the SOFT flag - "told us
    # they can't make it" - and someone turning up anyway is the
    # commonest reason to reach for a swap at all, so they have to be
    # listed. This function used to borrow
    # `PairingsEngine.Pairing.active_players/1`, whose job is "who may the
    # engine pair automatically" and which therefore drops `absent`; that
    # made precisely the players worth swapping with invisible.
    #
    # `forfeit` and a non-active status are the HARD ones and stay out.
    # Those are withdrawals from the event, and reversing one is a
    # deliberate edit on the Players page, not a round-level substitution.
    from(p in Player,
      where: p.tournament_id == ^tournament_id and p.status == "active" and p.forfeit == false
    )
    |> Repo.all()
    |> Enum.reject(&MapSet.member?(seated, &1.id))
    |> Enum.map(
      &%{
        player: &1,
        player_id: &1.id,
        round: number,
        type: Map.get(bye_types, &1.id),
        absent?: &1.absent
      }
    )
  end

  @doc """
  Empties the seat `player_id` occupies in `round`, leaving the board, its
  number and the opponent exactly where they are, and files the player as
  `"absent"` for the round so they score the tournament's absence value
  (`Standings.bye_points/4`) and show up in `list_round_pool/2`.

  Any result already on that board is cleared: it described a game between
  two specific players, and one of them is no longer there.
  """
  def vacate_seat(%Round{} = round, player_id, type \\ "absent") do
    with :ok <- ensure_writable(round.tournament_id) do
      do_vacate_seat(round, player_id, type)
    end
  end

  defp do_vacate_seat(%Round{} = round, player_id, type) do
    case find_player_seat(round.pairings, player_id) do
      {:error, reason} ->
        {:error, reason}

      {:ok, {pairing, field}} ->
        Repo.transaction(fn ->
          {:ok, updated} =
            pairing
            |> Pairing.changeset(%{field => nil, :result => ""})
            |> Repo.update()

          Repo.insert_all(
            "byes",
            [
              %{
                tournament_id: round.tournament_id,
                player_id: player_id,
                round: round.number,
                type: type
              }
            ],
            on_conflict: :nothing
          )

          updated
        end)
        |> finish_round_write(round.tournament_id)
    end
  end

  @doc """
  Seats `player_id` (someone from `list_round_pool/2`) in the vacant side
  of `pairing`, and drops their `"byes"` row for the round - they're
  playing after all, so the absence that put them in the pool no longer
  applies.

  Returns `{:error, :seat_taken}` if neither side of the board is vacant.
  """
  def fill_seat(%Round{} = round, %Pairing{} = pairing, player_id) do
    field =
      cond do
        is_nil(pairing.white_player_id) -> :white_player_id
        is_nil(pairing.black_player_id) -> :black_player_id
        true -> nil
      end

    cond do
      # `ensure_writable/1` is documented as being called at the top of every
      # state-changing function in this module, and three of the vacancy
      # family were missed - this one, `award_bye_for_vacancy/2` and
      # `pair_from_pool/4`. Two comments in `pairings_live.ex` assert the
      # writes are refused server-side "regardless", which was not true for
      # them.
      refusal = write_refused(round.tournament_id) ->
        refusal

      # A player id arrives in a LiveView event payload, long after the mount
      # was authorised - `get_player!/2`'s own doc says exactly this: it is
      # attacker-controlled, and authorising the tournament proves nothing
      # about the row. `Pairing.changeset/2` casts the id with no ownership
      # check and the FK is `references(:players)` with no tournament column,
      # so any player id in the database was accepted onto this board.
      not player_belongs_to_tournament?(round.tournament_id, player_id) ->
        {:error, :invalid_player}

      is_nil(field) ->
        {:error, :seat_taken}

      pairing.result == "bye" ->
        # Not a vacancy - an allocated bye. Filling it would silently
        # convert a scored bye into a game; `award_bye_for_vacancy/2`'s
        # inverse is a deliberate, separate action.
        {:error, :not_a_vacancy}

      true ->
        Repo.transaction(fn ->
          {:ok, updated} = pairing |> Pairing.changeset(%{field => player_id}) |> Repo.update()
          delete_bye_row(round, player_id)
          updated
        end)
        |> finish_round_write(round.tournament_id)
    end
  end

  @doc """
  Resolves a vacancy the other way: the player still sitting at `pairing`
  gets a pairing-allocated bye. They move into the white seat (a bye is
  stored as `black_player_id: nil`, the shape `Standings` and the TRF
  export both already read) and the board scores `bye_value`.
  """
  def award_bye_for_vacancy(%Round{} = round, %Pairing{} = pairing) do
    remaining = pairing.white_player_id || pairing.black_player_id

    cond do
      refusal = write_refused(round.tournament_id) ->
        refusal

      is_nil(remaining) ->
        {:error, :empty_board}

      pairing.white_player_id && pairing.black_player_id ->
        {:error, :not_a_vacancy}

      true ->
        pairing
        |> Pairing.changeset(%{
          white_player_id: remaining,
          black_player_id: nil,
          result: "bye"
        })
        |> Repo.update()
        |> finish_round_write(round.tournament_id)
    end
  end

  @doc """
  Toggles the display-only `hidden` flag on a fully-vacated pairing (both
  seats empty - the state two "mark absent" gestures on the same board
  eventually leave behind) so an arbiter can declutter the pairings
  view/prints of a board with nobody left on it.

  Deliberately narrow and inert: `hidden` is never read by
  `PairingDisplay.compute_labels/1` or `freeze_round_display_boards!/1`, so
  toggling it can never change what any OTHER row's `display_board` shows
  - see `PairingsEngine.PairingDisplay`'s moduledoc for why that freeze
  must never be touched by anything but a (re-)pairing. The row's real
  board number, frozen display label, audit history and any TRF/export
  data are completely unaffected either way, and un-hiding brings the row
  back exactly as it was.

  Refused with `{:error, :not_vacant}` on a pairing with anyone still
  seated - hiding is for empty rows only, never a way to make an active
  board disappear from the arbiter's own working view.
  """
  def set_pairing_hidden(%Round{} = round, %Pairing{} = pairing, hidden?)
      when is_boolean(hidden?) do
    cond do
      refusal = write_refused(round.tournament_id) ->
        refusal

      pairing.white_player_id != nil or pairing.black_player_id != nil ->
        {:error, :not_vacant}

      true ->
        pairing
        |> Ecto.Changeset.change(hidden: hidden?)
        |> Repo.update()
        |> finish_round_write(round.tournament_id)
    end
  end

  @doc """
  Permanently deletes `pairing` - the row, and any result on it, gone for
  good. This is the one board-cleanup action that is NOT just a display
  toggle, so it is restricted to the two conditions that together make it
  safe:

    * `pairing` must be the round's own highest real `board` number.
      Deleting the trailing row never requires renumbering anything after
      it, since nothing comes after it - deleting anywhere else in the
      round would leave a permanent gap in the middle of the real board
      sequence for no invariant-preserving reason, so it's refused
      (`{:error, :not_last_board}`). This is a property of the real
      `board` column, decided fresh from the round's current pairings
      every call - never the frozen `display_board` string, which can be
      a fixed-table label like `"1001"` or a slash-joined `"5/6"` that
      doesn't order the same way real board numbers do.
    * `pairing` must be fully vacant (both seats empty) -
      `{:error, :not_vacant}` otherwise. This exists to let an arbiter
      clean up literal clutter, not as a general "undo a board" button;
      anything with a player still seated goes through `vacate_seat/3` (or
      a swap) first, same as hiding above.

  Standings/tiebreaks need no separate invalidation call beyond the usual
  `invalidate_manual_ranking/1` - `Standings.standings/1` always replays
  every pairing/bye from scratch (see the module doc), so a deleted empty
  pairing (no result, no players) simply stops existing to replay.
  """
  def delete_pairing(%Round{} = round, %Pairing{} = pairing) do
    max_board = round.pairings |> Enum.map(& &1.board) |> Enum.max(fn -> nil end)

    cond do
      refusal = write_refused(round.tournament_id) ->
        refusal

      pairing.white_player_id != nil or pairing.black_player_id != nil ->
        {:error, :not_vacant}

      pairing.board != max_board ->
        {:error, :not_last_board}

      true ->
        pairing
        |> Repo.delete()
        |> finish_round_write(round.tournament_id)
    end
  end

  @doc """
  Pairs two pool players into a brand-new board in `round`, numbered
  `board`. Both players' `"byes"` rows are dropped - they're playing.

  Re-checks `board` is still free right inside the transaction rather
  than trusting the `round` struct the caller happened to have on hand -
  the confirm dialog that stages this (PairingsLive's "pair these two"
  gesture) can now sit open across a remote update from another arbiter
  (see `keep_gesture` in that LiveView's `refresh/2`), so the board
  number could have been taken by something else in the meantime.
  Returns `{:error, :board_taken}` rather than creating a second pairing
  at the same board.
  """
  def pair_from_pool(%Round{} = round, white_id, black_id, board)
      when is_integer(board) and board > 0 do
    cond do
      refusal = write_refused(round.tournament_id) ->
        refusal

      white_id == black_id ->
        {:error, :same_player}

      # Same reasoning as `fill_seat/3`. `add_forbidden_pairing/3` already
      # enforces this with the same predicate; these seats did not.
      not both_players_belong_to_tournament?(round.tournament_id, white_id, black_id) ->
        {:error, :invalid_player}

      true ->
        do_pair_from_pool(round, white_id, black_id, board)
    end
  end

  defp do_pair_from_pool(round, white_id, black_id, board) do
    Repo.transaction(fn ->
      taken? =
        Repo.exists?(from p in Pairing, where: p.round_id == ^round.id and p.board == ^board)

      if taken? do
        Repo.rollback(:board_taken)
      else
        {:ok, created} =
          %Pairing{round_id: round.id}
          |> Pairing.changeset(%{
            board: board,
            white_player_id: white_id,
            black_player_id: black_id,
            result: ""
          })
          |> Repo.insert()

        # Every other pairing-creating path freezes what it inserts; this
        # one did not, so its row fell through to
        # `PairingDisplay.fallback_label/1` and printed its REAL board
        # number, outside the round's frozen sequence. Narrow on purpose -
        # see `freeze_new_pairing_display_board!/1` for why re-freezing the
        # whole round here would be the wrong fix.
        :ok = freeze_new_pairing_display_board!(created)

        delete_bye_row(round, white_id)
        delete_bye_row(round, black_id)
        created
      end
    end)
    |> finish_round_write(round.tournament_id)
  end

  @doc """
  The lowest board number not already used in `round` - what the "pair
  these two" action offers as a default table number.
  """
  def next_free_board(%Round{} = round) do
    used = MapSet.new(round.pairings, & &1.board)
    Enum.find(1..(MapSet.size(used) + 1)//1, &(not MapSet.member?(used, &1)))
  end

  @doc """
  Swaps a SEATED player with one from `list_round_pool/2`: the pool player
  takes the seat (board, colour and opponent all unchanged), and the
  player who was there goes into the pool in their place, filed under the
  same `"byes"` type the pool player had - an "absent" swap hands over the
  absence along with the seat, so the round's absentee count doesn't
  change just because two names traded places.

  A pool player with no `"byes"` row at all (simply unpaired) hands over
  `"absent"`, that being what the displaced player now is.

  Returns `{:error, :invalid_player}` if `pool_id` isn't a player of this
  tournament, and `{:error, :already_seated}` if they have been given a
  board in this round since the gesture was staged.
  """
  def swap_seated_with_pool_player(%Round{} = round, seated_id, pool_id) do
    with :ok <- ensure_writable(round.tournament_id),
         {:ok, {pairing, field}} <- find_player_seat(round.pairings, seated_id) do
      handover_type = pool_player_type(round, pool_id) || "absent"

      Repo.transaction(fn ->
        # The confirmation gesture this arrives from can sit open for
        # minutes across a remote change by another arbiter (see
        # `keep_gesture` in PairingsLive's `refresh/2`), so `pool_id` is
        # re-checked here, inside the transaction, against the database
        # rather than against the possibly-stale `round.pairings` the
        # caller handed us. Same two guards the siblings already have:
        # `fill_seat/3` checks tournament membership and
        # `do_pair_from_pool/4` re-checks the board.
        cond do
          not player_belongs_to_tournament?(round.tournament_id, pool_id) ->
            Repo.rollback(:invalid_player)

          player_seated_in_round?(round.id, pool_id) ->
            Repo.rollback(:already_seated)

          true ->
            :ok
        end

        {:ok, updated} =
          pairing
          |> Pairing.changeset(clear_stale_result(%{field => pool_id}, pairing))
          |> Repo.update()

        delete_bye_row(round, pool_id)

        Repo.insert_all(
          "byes",
          [
            %{
              tournament_id: round.tournament_id,
              player_id: seated_id,
              round: round.number,
              type: handover_type
            }
          ],
          on_conflict: :nothing
        )

        updated
      end)
      |> finish_round_write(round.tournament_id)
    end
  end

  # A fresh read of "is this player already on a board in this round?" -
  # deliberately a query and not `Enum.any?(round.pairings, …)`, because the
  # caller's `round` struct is exactly what may be out of date.
  defp player_seated_in_round?(round_id, player_id) do
    Repo.exists?(
      from p in Pairing,
        where:
          p.round_id == ^round_id and
            (p.white_player_id == ^player_id or p.black_player_id == ^player_id)
    )
  end

  defp pool_player_type(%Round{} = round, player_id) do
    Repo.one(
      from b in "byes",
        where:
          b.tournament_id == ^round.tournament_id and b.round == ^round.number and
            b.player_id == ^player_id,
        select: b.type
    )
  end

  defp delete_bye_row(%Round{} = round, player_id) do
    Repo.delete_all(
      from b in "byes",
        where:
          b.tournament_id == ^round.tournament_id and b.round == ^round.number and
            b.player_id == ^player_id
    )
  end

  ## ---------- Tournament/round status ----------
  #
  # `status` ("setup" | "running" | "finished") is derived, not hand-set -
  # see `refresh_status!/1` below. A round itself is considered "finished"
  # when every one of its pairings carries a result (a "bye" pairing's
  # result is the literal string "bye", already non-blank, so pairing-
  # allocated byes never block a round from counting as finished).

  @doc """
  Derives `tournament`'s status from its actual pairing/scoring state and
  persists it if it changed, returning the (possibly updated) tournament
  unchanged otherwise. Accepts either a `%Tournament{}` or a tournament id.

    * `"finished"` - `rounds_count` rounds have been paired, and every
      pairing in every paired round has a recorded result.
    * `"running"`  - at least one round has been paired, but the tournament
      isn't finished yet per the rule above.
    * `"setup"`    - no round has been paired yet.

  Tolerant and self-contained by design: safe to call after any write that
  might affect completeness (a result entered, a round paired or unpaired,
  a bulk import) without the caller needing to know the current status or
  pass any extra context. Returns `nil` if the tournament (or its id) no
  longer exists - e.g. deleted concurrently - rather than raising.

  Broadcasts `{:tournament_changed, tournament_id, :tournament}` (the same
  hint `delete_tournament/1` uses) only when the status actually changes, so
  callers that already broadcast their own hint for the same write (e.g.
  `:results`, `:rounds`) don't spam a second identical message on a no-op.
  """
  def refresh_status!(%Tournament{} = tournament) do
    status = derive_status(tournament)

    if status != tournament.status do
      {:ok, updated} =
        tournament
        |> Tournament.changeset(%{status: status})
        |> Repo.update()

      broadcast_tournament_change(updated.id, :tournament)
      updated
    else
      tournament
    end
  end

  def refresh_status!(tournament_id) do
    case Repo.get(Tournament, tournament_id) do
      nil -> nil
      tournament -> refresh_status!(tournament)
    end
  end

  @doc """
  Names the tournaments that are mid-event: paired, and not yet fully scored.

  Used to keep a rating-list sync from starting on top of a live round.
  SQLite takes ONE write lock for the whole database, and the two sync
  transactions are the only things in the application that hold it for more
  than milliseconds - long enough that an arbiter entering a result waits out
  `busy_timeout` and is refused. A rating list can be refreshed at any time;
  a result cannot wait for one. So the sync yields, not the arbiter.
  """
  def running_tournament_names do
    Repo.all(
      from t in Tournament,
        where: t.status == "running",
        order_by: t.name,
        select: t.name
    )
  end

  defp derive_status(%Tournament{} = tournament) do
    paired = Repo.aggregate(from(r in Round, where: r.tournament_id == ^tournament.id), :count)

    cond do
      paired == 0 -> "setup"
      paired >= tournament.rounds_count and all_rounds_scored?(tournament.id) -> "finished"
      true -> "running"
    end
  end

  defp all_rounds_scored?(tournament_id) do
    not Repo.exists?(
      from p in Pairing,
        join: r in Round,
        on: p.round_id == r.id,
        where: r.tournament_id == ^tournament_id and p.result == ""
    )
  end
end
