defmodule PairingsEngine.Audit.AuditLog do
  @moduledoc """
  One append-only audit-trail row: a single state-changing action, who took
  it, and a freeform structured `details` payload specific to that action
  code. See `PairingsEngine.Audit` for the write and query API, and
  `PairingsEngineWeb.AuditLive` for how each row is rendered into a
  human-readable sentence.

  `action` is a dot-namespaced code (e.g. `"player.updated"`,
  `"pairing.round_paired"`). `user_id` is nullable - a nil user renders as
  "System". There is no `updated_at`: rows are never modified once written.

  `tournament_id` is nullable too, for a different reason: most rows ARE
  about one tournament, but a role granted, a backup downloaded, the
  publishing connection repointed, or a rating-list sync started are acts
  on the installation itself, with no tournament to name. `nil` here means
  exactly that, not "unknown" - see `PairingsEngine.Audit.log_system/3` and
  the migration that widened this column
  (`priv/repo/migrations/20260829210000_make_audit_logs_tournament_optional.exs`)
  for why one table holds both kinds of row.
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
    |> validate_required([:action])
  end
end
