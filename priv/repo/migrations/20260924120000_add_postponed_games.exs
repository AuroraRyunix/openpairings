defmodule PairingsEngine.Repo.Migrations.AddPostponedGames do
  @moduledoc """
  Postponed games (VCL4THP Q157-169, `PairingsEngine.PostponedGames`).

  On `tournaments`:

    * `postponed_games` - whether the tournament allows them at all. Off for
      every existing row, so nothing changes for a tournament that never
      ticks it.
    * `postponed_requester_outcome` / `postponed_opponent_outcome` - what a
      postponed game counts as until it is played, for the player who asked
      for it and for the other one: `"win"`, `"draw"` or `"loss"`. Both
      `"draw"` by default, which is the FIDE rule (Q167).

  On `pairings`, all nil/false for every existing row:

    * `provisional_white` / `provisional_black` - the outcome each side of a
      postponed game counts as, taken from the tournament's setting when the
      game was postponed, so changing the setting later leaves it alone.
    * `postponed_by` - `"white"`, `"black"` or nil (nobody named), kept
      after the game is played, when the result no longer says it.
    * `played_on` - the date a postponed game was actually played, which
      decides which rating report it belongs in.
    * `finalised_at` - when the board went into a TRF the arbiter marked as
      sent; `finalised_open` - whether it was an open postponed game then
      (written as `?`), in which case its later result goes in the
      postponed-games file instead; `postponed_reported_at` - when that
      later result was sent.

  Additive, nullable or defaulted, so reversible and safe on existing data.
  """
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      add :postponed_games, :boolean, null: false, default: false
      add :postponed_requester_outcome, :string, null: false, default: "draw"
      add :postponed_opponent_outcome, :string, null: false, default: "draw"
    end

    alter table(:pairings) do
      add :provisional_white, :string
      add :postponed_by, :string
      add :provisional_black, :string
      add :played_on, :date
      add :finalised_at, :utc_datetime
      add :finalised_open, :boolean, null: false, default: false
      add :postponed_reported_at, :utc_datetime
    end
  end
end
