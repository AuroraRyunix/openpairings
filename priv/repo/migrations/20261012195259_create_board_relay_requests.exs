defmodule PairingsEngine.Repo.Migrations.CreateBoardRelayRequests do
  @moduledoc """
  Where a tournament stands with the results site about its hall box's
  permission to send moves there (`PairingsEngine.BoardLink.RelayKeys`).

  One row per tournament at most, and none until something was asked. The
  permission itself (the relay key) stays where it was, in
  `tournaments.openresults_relay_key`; this is the bookkeeping around it:
  that it was fetched and when, or why it was not and when to ask again.
  """
  use Ecto.Migration

  def change do
    create table(:board_relay_requests) do
      add :tournament_id, references(:tournaments, on_delete: :delete_all), null: false
      # "held" (fetched, and in the tournament's column), "wanted" (asked,
      # not answered: the site was unreachable or busy) or "refused" (the
      # site said no, and `reason` says which no).
      add :state, :string, null: false, default: "wanted"
      add :reason, :string
      add :attempts, :integer, null: false, default: 0
      add :next_attempt_at, :utc_datetime
      add :obtained_at, :utc_datetime
      # The address on the results site the held key is for. A tournament
      # that moved to another one needs another key.
      add :slug, :string
      # The arbiter asked for a new one while one is held.
      add :replace, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:board_relay_requests, [:tournament_id])
  end
end
