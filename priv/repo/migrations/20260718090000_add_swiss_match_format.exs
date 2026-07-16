defmodule PairingsEngine.Repo.Migrations.AddSwissMatchFormat do
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      # Swiss "match format": a match is two physical rounds, the second an
      # exact colour-reversed mirror of the first — the JaVaFo-decided leg
      # plus its mirror, both inserted by PairingsEngine.Pairing.do_pair/2 in
      # one transaction. Sibling feature to round robin's rr_match_format —
      # see the field's own doc comment on
      # PairingsEngine.Tournaments.Tournament.
      add :swiss_match_format, :boolean, default: false, null: false
    end
  end
end
