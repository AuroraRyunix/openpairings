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
  alias PairingsEngine.Standings
  alias PairingsEngine.PlayerStats
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
        where:
          is_nil(t.deleted_at) and
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
  Gets a tournament by id, excluding soft-deleted (recycle-binned) ones —
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
  Gets a tournament by its `public_slug` — the unguessable token behind the
  public (no-login) read-only pages (see docs/public-pages.md). Returns
  `nil` if no tournament has this slug.

  **Deliberately no scope/authorization check** — this is the one lookup in
  this module that's meant to be public. Anyone holding the link can view
  the tournament; the slug itself (a random 12-byte token, not the
  sequential numeric `id`) is what keeps it from being enumerable.

  Honours `public_pages_enabled`: a tournament whose owner has switched its
  public pages off returns `nil` here (a 404 to the visitor) even with the
  correct slug, so taking the pages down is immediate and a later rotate or
  re-enable doesn't resurrect the old link.
  """
  def get_tournament_by_public_slug(slug) do
    Repo.one(
      from t in Tournament,
        where: t.public_slug == ^slug and t.public_pages_enabled == true and is_nil(t.deleted_at)
    )
  end

  @doc """
  Finds an existing, non-deleted tournament (owned by or shared with
  `scope`'s user) that was already imported from the same `.swar` file —
  matched on `swar_guid`, the persistent per-tournament id SWAR itself
  stamps into every export of the same tournament (see
  `PairingsEngine.SwarImport.parse/1`'s `:guid`). Used to warn before a
  re-upload of the same tournament silently creates a duplicate — see
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
  Same as `get_user_tournament!/2`, but returns `nil` instead of raising —
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
  currently in the recycle bin (`deleted_at` set) — the counterpart to
  `get_user_tournament!/2` for the Recycle bin panel's Restore/Delete
  permanently actions, which need to load the very row `list_tournaments/1`
  now hides. Raises `Ecto.NoResultsError` if the tournament doesn't exist or
  isn't owned by the scope's user.
  """
  def get_owned_tournament_including_deleted!(%Scope{} = scope, id) do
    Repo.get_by!(Tournament, id: id, user_id: scope.user.id)
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
      where:
        t.id == ^id and is_nil(t.deleted_at) and
          (t.user_id == ^user.id or t.id in subquery(collaborator_tournament_ids(user)))
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

  defp generate_invite_token,
    do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

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

  Only ever call this where the caller then proves the row is the current
  user's — `accept_invitation/2` and `decline_invitation/2` both check the
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
  Finds a collaborator row by its `invite_token` only — never by id, so a
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

  ## ---------- Logo (SWAR parity #14-16 — place cards) ----------
  #
  # Per-tournament print logo, stored as a DB blob (`tournaments.logo_data`
  # + `logo_content_type`) so backups/deploys carry it — no filesystem or
  # upload-dir question. Both fields are deliberately NOT cast by
  # `Tournament.changeset/2` (see that schema's comment), so an ordinary
  # settings-form save can never clobber the blob; these two functions are
  # the only writers.

  # A print logo has no business being larger than this — it's stored in
  # the DB and shipped in every JSON backup.
  @max_logo_bytes 2_000_000

  @doc """
  Sets `tournament`'s print logo (embedded as a base64 `data:` URI by
  `PairingsEngineWeb.PrintController` — see `docs/printing.md`) after
  verifying `binary` is actually one of the accepted raster image types, by
  its real file signature (magic bytes) — never by a filename extension or
  the browser-supplied content-type, both of which are attacker-controlled.
  SVG is deliberately never accepted, no matter how it's labelled: it's an
  XML document that can carry scripts, and this blob is rendered straight
  back into pages we serve, so raster-only removes that whole class of
  problem. See `detect_image_type/1` for the exact signatures checked and
  the size cap.

  Returns `{:error, :invalid_image}` (never touching the row) for anything
  that fails validation — the caller (`SettingsLive`) turns that into a
  friendly flash rather than ever storing unvalidated bytes.
  """
  @spec set_logo(Tournament.t(), binary()) ::
          {:ok, Tournament.t()} | {:error, :invalid_image} | {:error, Ecto.Changeset.t()}
  def set_logo(%Tournament{} = tournament, binary) when is_binary(binary) do
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
    tournament
    |> Ecto.Changeset.change(logo_data: nil, logo_content_type: nil)
    |> Repo.update()
    |> tap_ok(fn updated -> broadcast_tournament_change(updated.id, :settings) end)
  end

  ## ---------- Public pages (enable/disable + slug rotation) ----------
  #
  # The public read-only pages (/p/:slug/...) expose player names, ratings,
  # clubs and federations to anyone with the link. These two functions are the
  # off switch and the "the link leaked" recovery for that — `public_slug` and
  # `public_pages_enabled` are both deliberately outside `Tournament.changeset/2`,
  # so an ordinary settings save can neither disable sharing nor rotate a link
  # by accident; these are the only writers.

  @doc """
  Turns `tournament`'s public pages on or off. While off,
  `get_tournament_by_public_slug/1` returns `nil`, so every `/p/:slug/...`
  page 404s regardless of the slug. Broadcasts `:settings`.
  """
  @spec set_public_pages(Tournament.t(), boolean()) ::
          {:ok, Tournament.t()} | {:error, Ecto.Changeset.t()}
  def set_public_pages(%Tournament{} = tournament, enabled?) when is_boolean(enabled?) do
    tournament
    |> Ecto.Changeset.change(public_pages_enabled: enabled?)
    |> Repo.update()
    |> tap_ok(fn updated -> broadcast_tournament_change(updated.id, :settings) end)
  end

  @doc """
  Opens or closes public self-registration at `/p/:slug/register`.

  Deliberately a controlled setter rather than a `changeset/2` field, like
  `set_public_pages/2` and `rotate_public_slug/1`: this is the only public
  page that WRITES to the tournament, so an ordinary settings save must not
  be able to open it by accident. Broadcasts `:settings`, which closes the
  form live on every device already holding it open.
  """
  @spec set_registration_open(Tournament.t(), boolean()) ::
          {:ok, Tournament.t()} | {:error, Ecto.Changeset.t()}
  def set_registration_open(%Tournament{} = tournament, open?) when is_boolean(open?) do
    tournament
    |> Ecto.Changeset.change(registration_open: open?)
    |> Repo.update()
    |> tap_ok(fn updated -> broadcast_tournament_change(updated.id, :settings) end)
  end

  @doc """
  Looks up a tournament by `public_slug` for the self-registration form,
  returning `nil` unless registration is actually open right now.

  Separate from `get_tournament_by_public_slug/1` so that closing the form
  cannot be bypassed: the read-only public pages stay reachable while
  registration is shut, and every entry point to the writing page has to go
  through this one function.
  """
  @spec get_tournament_for_registration(String.t()) :: Tournament.t() | nil
  def get_tournament_for_registration(slug) do
    Repo.one(
      from t in Tournament,
        where:
          t.public_slug == ^slug and t.public_pages_enabled == true and
            t.registration_open == true and is_nil(t.deleted_at)
    )
  end

  @doc """
  Registers a player from the public form.

  Always lands them **absent**. Someone filling in a web form has announced
  an intention, not turned up — the arbiter marks them present when they
  actually do. Getting this backwards would silently pair a no-show and
  hand their opponent a forfeit win, so `absent: true` is forced here
  rather than taken from the submitted params.

  Re-checks `registration_open` inside the call instead of trusting the
  caller: the form is a long-lived LiveView and the arbiter may close
  registration between the page rendering and someone pressing submit.

  Everything else the arbiter can edit afterwards on the Players page, so
  this takes only what the form collects and lets `create_player/2`'s own
  duplicate-FIDE-id guard reject a double entry.
  """
  @spec register_public_player(String.t(), map()) ::
          {:ok, Player.t()} | {:error, :closed | :duplicate_fide_id | Ecto.Changeset.t()}
  def register_public_player(slug, attrs) do
    case get_tournament_for_registration(slug) do
      nil ->
        {:error, :closed}

      tournament ->
        attrs =
          attrs
          |> Map.take(["name", "fide_id", "fide_rating", "title", "federation", "birth_year"])
          |> Map.put("absent", true)

        create_player(tournament.id, attrs)
    end
  end

  @doc """
  Rotates `tournament`'s `public_slug` to a fresh random token, permanently
  invalidating any previously shared link while leaving the pages enabled.
  Broadcasts `:settings`.
  """
  @spec rotate_public_slug(Tournament.t()) ::
          {:ok, Tournament.t()} | {:error, Ecto.Changeset.t()}
  def rotate_public_slug(%Tournament{} = tournament) do
    tournament
    |> Ecto.Changeset.change(public_slug: Tournament.generate_public_slug())
    |> Repo.update()
    |> tap_ok(fn updated -> broadcast_tournament_change(updated.id, :settings) end)
  end

  @doc """
  Sniffs `binary`'s real file-format signature and returns
  `{:ok, verified_content_type}` for one of the accepted raster types, or
  `:error` for anything else — including a well-formed SVG (never accepted,
  see `set_logo/2`) or anything over #{@max_logo_bytes} bytes.

  Signatures checked (first matching bytes win, order doesn't matter — the
  four are mutually exclusive):

    * PNG  — the 8-byte PNG signature `\\x89 P N G \\r \\n \\x1a \\n`
    * JPEG — the `\\xFF \\xD8 \\xFF` SOI marker
    * GIF  — `GIF87a` or `GIF89a`
    * WebP — a RIFF container carrying a `WEBP` fourcc (`RIFF????WEBP`)
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
  # it outright — it sets `deleted_at`, which every normal listing/fetch
  # path above (`list_tournaments/1`, `get_tournament!/1`,
  # `get_tournament_by_public_slug/1`, `get_user_tournament!/2`,
  # `get_user_tournament/2`, `get_authorized_tournament!/2`,
  # `get_authorized_tournament/2`) now excludes, so a binned tournament's
  # own pages, public pages and exports all 404/disappear exactly as if it
  # had been hard-deleted. The row (and everything cascade-linked to it)
  # only actually goes away via `purge_tournament/1`, either picked by the
  # owner from the bin or swept up automatically by
  # `purge_expired_tournaments/0` once it's more than 90 days old.

  @recycle_bin_retention_days 90

  @doc """
  Moves `tournament` to the recycle bin — sets `deleted_at` to now (truncated
  to the second) instead of deleting the row. From this point on every
  normal fetch/listing path treats it as gone; `restore_tournament/1` undoes
  this, `purge_tournament/1` finishes the job for real. Broadcasts on the
  owner's tournament-list topic, same as `delete_tournament/1` did, so the
  Tournaments page refreshes live.
  """
  def soft_delete_tournament(%Tournament{} = tournament) do
    tournament
    |> Ecto.Changeset.change(deleted_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update()
    |> tap_ok(fn updated ->
      broadcast_tournament_change(updated.id, :tournament)
      broadcast_user_tournaments(updated.user_id)
    end)
  end

  @doc """
  Restores `tournament` out of the recycle bin — clears `deleted_at`, so it
  reappears everywhere `soft_delete_tournament/1` made it disappear from.
  Broadcasts the same as `soft_delete_tournament/1`.
  """
  def restore_tournament(%Tournament{} = tournament) do
    tournament
    |> Ecto.Changeset.change(deleted_at: nil)
    |> Repo.update()
    |> tap_ok(fn updated ->
      broadcast_tournament_change(updated.id, :tournament)
      broadcast_user_tournaments(updated.user_id)
    end)
  end

  @doc """
  The real, irreversible hard delete — cascades exactly like
  `delete_tournament/1` (which this now backs), used both for the owner's
  "Delete permanently" action from the recycle bin and by
  `purge_expired_tournaments/0`'s automatic sweep.
  """
  def purge_tournament(%Tournament{} = tournament), do: delete_tournament(tournament)

  @doc """
  Lists the scope's user's own recycle-binned tournaments (`deleted_at` set),
  most recently deleted first — collaborator-shared tournaments never show
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
  `TournamentsLive`'s mount/handle_params) rather than on a schedule — cheap
  enough to run on every page load, and self-correcting if a deploy misses a
  few days. Returns the number of tournaments purged.
  """
  def purge_expired_tournaments do
    cutoff = DateTime.utc_now() |> DateTime.add(-@recycle_bin_retention_days, :day)

    expired =
      Repo.all(from t in Tournament, where: not is_nil(t.deleted_at) and t.deleted_at < ^cutoff)

    Enum.each(expired, &purge_tournament/1)

    length(expired)
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
  as it does for one that doesn't exist — a caller cannot tell the difference,
  and cannot act on the row either way.
  """
  def get_player!(tournament_id, id),
    do: Repo.get_by!(Player, id: id, tournament_id: tournament_id)

  @doc """
  Like `get_player!/2` but returns `nil` instead of raising when the player
  doesn't exist in this tournament — and, unlike the bang version, tolerates
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
    |> guard_pairing_number_freeze(player)
    |> Repo.update()
    |> tap_ok(fn updated -> broadcast_tournament_change(updated.tournament_id, :players) end)
  end

  # FIDE C.04.2.B.3: a player's pairing number (TPN) may be adjusted while
  # the "List of Participants" is still effectively open (late entries,
  # early data-entry corrections), but "no modification of a TPN ... is
  # allowed after the fourth round has been paired" — every already-played
  # round's opponent references are keyed on that number, so reshuffling it
  # later silently corrupts what "round 2, board 5" actually meant.
  #
  # Only guards an *existing* number being changed to a different one —
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
    Repo.delete(player)
    |> tap_ok(fn deleted -> broadcast_tournament_change(deleted.tournament_id, :players) end)
  end

  @doc """
  Applies `updates` (a list of `{%Player{}, attrs}` pairs) in a single
  transaction and fires exactly one `tournament_changed` broadcast on
  success — used by `PairingsEngine.RatingRefresh.apply/2` so a bulk rating
  refresh doesn't flood open LiveViews with one broadcast per player.
  Rolls back (returning `{:error, changeset}`) if any single update fails
  validation.
  """
  def bulk_update_players(tournament_id, updates) do
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

  @doc """
  Sets the whole-tournament `absent` flag on every player in `tournament_id`
  to `absent?` — the "All Absent" / "All Present" right-click action on the
  Players grid's Pr. column header.

  Deliberately touches ONLY that one boolean. `absent_rounds` (the
  per-round SWAR notation, see `PairingsEngineWeb.PlayersLive`'s `cell/2`
  "pr" clause) is left exactly as each player had it — this is the
  generally-present/generally-absent switch, not a bulk edit of who is
  out for which specific round. One transaction, one broadcast, via
  `bulk_update_players/2`.
  """
  def set_all_players_absent(tournament_id, absent?) when is_boolean(absent?) do
    players = list_players(tournament_id)
    updates = for p <- players, do: {p, %{"absent" => absent?}}
    bulk_update_players(tournament_id, updates)
  end

  def change_player(%Player{} = player, attrs \\ %{}), do: Player.changeset(player, attrs)

  @doc """
  Applies `tournament.extra_points_bands` (SWAR parity #12 Elo-band
  auto-assign — see `PairingsEngine.Tournaments.Tournament.band_extra_points/2`
  and `docs/extra-points.md`) to every player in the tournament, **overwriting**
  each player's `extra_points` — a player matching no band is set back to
  `0.0`, not left alone, so re-running after a rating change (or a bands
  edit) always reflects the current rule rather than layering on top of a
  stale prior run. A single transaction, one `tournament_changed` broadcast
  (via `bulk_update_players/2`), same pattern as `PairingsEngine.RatingRefresh.apply/2`.

  Returns `{:ok, %{matched: n, total: m}}` — `matched` counts players whose
  rating fell under at least one band (bonus > 0.0), `total` every player in
  the tournament — for the "Set extra points for N of M players" summary on
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
  each player's `category` — same shape as `apply_extra_points_bands/1`.
  Unconditional: a player who matches no rule is set back to `""`, not
  left alone, so re-running after a rating update (or a rule edit) always
  reflects the current rules rather than a stale prior run — and, as a
  direct consequence, running this DOES clear any category the arbiter
  set by hand that doesn't happen to also be a ruled category's match.
  Only meant for tournaments where category is fully rule-driven; a mix
  of ruled and hand-picked categories doesn't survive a re-run.

  One transaction, one broadcast (`bulk_update_players/2`). Returns
  `{:ok, %{matched: n, total: m}}` — `matched` counts players who landed
  in a RULED category (not `""`) — for the same "Assigned N of M players"
  summary `ExtraPointsLive` shows for its own bulk rule application.
  """
  @spec auto_assign_categories(Tournament.t()) ::
          {:ok, %{matched: non_neg_integer(), total: non_neg_integer()}} | {:error, term()}
  def auto_assign_categories(%Tournament{} = tournament) do
    players = list_players(tournament.id)

    updates =
      Enum.map(players, fn player ->
        category =
          PlayerStats.assign_category(player, tournament.categories, tournament.category_rules)

        {player, %{category: category}}
      end)

    matched = Enum.count(updates, fn {_player, attrs} -> attrs.category != "" end)

    case bulk_update_players(tournament.id, updates) do
      {:ok, _updated} -> {:ok, %{matched: matched, total: length(players)}}
      error -> error
    end
  end

  ## ---------- Manual standings override (SWAR parity #23) ----------
  #
  # See docs/manual-standings.md for the full write-up: seeding, the
  # staleness mechanism, and why Keizer tournaments don't offer this. Short
  # version: `tournament.manual_ranking` lets the arbiter hand-order the
  # standings display via `players.manual_rank` — always a plain positive
  # `1..N` value (or `nil` for a never-placed player), never sign-encoded.
  # Staleness lives on `tournaments.manual_ranking_stale` (one row, set by
  # `invalidate_manual_ranking/1` below and read back by
  # `PairingsEngine.Standings.manual_ranking_stale?/1`). This never touches
  # points/tiebreaks, only which `:rank` gets displayed
  # (`PairingsEngine.Standings.apply_manual_ranking/2`). Nothing here
  # special-cases Keizer — the only caller of these functions
  # (`StandingsLive`) simply never shows the controls when
  # `pairing_system == "keizer"`.

  @doc """
  Turns manual ranking on for `tournament` and seeds every player's
  `manual_rank` from the current computed standings order (SWAR parity #23
  requirement: seed from the real standings, not an empty/arbitrary list).
  Safe to call even when manual ranking is already on — always reseeds
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
  place (harmless while off — nothing reads it) so switching back on later
  starts from a familiar state before `enable_manual_ranking/1` reseeds it
  fresh, rather than needing to be rebuilt from scratch.
  """
  def disable_manual_ranking(%Tournament{} = tournament),
    do: set_manual_ranking_flag(tournament, false)

  defp set_manual_ranking_flag(tournament, value) do
    tournament
    |> Ecto.Changeset.change(manual_ranking: value)
    |> Repo.update()
    |> tap_ok(fn updated -> broadcast_tournament_change(updated.id, :settings) end)
  end

  @doc """
  Re-seeds `tournament`'s manual order from the current computed standings
  (`PairingsEngine.Standings.standings/1`) — every player's `manual_rank`
  is set to their current tiebreak rank (a plain positive `1..N` value),
  and `tournaments.manual_ranking_stale` is cleared. This is both how
  `enable_manual_ranking/1` seeds the first time and the arbiter's explicit
  "re-seed from current order" action once the banner reports the hand-set
  order is stale (SWAR parity #23 requirement 5) or incomplete (a player
  joined after the mode was switched on and was never placed).
  """
  def reseed_manual_ranking(%Tournament{} = tournament) do
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

  An explicit reorder also confirms the whole list is fresh — even from a
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

  # Current manual order, nulls (never-seeded players) last — the same
  # "rank, nil-last" ordering `PairingsEngine.Standings.apply_manual_ranking/2`
  # displays, computed here directly off `manual_rank` since we need the
  # actual `%Player{}` structs to write back, not just display entries.
  # `manual_rank` is always a plain positive `1..N` value (or `nil`) — no
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
  SWAR parity #23 requirement 5: a result (or bye — see
  `PairingsEngine.Pairing`) changing invalidates a previously hand-set
  manual order without discarding it. Sets `tournaments.manual_ranking_stale`
  to `true` in a single one-row update — the hand-set `players.manual_rank`
  values are left completely untouched, so the order itself survives
  intact; only the "is this still trustworthy" flag changes. This is
  exactly the bit `PairingsEngine.Standings.manual_ranking_stale?/1` reads.
  Idempotent — setting an already-true flag is a no-op write, just like
  the sign-flip approach it replaced was WHERE-clause idempotent.
  See docs/manual-standings.md.

  Gated on `manual_ranking` so a tournament that never uses this feature
  (or has switched it off) never pays for the extra write on every
  result/bye write, and so a since-disabled tournament's flag doesn't get
  needlessly marked stale — irrelevant anyway since
  `enable_manual_ranking/1` always reseeds fresh (and clears staleness).

  Public (not just called from this module's own `update_pairing_result/2`)
  because `PairingsEngine.Pairing` — the pairing engine, which is where
  byes are written — needs the same hook. Both call sites are required to
  invalidate **before** broadcasting `:tournament_changed` on the
  tournament's topic: a subscriber (StandingsLive, PublicStandingsLive,
  ...) reacts to that broadcast by immediately re-reading the DB, so
  committing this write first means every reload the broadcast triggers
  already observes the stale flag — never a race where a subscriber
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

  ## Forbidden pairings (arbiter-configured "never pair these two" — see
  ## docs/forbidden-pairings.md). A tournament-configuration write like
  ## `update_tournament/2` above: any authorized user (owner or accepted
  ## collaborator, per `get_authorized_tournament!/2`) may manage these, not
  ## just the owner — there's no separate ownership check here, same as the
  ## general Settings form.

  @doc """
  Lists `tournament`'s forbidden pairings, most recently added first, with
  both players preloaded as `:player_a` / `:player_b` so the UI can render
  "Name A — Name B" without a second query per row.
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

    * `:same_player` — `player_a_id == player_b_id`
    * `:invalid_player` — either id doesn't belong to `tournament`
    * `:already_forbidden` — the pair is already forbidden, in either order
      (`{a, b}` and `{b, a}` are the same pair)

  Otherwise inserts the row and broadcasts `:settings` on the tournament's
  topic (same hint `update_tournament/2` uses — both are tournament
  configuration, so the Settings page reload path is identical).
  """
  def add_forbidden_pairing(%Tournament{} = tournament, player_a_id, player_b_id) do
    cond do
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

  @doc """
  Byes-table rows (`"requested-half"` / `"requested-zero"` / `"absent"` —
  see `PairingsEngine.Standings.add_bye_records/3` for the exact scoring
  rule per type) for `tournament_id` in round `number`, each with its
  `%Player{}` preloaded as `:player`.

  These are DIFFERENT from a pairing-allocated bye (a real `Pairing` row
  with `black_player_id: nil, result: "bye"`, already visible via
  `get_round/2`'s `round.pairings`) — a byes-table row never appears in
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
    pairing
    |> Pairing.changeset(%{result: result})
    |> Repo.update()
    |> tap_ok(fn updated ->
      tournament_id = round_tournament_id(updated.round_id)
      # Invalidate *before* broadcasting: a subscriber (StandingsLive,
      # PublicStandingsLive, ...) reacts to `broadcast_tournament_change/2`
      # by immediately re-reading the DB. If the `manual_ranking_stale`
      # write happened after the broadcast, a subscriber's reload could
      # race it and render the old (fresh-looking) manual order for one
      # frame, with nothing left to trigger a second re-render once the
      # flag actually commits — exactly the "silently serving stale as
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
  Swaps two players' SEATS in `round` — the SWAR "swap players" move.
  Whatever slot each player currently occupies (board, colour, opponent
  or bye), the two trade: the slot itself — its board number and which
  colour sits there — never moves, only WHO fills it does. Everyone else
  in the round is untouched.

      round has  1. A-B   2. C-D
      swap(A, D) gives  1. D-B   2. C-A

  Passing a player's own opponent swaps only that one board's colours —
  the same operation, since both players are already in the same
  pairing's two seats.

  Allowed against a bye (`black_player_id: nil`) — the player swapped IN
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
    # Same row on both sides — A and B are already each other's opponent,
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
  # who WERE there and is cleared — see the moduledoc on
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
  # want the round re-paired — they want THAT seat emptied and, if
  # possible, refilled from whoever is sitting the round out. So a seat can
  # be VACANT: `white_player_id`/`black_player_id` is `nil` while
  # `result` is `""`.
  #
  # That shape is deliberately the one the rest of the codebase already
  # copes with, rather than a new flag:
  #
  #   * `Standings.pairing_records/3` returns `[]` for `result: ""`, so a
  #     vacant board contributes nothing to anyone's score — true, since
  #     no game has happened and the arbiter hasn't yet said what should
  #     happen instead.
  #   * `Pairing.round_complete?/2` looks for exactly `result == ""`, so a
  #     vacant board blocks the next round from being paired until the
  #     arbiter resolves it. That's the safety net: a vacancy can't be
  #     silently forgotten.
  #   * TRF export's `bye_safe_result/2` already normalises a row with no
  #     opponent into a legal bye code.
  #
  # A vacancy is resolved exactly two ways — `fill_seat/4` (someone takes
  # the seat) or `award_bye_for_vacancy/2` (the player left behind gets a
  # bye). Both land on shapes with well-defined FIDE scoring; neither
  # invents a "forfeit against nobody", which is the one combination the
  # tiebreak code has no rule for (see `Standings.dummy_score/3`'s note).

  @doc """
  Everyone in `tournament_id` who is NOT sitting at a board in round
  `number` — the round's pool. `type` is the `"byes"`-table type when
  they have a row there (`"requested-half"`, `"requested-zero"`,
  `"absent"`), or `nil` for a player who is simply unpaired.

  Each entry carries `player_id` and `round` alongside the preloaded
  `player`, so an entry IS a `"byes"`-table row as far as
  `Standings.bye_points_for_row/2` is concerned — the pool panel can ask
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
    # decides who belongs in it. `absent` is the SOFT flag — "told us
    # they can't make it" — and someone turning up anyway is the
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
  of `pairing`, and drops their `"byes"` row for the round — they're
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
      is_nil(field) ->
        {:error, :seat_taken}

      pairing.result == "bye" ->
        # Not a vacancy — an allocated bye. Filling it would silently
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
  Pairs two pool players into a brand-new board in `round`, numbered
  `board`. Both players' `"byes"` rows are dropped — they're playing.
  """
  def pair_from_pool(%Round{} = round, white_id, black_id, board)
      when is_integer(board) and board > 0 do
    if white_id == black_id do
      {:error, :same_player}
    else
      Repo.transaction(fn ->
        {:ok, created} =
          %Pairing{round_id: round.id}
          |> Pairing.changeset(%{
            board: board,
            white_player_id: white_id,
            black_player_id: black_id,
            result: ""
          })
          |> Repo.insert()

        delete_bye_row(round, white_id)
        delete_bye_row(round, black_id)
        created
      end)
      |> finish_round_write(round.tournament_id)
    end
  end

  @doc """
  The lowest board number not already used in `round` — what the "pair
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
  same `"byes"` type the pool player had — an "absent" swap hands over the
  absence along with the seat, so the round's absentee count doesn't
  change just because two names traded places.

  A pool player with no `"byes"` row at all (simply unpaired) hands over
  `"absent"`, that being what the displaced player now is.
  """
  def swap_seated_with_pool_player(%Round{} = round, seated_id, pool_id) do
    with {:ok, {pairing, field}} <- find_player_seat(round.pairings, seated_id) do
      handover_type = pool_player_type(round, pool_id) || "absent"

      Repo.transaction(fn ->
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
  # `status` ("setup" | "running" | "finished") is derived, not hand-set —
  # see `refresh_status!/1` below. A round itself is considered "finished"
  # when every one of its pairings carries a result (a "bye" pairing's
  # result is the literal string "bye", already non-blank, so pairing-
  # allocated byes never block a round from counting as finished).

  @doc """
  Derives `tournament`'s status from its actual pairing/scoring state and
  persists it if it changed, returning the (possibly updated) tournament
  unchanged otherwise. Accepts either a `%Tournament{}` or a tournament id.

    * `"finished"` — `rounds_count` rounds have been paired, and every
      pairing in every paired round has a recorded result.
    * `"running"`  — at least one round has been paired, but the tournament
      isn't finished yet per the rule above.
    * `"setup"`    — no round has been paired yet.

  Tolerant and self-contained by design: safe to call after any write that
  might affect completeness (a result entered, a round paired or unpaired,
  a bulk import) without the caller needing to know the current status or
  pass any extra context. Returns `nil` if the tournament (or its id) no
  longer exists — e.g. deleted concurrently — rather than raising.

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
