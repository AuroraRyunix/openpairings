defmodule PairingsEngine.Repo.Migrations.AddPairingPublishDelay do
  use Ecto.Migration

  # `publish_mode` default "immediate" preserves today's behaviour for
  # every existing tournament with zero migration risk: `rounds.published_at`
  # is added WITHOUT a backfill (existing rounds get `nil`), but the
  # visibility rule (`Tournaments.round_published?/2`) ignores
  # `published_at` entirely in "immediate" mode - a round is visible the
  # moment it exists, exactly as before. `published_at` only starts
  # mattering once a tournament explicitly opts into "manual" / "timed" /
  # "scheduled" via Settings, at which point every round paired FROM then
  # on gets a real value computed at pairing time (see
  # `Tournaments.compute_published_at/2`).
  def change do
    alter table(:tournaments) do
      # immediate | manual | timed | scheduled
      add :publish_mode, :string, null: false, default: "immediate"
      # Only meaningful for "timed" - minutes after pairing before a round
      # appears on the public pairings page.
      add :publish_delay_minutes, :integer, null: false, default: 0
    end

    alter table(:rounds) do
      add :published_at, :utc_datetime
    end
  end
end
