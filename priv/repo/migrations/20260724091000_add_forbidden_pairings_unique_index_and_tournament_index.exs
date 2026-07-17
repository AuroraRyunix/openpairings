defmodule PairingsEngine.Repo.Migrations.AddForbiddenPairingsUniqueIndexAndTournamentIndex do
  use Ecto.Migration

  def change do
    # Order-insensitivity ({a,b} == {b,a}) was previously enforced only by
    # a check-then-insert race in PairingsEngine.Tournaments.add_forbidden_pairing/3.
    # ForbiddenPairing.changeset/2 now normalizes storage order (the smaller
    # id always goes in player_a_id), so an ordinary two-column unique index
    # is order-insensitive by construction — a real DB-level guarantee
    # instead of a racy application check.
    create unique_index(:forbidden_pairings, [:tournament_id, :player_a_id, :player_b_id])

    # list_forbidden_pairings/1 always filters by tournament_id alone with
    # no existing index on this FK — a full table scan every time. Same
    # class of cheap fix as the byes(tournament_id, round) index added
    # previously; not urgent at this table's realistic size, but free to
    # add alongside the unique index above since this migration already
    # touches the table.
    create index(:forbidden_pairings, [:tournament_id])
  end
end
