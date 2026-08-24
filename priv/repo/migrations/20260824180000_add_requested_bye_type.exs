defmodule PairingsEngine.Repo.Migrations.AddRequestedByeType do
  @moduledoc """
  What a bye a player ASKED for is worth.

  The `byes` table has carried a `"requested-half"` type since the SWAR
  importer was written, and everything downstream reads it - `Standings`
  pays it `points_draw`, the TRF exporter writes it as `H`, the player card
  and every print template label it "½ bye". Nothing in the application
  could ever create one: `Pairing.insert_round_absentee_byes/3` hardcoded
  `"requested-zero"`, so a SWAR import was the only way such a row could
  exist.

  That is the wrong default for most opens, where a bye requested in
  advance is worth half a point. It also made the question the public
  registration form has to answer - "do I get points for this?" - one with
  only one possible answer.

  Defaults to `"zero"`, which is exactly what the hardcoded value did, so
  no existing tournament changes behaviour.
  """
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      add :requested_bye_type, :string, null: false, default: "zero"
    end
  end
end
