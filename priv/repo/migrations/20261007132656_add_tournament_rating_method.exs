defmodule PairingsEngine.Repo.Migrations.AddTournamentRatingMethod do
  @moduledoc """
  The Tournament Rating (TRF26 record 172 methods, VCL4THP Q145) and the
  order for players level on rating and title (C.04.2 2.2.3, Q146).

    * `tournaments.rating_method` - which rating ranks the players and so
      gives them their pairing numbers: `FIDE`, `NRO`, `FIDON`, `NIDOF`,
      `HBFN` or `OTHER`. `FIDON` (FIDE rating, the national one for a player
      without) is what this app always did, so every existing tournament
      keeps it.
    * `tournaments.initial_order_tiebreak` - the last criterion of the
      initial order, after rating and FIDE title: `name` (alphabetical, the
      regulation's default and what every existing tournament had),
      `fide_id`, `age_older` or `age_younger`.
    * `tournaments.late_entry_numbering` - a Swiss late entrant's pairing
      number: `end` (after the field, what this app always did) or `rating`
      (the number their rating earns, everybody below moving down one -
      C.04.2 2.4).
    * `players.tournament_rating` - a rating typed by hand for this
      tournament, read by `HBFN` and `OTHER`. Null when nobody typed one.
  """
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      add :rating_method, :string, null: false, default: "FIDON"
      add :initial_order_tiebreak, :string, null: false, default: "name"
      add :late_entry_numbering, :string, null: false, default: "end"
    end

    alter table(:players) do
      add :tournament_rating, :integer
    end
  end
end
