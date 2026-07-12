defmodule PairingsEngine.Tournaments do
  @moduledoc """
  Tournament, player, team and round management, plus ownership/access
  control — who owns a tournament, and who else it's been shared with (see
  `PairingsEngine.Tournaments.Collaborator` and `docs/teams.md` for the
  full "share a tournament by email" feature).
  """

  import Ecto.Query
  alias PairingsEngine.Repo
  alias PairingsEngine.Tiebreaks
  alias PairingsEngine.Accounts
  alias PairingsEngine.Accounts.{Scope, User}
  alias PairingsEngine.Tournaments.{Tournament, Player, Team, Round, Pairing, Collaborator}

  ## ---------- Live updates (PubSub) ----------
  #
  # Every write in this module (and in the other modules that mutate
  # tournament-scoped data directly, namely PairingsEngine.Pairing and
  # PairingsEngine.SwarImport) broadcasts on the tournament's topic so any
  # open LiveView showing that tournament can reload instantly instead of
  # polling. `hint` is a lightweight atom describing what changed
  # (:players, :pairings, :results, :settings, :rounds, :tournament) — most
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
    end

    :ok
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
  single `Repo.transaction` (e.g. `PairingsEngine.SwarImport`) — broadcasting
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

  Returns `{tournament, player_count, owner?}` tuples — `owner?` is `true`
  when `scope.user` is the tournament's owner and `false` when it's shared
  with them as a collaborator, so the UI can tell the two apart (e.g. a
  "shared" badge).
  """
  def list_tournaments(%Scope{} = scope) do
    user = scope.user

    Repo.all(
      from t in Tournament,
        left_join: p in assoc(t, :players),
        where: t.user_id == ^user.id or t.id in subquery(collaborator_tournament_ids(user)),
        group_by: t.id,
        select: {t, count(p.id), t.user_id == ^user.id},
        order_by: [desc: t.inserted_at]
    )
  end

  @doc "True if `scope.user` is the tournament's owner (as opposed to a collaborator)."
  def owner?(%Tournament{} = tournament, %Scope{} = scope), do: tournament.user_id == scope.user.id

  def get_tournament!(id), do: Repo.get!(Tournament, id)

  @doc """
  Gets a tournament by its `public_slug` — the unguessable token behind the
  public (no-login) read-only pages (see docs/public-pages.md). Returns
  `nil` if no tournament has this slug.

  **Deliberately no scope/authorization check** — this is the one lookup in
  this module that's meant to be public. Anyone holding the link can view
  the tournament; the slug itself (a random 12-byte token, not the
  sequential numeric `id`) is what keeps it from being enumerable.
  """
  def get_tournament_by_public_slug(slug), do: Repo.get_by(Tournament, public_slug: slug)

  @doc """
  Gets a tournament owned by the scope's user.

  Raises `Ecto.NoResultsError` if the tournament doesn't exist or isn't
  owned by the scope's user (so URL guessing can't leak other users' data).
  """
  def get_user_tournament!(%Scope{} = scope, id) do
    Repo.get_by!(Tournament, id: id, user_id: scope.user.id)
  end

  @doc """
  Same as `get_user_tournament!/2`, but returns `nil` instead of raising —
  useful when reloading after a PubSub notification, since the tournament
  may have been deleted (by another tab/user) in the meantime.
  """
  def get_user_tournament(%Scope{} = scope, id) do
    Repo.get_by(Tournament, id: id, user_id: scope.user.id)
  end

  @doc """
  Gets a tournament the scope's user is authorized to access — either
  because they own it, or because they collaborate on it (matched by
  `user_id`, or by `email` for a not-yet-linked pending invite; see
  `link_pending_collaborators/1`).

  Use this (instead of `get_user_tournament!/2`) for every tournament-scoped
  view/action a collaborator should also be able to use — everything except
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
  raising — useful when reloading after a PubSub notification, since the
  tournament may have been deleted (or the caller's access revoked) in the
  meantime.
  """
  def get_authorized_tournament(%Scope{} = scope, id) do
    Repo.one(authorized_tournament_query(scope, id))
  end

  defp authorized_tournament_query(%Scope{} = scope, id) do
    user = scope.user

    from t in Tournament,
      where: t.id == ^id and (t.user_id == ^user.id or t.id in subquery(collaborator_tournament_ids(user)))
  end

  # Only *accepted* collaborator rows grant access — a pending invite (added
  # but not yet accepted via `/invites/:token`, see `accept_invitation/2`)
  # must not unlock the tournament for anyone. This is the single choke
  # point both `authorized_tournament_query/2` and `list_tournaments/1` go
  # through, so it's the only place that needs to know about `status`.
  defp collaborator_tournament_ids(%User{} = user) do
    from c in Collaborator,
      where: c.status == "accepted" and (c.user_id == ^user.id or c.email == ^user.email),
      select: c.tournament_id
  end

  ## Collaborators (tournament sharing by email — see docs/teams.md)

  @doc "Lists a tournament's collaborators (pending and active), most recently added first."
  def list_collaborators(%Tournament{} = tournament) do
    Repo.all(
      from c in Collaborator,
        where: c.tournament_id == ^tournament.id,
        order_by: [desc: c.inserted_at]
    )
  end

  @doc """
  Invites `email` to collaborate on `tournament`. Owner-only — returns
  `{:error, :not_owner}` unless `scope.user` is the tournament's owner.

  This grants **no access by itself** — it creates a `status: "pending"`
  row with a fresh `invite_token` and emails that person a link to
  `/invites/:token` (see `PairingsEngineWeb.InviteLive`), where they must
  explicitly accept (`accept_invitation/2`) before `collaborator_tournament_ids/1`
  will count them. If a user with this email already exists, `user_id` is
  linked immediately (a courtesy for `list_pending_invitations/1`,
  irrelevant to access); otherwise it stays `nil` until that person logs in
  (see `link_pending_collaborators/1`) or accepts. Rejects the owner's own
  email and a duplicate email gracefully rather than raising.

  Returns `{:ok, collaborator}` on success, where `collaborator.mail_status`
  (a virtual field, not persisted) is `:sent` or `:failed` — the row is
  still created even if the invitation email couldn't be delivered (e.g. an
  SMTP hiccup), so the owner can share `/invites/<invite_token>` manually.
  """
  def add_collaborator(%Scope{} = scope, %Tournament{} = tournament, email) do
    email = normalize_email(email)
    owner_email = normalize_email(scope.user.email)

    cond do
      tournament.user_id != scope.user.id ->
        {:error, :not_owner}

      email == "" ->
        {:error, :blank_email}

      email == owner_email ->
        {:error, :cannot_add_owner}

      Repo.exists?(from c in Collaborator, where: c.tournament_id == ^tournament.id and c.email == ^email) ->
        {:error, :already_added}

      true ->
        user = Accounts.get_user_by_email(email)

        %Collaborator{tournament_id: tournament.id, user_id: user && user.id}
        |> Collaborator.changeset(%{email: email, status: "pending", invite_token: generate_invite_token()})
        |> Repo.insert()
        |> case do
          {:ok, collaborator} ->
            broadcast_tournament_change(tournament.id, :collaborators)
            if collaborator.user_id, do: broadcast_user_tournaments(collaborator.user_id)
            {:ok, %{collaborator | mail_status: deliver_invitation_email(scope.user, tournament, collaborator)}}

          error ->
            error
        end
    end
  end

  # Never lets a mailer exception (e.g. an SMTP hiccup) crash the caller —
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

  defp generate_invite_token, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

  @doc """
  Removes a collaborator from `tournament` — whether still pending or
  already accepted. Owner-only — returns `{:error, :not_owner}` unless
  `scope.user` is the tournament's owner, and `{:error, :not_found}` if
  `collaborator_id` isn't one of this tournament's collaborators. For a
  pending row, this revokes the invitation outright.
  """
  def remove_collaborator(%Scope{} = scope, %Tournament{} = tournament, collaborator_id) do
    if tournament.user_id != scope.user.id do
      {:error, :not_owner}
    else
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
  Lists the scope's user's pending invitations — collaborator rows with
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
  `id` — see `find_invitation/1`. Requires the scope's user's email to
  match the invitation's email (case-insensitively); returns
  `{:error, :email_mismatch}` otherwise, so a logged-in user can't accept an
  invite that was sent to someone else. Returns `{:error, :not_found}` if
  the token/id doesn't match a pending row.

  On success, sets `status: "accepted"`, links `user_id` to the scope's
  user, and clears `invite_token` (it's single-use). Broadcasts on both the
  tournament's topic and the user's tournament-list topic so any open
  LiveView refreshes live.
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
  `id` — deletes the row outright. Requires the scope's user's email to
  match the invitation's email (case-insensitively), same as
  `accept_invitation/2`. Returns `{:error, :not_found}` or
  `{:error, :email_mismatch}`.
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
  Used by `accept_invitation/2`, `decline_invitation/2` and
  `PairingsEngineWeb.InviteLive` (the `/invites/:token` page).
  """
  def find_invitation(token_or_id) do
    case Integer.parse(to_string(token_or_id)) do
      {id, ""} -> Repo.get(Collaborator, id)
      _ -> Repo.get_by(Collaborator, invite_token: token_or_id)
    end
  end

  @doc """
  Links any pending `tournament_collaborators` rows (invited by email before
  that person had an account) to `user`, by matching `email`. Call this on
  every login (see `PairingsEngineWeb.UserAuth.log_in_user/3`) so a
  freshly-registered invitee can find their invitation under `user_id` too,
  and so `list_pending_invitations/1` picks it up without needing an exact
  email match. This alone still grants **no access** — the invite stays
  `status: "pending"` until explicitly accepted. Idempotent — a no-op once
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
    tournament
    |> Tournament.changeset(attrs)
    |> Repo.update()
    |> tap_ok(fn updated ->
      broadcast_tournament_change(updated.id, :settings)
      broadcast_user_tournaments(updated.user_id)
    end)
  end

  def delete_tournament(%Tournament{} = tournament) do
    Repo.delete(tournament)
    |> tap_ok(fn deleted ->
      broadcast_tournament_change(deleted.id, :tournament)
      broadcast_user_tournaments(deleted.user_id)
    end)
  end

  def change_tournament(%Tournament{} = tournament, attrs \\ %{}) do
    Tournament.changeset(tournament, attrs)
  end

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
          desc: fragment("CASE WHEN ? > 0 THEN ? ELSE ? END", p.fide_rating, p.fide_rating, p.national_rating),
          asc: p.name
        ]
    )
  end

  def count_players(tournament_id) do
    Repo.aggregate(from(p in Player, where: p.tournament_id == ^tournament_id), :count)
  end

  def get_player!(id), do: Repo.get!(Player, id)

  def create_player(tournament_id, attrs) do
    fide_id = attrs["fide_id"] || attrs[:fide_id]

    duplicate? =
      fide_id not in [nil, ""] and
        Repo.exists?(
          from p in Player,
            where: p.tournament_id == ^tournament_id and p.fide_id == ^fide_id
        )

    if duplicate? do
      {:error, :duplicate_fide_id}
    else
      %Player{tournament_id: tournament_id}
      |> Player.changeset(attrs)
      |> Repo.insert()
      |> tap_ok(fn player -> broadcast_tournament_change(player.tournament_id, :players) end)
    end
  end

  def update_player(%Player{} = player, attrs) do
    player
    |> Player.changeset(attrs)
    |> Repo.update()
    |> tap_ok(fn updated -> broadcast_tournament_change(updated.tournament_id, :players) end)
  end

  def delete_player(%Player{} = player) do
    Repo.delete(player)
    |> tap_ok(fn deleted -> broadcast_tournament_change(deleted.tournament_id, :players) end)
  end

  def change_player(%Player{} = player, attrs \\ %{}), do: Player.changeset(player, attrs)

  ## Teams

  def list_teams(tournament_id) do
    Repo.all(from t in Team, where: t.tournament_id == ^tournament_id, order_by: t.name)
  end

  ## Rounds & pairings (round lifecycle is filled in by the pairing engine)

  def get_round(tournament_id, number) do
    Repo.one(
      from r in Round,
        where: r.tournament_id == ^tournament_id and r.number == ^number,
        preload: [pairings: [:white_player, :black_player]]
    )
  end

  def list_rounds(tournament_id) do
    Repo.all(from r in Round, where: r.tournament_id == ^tournament_id, order_by: r.number)
  end

  def update_pairing_result(%Pairing{} = pairing, result) do
    pairing
    |> Pairing.changeset(%{result: result})
    |> Repo.update()
    |> tap_ok(fn updated ->
      broadcast_tournament_change(round_tournament_id(updated.round_id), :results)
    end)
  end

  defp round_tournament_id(round_id) do
    Repo.one(from r in Round, where: r.id == ^round_id, select: r.tournament_id)
  end
end
