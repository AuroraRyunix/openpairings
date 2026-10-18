defmodule PairingsEngine.Repo.Migrations.AddRegistrationFeeAndPendingList do
  @moduledoc """
  What the entry form states about money, and whether the public entry list
  shows entries that are still waiting for a decision.

  The fee is a statement on the form and nothing else: no payment is taken
  anywhere. All three fee columns are nullable, so an existing tournament
  states no fee. `registration_list_pending` defaults to true as decided on
  2026-10-18 - it only matters once `registration_list_public` is on, which
  every existing tournament has off.
  """
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      add :registration_fee_amount, :string
      add :registration_fee_currency, :string
      add :registration_fee_note, :string
      add :registration_list_pending, :boolean, default: true, null: false
    end
  end
end
