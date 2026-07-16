defmodule PairingsEngine.Audit.AuditLog do
  @moduledoc """
  One append-only audit-trail row: a single state-changing action taken on a
  tournament, who took it, and a freeform structured `details` payload
  specific to that action code. See `PairingsEngine.Audit` for the write and
  query API, and `PairingsEngineWeb.AuditLive` for how each row is rendered
  into a human-readable sentence.

  `action` is a dot-namespaced code (e.g. `"player.updated"`,
  `"pairing.round_paired"`). `user_id` is nullable — a nil user renders as
  "System". There is no `updated_at`: rows are never modified once written.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "audit_logs" do
    field :action, :string
    field :details, :map, default: %{}

    belongs_to :tournament, PairingsEngine.Tournaments.Tournament
    belongs_to :user, PairingsEngine.Accounts.User

    timestamps(updated_at: false)
  end

  def changeset(audit_log, attrs) do
    audit_log
    |> cast(attrs, [:tournament_id, :user_id, :action, :details])
    |> validate_required([:tournament_id, :action])
  end
end
