defmodule PairingsEngine.Repo.Migrations.AddFideHomologatedAndIdRanges do
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      # "This tournament is FIDE-rated/reportable" tickbox — see
      # PairingsEngine.Tournaments.Tournament's field doc.
      add :fide_homologated, :boolean, null: false, default: false

      # Ordered list of %{"fide_tournament_id" => id, "from_round" => n, "to_round" => n}
      # entries — SWAR's "this FIDE tournament ID applies to rounds X-Y" model.
      # See PairingsEngine.Tournaments.Tournament's field doc for the
      # validation rules and how this interacts with the plain
      # `fide_tournament_id` fallback field.
      add :fide_id_ranges, {:array, :map}, null: false, default: []
    end
  end
end
