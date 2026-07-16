defmodule PairingsEngine.Repo.Migrations.AddManualRankingAndLogo do
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      # Explicit manual-standings override mode (SWAR parity #23). When true the
      # arbiter's hand-set player order wins over the computed tiebreak order,
      # and every surface that shows a rank (standings, public pages, prints,
      # TRF export) must say so — an override that is invisible is a bug.
      add :manual_ranking, :boolean, default: false, null: false

      # Per-tournament logo for print documents (SWAR parity #14-16). Stored as
      # a DB blob rather than on disk so deploys/backups carry it without any
      # filesystem or upload-dir question. Written only via Tournaments.set_logo/
      # clear_logo — deliberately NOT cast by changeset/2, same as deleted_at.
      add :logo_data, :binary
      add :logo_content_type, :string
    end

    alter table(:players) do
      # Arbiter-assigned rank used only while the tournament is in manual_ranking
      # mode; nil = never hand-placed. Managed by Tournaments reorder functions,
      # NOT cast by Player.changeset/2.
      add :manual_rank, :integer
    end

    create index(:players, [:tournament_id, :manual_rank])
  end
end
