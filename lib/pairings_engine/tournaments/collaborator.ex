defmodule PairingsEngine.Tournaments.Collaborator do
  @moduledoc """
  Grants a user (by email) access to a tournament they don't own - the
  "Share a tournament" feature (see `docs/teams.md`). A row here is created
  by the tournament's owner via `PairingsEngine.Tournaments.add_collaborator/3`
  and, once *accepted*, lets that person open/edit/pair/enter-results/print/
  export/generate-norms on the tournament exactly like the owner, with two
  exceptions that stay owner-only: managing collaborators, and deleting the
  tournament (both gated on `tournaments.user_id`, not on any row here).

  Being added does **not** grant access by itself. Every row starts
  `status: "pending"` with a random `invite_token`; the invited person must
  explicitly accept via the `/invites/:token` page (see
  `PairingsEngine.Tournaments.accept_invitation/2`) before
  `get_authorized_tournament/2`, `get_authorized_tournament!/2` or
  `list_tournaments/1` will honour the row (only `status == "accepted"`
  counts - see `PairingsEngine.Tournaments.collaborator_tournament_ids/1`).
  Declining, or the owner revoking, deletes the row outright.

  `user_id` starts out `nil` when the invited email has no account yet; it
  gets linked either when that email logs in for the first time (see
  `PairingsEngine.Tournaments.link_pending_collaborators/1`, called from
  `PairingsEngineWeb.UserAuth.log_in_user/3`) or, definitely, the moment the
  invitation is accepted. A `nil` `user_id` never grants access on its
  own - only `status == "accepted"` does.

  Not to be confused with `PairingsEngine.Tournaments.Team` (table
  `teams`) - that's an unrelated concept, chess teams within a team
  tournament (name/captain/players), nothing to do with user access.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @roles ~w(editor)
  @statuses ~w(pending accepted)

  schema "tournament_collaborators" do
    field :email, :string
    field :role, :string, default: "editor"
    field :status, :string, default: "pending"
    field :invite_token, :string
    # Not persisted - set in-memory by
    # `PairingsEngine.Tournaments.add_collaborator/3` so the caller (the
    # Settings LiveView) can tell whether the invitation email actually went
    # out, without changing that function's `{:ok, collaborator}` contract.
    field :mail_status, :any, virtual: true

    belongs_to :tournament, PairingsEngine.Tournaments.Tournament
    belongs_to :user, PairingsEngine.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(collaborator, attrs) do
    collaborator
    |> cast(attrs, [:tournament_id, :user_id, :email, :role, :status, :invite_token])
    |> update_change(:email, &normalize_email/1)
    |> validate_required([:tournament_id, :email])
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
      message: "must be a valid email address"
    )
    |> validate_inclusion(:role, @roles)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:tournament_id, :email])
    |> unique_constraint(:invite_token)
  end

  defp normalize_email(email) when is_binary(email),
    do: email |> String.trim() |> String.downcase()

  defp normalize_email(email), do: email
end
